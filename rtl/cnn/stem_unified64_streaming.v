`timescale 1ns/1ps
`default_nettype none

/*
 * Isolated 64-MAC Stem prototype with static window banking.
 *
 * The production Stem is intentionally not instantiated here.  This block
 * is a proof vehicle for the dataflow that the top-level Stem would need:
 * three physical line-buffer rows, a four-pixel by sixteen-channel MAC
 * block, and four-byte output commits.  Input words use the same little
 * endian byte order as the external feature SRAM (x is the slow dimension,
 * channel is the innermost byte), but are deliberately fetched through a
 * real 32-bit request/response port rather than a testbench-only array.
 *
 * A row is first assembled in a small byte staging buffer and then packed
 * into nine independent 64-bit line memories (three row slots by three
 * channels).  The memories hold eight adjacent pixels per word, including
 * right-side zero-point padding.  During compute, all nine memories are read
 * synchronously in parallel; the selected row/channel word is consumed one
 * cycle later.  This keeps the BRAM boundary explicit and avoids a large
 * dynamic LUTRAM image.
 *
 * One block is four adjacent output pixels and all sixteen output channels.
 * Sixty-four signed 8x8 products accumulate for each of 27 K taps.  Four
 * exact ten-stage requantizers issue sixteen four-byte commits per block.
 * The reference implementation drains a block before starting the next;
 * this establishes an honest cycle/resource baseline before adding a
 * double-bank commit overlap.
 */
module stem_static_window_banks #(
    parameter integer IMAGE_H = 32,
    parameter integer IMAGE_W = 32,
    parameter integer OUT_H = 32,
    parameter integer OUT_W = 32,
    parameter integer EPOCH_WIDTH = 4,
    // The original isolated proof used a packed 32-bit source word (four
    // NHWC bytes).  The cnn_top external memory contract is scalar: each
    // accepted 32-bit read contains one signed activation in bits [7:0].
    // Keep the packed mode available for the standalone proof while making
    // the integration mode an explicit, contract-preserving parameter.
    parameter integer PACKED_INPUT = 1,
    /* When set, the source/window scheduler emits its 4x16 tokens to the
     * top-level shared arithmetic island.  The local 64-MAC and four-lane
     * requant bank are then not elaborated. */
    parameter integer SHARED_ARRAY = 0
) (
    input wire clk,
    input wire rst_n,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [1:0] cfg_target,       // 0 weight byte, 1 bias, 2 multiplier, 3 shift
    input wire [8:0] cfg_index,
    input wire [31:0] cfg_data,

    input wire start,
    input wire [31:0] source_base_addr,
    input wire signed [7:0] input_zero_point,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    input wire [EPOCH_WIDTH-1:0] start_epoch,
    output reg busy,
    output reg done,
    output reg error,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [31:0] mem_req_addr,
    input wire mem_resp_valid,
    output wire mem_resp_ready,
    input wire [31:0] mem_resp_data,

    output wire out_wr_valid,
    input wire out_wr_ready,
    output wire [9:0] out_wr_pixel_idx,
    output wire [3:0] out_wr_channel_base,
    output wire [31:0] out_wr_data,
    output wire [3:0] out_wr_byte_en,
    output wire [EPOCH_WIDTH-1:0] out_wr_epoch,

    output wire [31:0] metric_cycles,
    output wire [31:0] metric_source_req_count,
    output wire [31:0] metric_source_resp_count,
    output wire [31:0] metric_output_commit_count,
    output wire [31:0] metric_token_count,
    output wire [31:0] metric_mac_count,
    output wire [31:0] metric_compute_cycles,
    output wire [31:0] metric_config_writes,

    /* Optional shared-array transaction sideband.  These ports are omitted
     * from legacy named instantiations and are active only for
     * SHARED_ARRAY=1. */
    output wire shared_valid_in,
    input wire shared_ready_in,
    output wire shared_first_k,
    output wire shared_last_k,
    output wire [7:0] shared_k_idx,
    output wire signed [63:0] shared_act_vec,
    output wire signed [127:0] shared_wgt_vec16,
    output wire [7:0] shared_pixel_mask,
    output wire [15:0] shared_cout_mask,
    output wire [10:0] shared_pixel_base,
    output wire [8:0] shared_cout_base,
    output wire signed [511:0] shared_bias_vec,
    output wire signed [511:0] shared_multiplier_vec,
    output wire [95:0] shared_shift_vec,
    input wire shared_out_valid,
    output wire shared_out_ready,
    input wire [10:0] shared_out_pixel_idx,
    input wire [8:0] shared_out_channel_base,
    input wire [3:0] shared_out_lane_mask,
    input wire signed [31:0] shared_out_data
);
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_LOAD_REQ   = 4'd1;
    localparam [3:0] ST_LOAD_WAIT  = 4'd2;
    localparam [3:0] ST_PACK       = 4'd3;
    localparam [3:0] ST_COMP_INIT  = 4'd4;
    localparam [3:0] ST_COMP_READ  = 4'd5;
    localparam [3:0] ST_COMP_OPERAND = 4'd6;
    localparam [3:0] ST_COMP_MAC   = 4'd7;
    localparam [3:0] ST_COMP_FLUSH = 4'd8;
    localparam [3:0] ST_RQ_ISSUE   = 4'd9;
    localparam [3:0] ST_RQ_DRAIN   = 4'd10;
    localparam [3:0] ST_FINISH     = 4'd11;
    localparam [3:0] ST_ERROR      = 4'd12;
    localparam [3:0] ST_SHARED_WAIT = 4'd13;

    localparam integer ROW_WORDS = PACKED_INPUT ? 24 : 96;
    localparam integer ROW_BYTES = 96;
    localparam integer BLOCKS_X = 8;
    localparam integer BLOCKS_Y = 32;
    localparam integer BLOCK_COUNT = 256;

    reg [3:0] state;
    reg signed [7:0] input_zero_point_reg;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg, activation_max_reg;
    reg [31:0] source_base_reg;
    reg [EPOCH_WIDTH-1:0] epoch_reg;
    /* Declared before the packed weight read ports so no implicit-net
     * forward reference is created during Vivado elaboration. */
    reg [5:0] weight_prefetch_phase;

    /* Parameter stores are written only while idle and then remain fixed for
     * the complete transaction.  Weight addresses are {cout,k}, so no live
     * cout cursor is present in the MAC loop.
     *
     * The first implementation kept 432 scalar bytes in a distributed array
     * and read sixteen unrelated locations every MAC cycle.  That is a
     * perfectly reasonable RTL model, but it asks synthesis for sixteen
     * independent read ports and expands into a large LUT/FF crossbar in the
     * unified-Stem full top.  Store eight output-channel weights per row in
     * two 64-bit mixed-width memories instead: the write side remains one
     * byte per external configuration beat, while the compute side performs
     * only two fixed-address 64-bit reads.  The two words are then sliced into
     * the sixteen local operand registers below.
     *
     * In Vivado the explicit XPM instances use one 8-bit write port and one
     * 64-bit registered read port per bank.  The non-SYNTHESIS model mirrors
     * the same one-cycle read latency so the functional timing contract is
     * identical in Verilator and Vivado. */
    wire cfg_weight_fire = rst_n && cfg_valid && cfg_ready &&
                           (cfg_target == 2'd0) && (cfg_index < 9'd432);
    wire weight_cfg_bank = (cfg_index >= 9'd216);
    wire [8:0] weight_cfg_local_index = weight_cfg_bank ?
                                         (cfg_index - 9'd216) : cfg_index;
    wire [4:0] weight_cfg_k = weight_cfg_local_index % 9'd27;
    wire [2:0] weight_cfg_lane = weight_cfg_local_index / 9'd27;
    wire [7:0] weight_cfg_byte_addr = (weight_cfg_k << 3) + weight_cfg_lane;
    wire [4:0] weight_rd_addr = weight_prefetch_phase[4:0];
    wire [63:0] weight_rd_data0_raw;
    wire [63:0] weight_rd_data1_raw;

/* The direct mixed-width RAMB experiment is retained behind an opt-in macro;
 * Vivado 2025.2 aborts during synthesis for that primitive configuration.
 * The XPM implementation below is the production synthesis path. */
`ifdef STEM_UNUSED_WEIGHT_STORAGE
`ifdef STEM_USE_LEGACY_WEIGHT_PRIMITIVE
    wire [31:0] weight_bank0_low_dout, weight_bank0_high_dout;
    wire [31:0] weight_bank1_low_dout, weight_bank1_high_dout;
    wire [3:0] weight_bank0_low_parity, weight_bank0_high_parity;
    wire [3:0] weight_bank1_low_parity, weight_bank1_high_parity;
    assign weight_rd_data0_raw = {weight_bank0_high_dout,
                                  weight_bank0_low_dout};
    assign weight_rd_data1_raw = {weight_bank1_high_dout,
                                  weight_bank1_low_dout};

    RAMB36E1 #(
        .DOA_REG(0), .DOB_REG(1), .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"), .RAM_MODE("SDP"),
        .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
        .READ_WIDTH_A(0), .READ_WIDTH_B(36),
        .RSTREG_PRIORITY_A("RSTREG"), .RSTREG_PRIORITY_B("RSTREG"),
        .SRVAL_A(36'h0), .SRVAL_B(36'h0),
        .WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(9), .WRITE_WIDTH_B(0)
    ) u_stem_weight_bank0_low (
        .CLKARDCLK(clk), .CLKBWRCLK(clk),
        .ENARDEN(cfg_weight_fire && !weight_cfg_bank && !weight_cfg_chunk),
        .ENBWREN(busy),
        .ADDRARDADDR({4'b0, weight_cfg_chunk_addr, 4'b0}),
        .ADDRBWRADDR({5'b0, weight_rd_addr, 6'b0}),
        .DIADI({24'b0, cfg_data[7:0]}), .DIPADIP(4'b0),
        .DIBDI(32'b0), .DIPBDIP(4'b0),
        .WEA(4'b0001), .WEBWE(8'b0),
        .DOADO(), .DOPADOP(), .DOBDO(weight_bank0_low_dout),
        .DOPBDOP(weight_bank0_low_parity),
        .REGCEAREGCE(1'b0), .REGCEB(1'b1),
        .RSTRAMARSTRAM(!rst_n), .RSTRAMB(!rst_n),
        .RSTREGARSTREG(!rst_n), .RSTREGB(!rst_n),
        .CASCADEINA(1'b0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .CASCADEOUTA(), .CASCADEOUTB(), .DBITERR(), .RDADDRECC(),
        .SBITERR(), .ECCPARITY()
    );
    RAMB36E1 #(
        .DOA_REG(0), .DOB_REG(1), .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"), .RAM_MODE("SDP"),
        .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
        .READ_WIDTH_A(0), .READ_WIDTH_B(36),
        .RSTREG_PRIORITY_A("RSTREG"), .RSTREG_PRIORITY_B("RSTREG"),
        .SRVAL_A(36'h0), .SRVAL_B(36'h0),
        .WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(9), .WRITE_WIDTH_B(0)
    ) u_stem_weight_bank0_high (
        .CLKARDCLK(clk), .CLKBWRCLK(clk),
        .ENARDEN(cfg_weight_fire && !weight_cfg_bank && weight_cfg_chunk),
        .ENBWREN(busy),
        .ADDRARDADDR({4'b0, weight_cfg_chunk_addr, 4'b0}),
        .ADDRBWRADDR({5'b0, weight_rd_addr, 6'b0}),
        .DIADI({24'b0, cfg_data[7:0]}), .DIPADIP(4'b0),
        .DIBDI(32'b0), .DIPBDIP(4'b0),
        .WEA(4'b0001), .WEBWE(8'b0),
        .DOADO(), .DOPADOP(), .DOBDO(weight_bank0_high_dout),
        .DOPBDOP(weight_bank0_high_parity),
        .REGCEAREGCE(1'b0), .REGCEB(1'b1),
        .RSTRAMARSTRAM(!rst_n), .RSTRAMB(!rst_n),
        .RSTREGARSTREG(!rst_n), .RSTREGB(!rst_n),
        .CASCADEINA(1'b0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .CASCADEOUTA(), .CASCADEOUTB(), .DBITERR(), .RDADDRECC(),
        .SBITERR(), .ECCPARITY()
    );
    RAMB36E1 #(
        .DOA_REG(0), .DOB_REG(1), .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"), .RAM_MODE("SDP"),
        .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
        .READ_WIDTH_A(0), .READ_WIDTH_B(36),
        .RSTREG_PRIORITY_A("RSTREG"), .RSTREG_PRIORITY_B("RSTREG"),
        .SRVAL_A(36'h0), .SRVAL_B(36'h0),
        .WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(9), .WRITE_WIDTH_B(0)
    ) u_stem_weight_bank1_low (
        .CLKARDCLK(clk), .CLKBWRCLK(clk),
        .ENARDEN(cfg_weight_fire && weight_cfg_bank && !weight_cfg_chunk),
        .ENBWREN(busy),
        .ADDRARDADDR({4'b0, weight_cfg_chunk_addr, 4'b0}),
        .ADDRBWRADDR({5'b0, weight_rd_addr, 6'b0}),
        .DIADI({24'b0, cfg_data[7:0]}), .DIPADIP(4'b0),
        .DIBDI(32'b0), .DIPBDIP(4'b0),
        .WEA(4'b0001), .WEBWE(8'b0),
        .DOADO(), .DOPADOP(), .DOBDO(weight_bank1_low_dout),
        .DOPBDOP(weight_bank1_low_parity),
        .REGCEAREGCE(1'b0), .REGCEB(1'b1),
        .RSTRAMARSTRAM(!rst_n), .RSTRAMB(!rst_n),
        .RSTREGARSTREG(!rst_n), .RSTREGB(!rst_n),
        .CASCADEINA(1'b0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .CASCADEOUTA(), .CASCADEOUTB(), .DBITERR(), .RDADDRECC(),
        .SBITERR(), .ECCPARITY()
    );
    RAMB36E1 #(
        .DOA_REG(0), .DOB_REG(1), .EN_ECC_READ("FALSE"),
        .EN_ECC_WRITE("FALSE"), .RAM_MODE("SDP"),
        .RDADDR_COLLISION_HWCONFIG("DELAYED_WRITE"),
        .READ_WIDTH_A(0), .READ_WIDTH_B(36),
        .RSTREG_PRIORITY_A("RSTREG"), .RSTREG_PRIORITY_B("RSTREG"),
        .SRVAL_A(36'h0), .SRVAL_B(36'h0),
        .WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
        .WRITE_WIDTH_A(9), .WRITE_WIDTH_B(0)
    ) u_stem_weight_bank1_high (
        .CLKARDCLK(clk), .CLKBWRCLK(clk),
        .ENARDEN(cfg_weight_fire && weight_cfg_bank && weight_cfg_chunk),
        .ENBWREN(busy),
        .ADDRARDADDR({4'b0, weight_cfg_chunk_addr, 4'b0}),
        .ADDRBWRADDR({5'b0, weight_rd_addr, 6'b0}),
        .DIADI({24'b0, cfg_data[7:0]}), .DIPADIP(4'b0),
        .DIBDI(32'b0), .DIPBDIP(4'b0),
        .WEA(4'b0001), .WEBWE(8'b0),
        .DOADO(), .DOPADOP(), .DOBDO(weight_bank1_high_dout),
        .DOPBDOP(weight_bank1_high_parity),
        .REGCEAREGCE(1'b0), .REGCEB(1'b1),
        .RSTRAMARSTRAM(!rst_n), .RSTRAMB(!rst_n),
        .RSTREGARSTREG(!rst_n), .RSTREGB(!rst_n),
        .CASCADEINA(1'b0), .CASCADEINB(1'b0),
        .INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
        .CASCADEOUTA(), .CASCADEOUTB(), .DBITERR(), .RDADDRECC(),
        .SBITERR(), .ECCPARITY()
    );
`else
`ifdef STEM_USE_XPM_WEIGHT_IMPL
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(5), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(256*8), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
        .WRITE_MODE_B("read_first")
    ) u_stem_weight_bank0 (
        .clka(clk), .clkb(clk), .ena(cfg_weight_fire && !weight_cfg_bank),
        .enb(busy), .addra(weight_cfg_byte_addr), .addrb(weight_rd_addr),
        .dina(cfg_data[7:0]), .wea(1'b1), .doutb(weight_rd_data0_raw),
        .rstb(!rst_n), .regceb(1'b1), .sleep(1'b0),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(5), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(256*8), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
        .WRITE_MODE_B("read_first")
    ) u_stem_weight_bank1 (
        .clka(clk), .clkb(clk), .ena(cfg_weight_fire && weight_cfg_bank),
        .enb(busy), .addra(weight_cfg_byte_addr), .addrb(weight_rd_addr),
        .dina(cfg_data[7:0]), .wea(1'b1), .doutb(weight_rd_data1_raw),
        .rstb(!rst_n), .regceb(1'b1), .sleep(1'b0),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`else
    /* Packed fallback/synthesis model.  Each bank has one registered 64-bit
     * read port and a byte-select write decoder; unlike the old scalar array,
     * synthesis cannot create sixteen independent memory reads.  The RAM
     * geometry is deliberately fixed at 32 rows (only rows 0..26 are used),
     * which also keeps the read address a direct phase cursor. */
    reg [63:0] weight_bank0_mem;
    reg [63:0] weight_bank1_mem;
    reg [63:0] weight_rd_data0_reg, weight_rd_data1_reg;
    assign weight_rd_data0_raw = weight_rd_data0_reg;
    assign weight_rd_data1_raw = weight_rd_data1_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            weight_rd_data0_reg <= 64'd0;
            weight_rd_data1_reg <= 64'd0;
        end else begin
            if (busy) begin
                weight_rd_data0_reg <= weight_bank0_mem;
                weight_rd_data1_reg <= weight_bank1_mem;
            end
        end
    end
`endif
`endif

`endif

    stem_weight_store_packed64 u_stem_weight_store (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_weight_fire), .cfg_index(cfg_index),
        .cfg_data(cfg_data), .read_enable(busy),
        .read_addr(weight_rd_addr), .read_data0(weight_rd_data0_raw),
        .read_data1(weight_rd_data1_raw)
    );

    reg signed [31:0] bias_mem [0:15];
    reg signed [31:0] multiplier_mem [0:15];
    reg [5:0] shift_mem [0:15];
    integer cfg_i;
    always @(posedge clk) begin
        if (rst_n && cfg_valid && cfg_ready) begin
            case (cfg_target)
                2'd0: begin end // packed weight child owns weight writes
                2'd1: if (cfg_index < 9'd16)
                    bias_mem[cfg_index] <= cfg_data;
                2'd2: if (cfg_index < 9'd16)
                    multiplier_mem[cfg_index] <= cfg_data;
                2'd3: if (cfg_index < 9'd16)
                    shift_mem[cfg_index] <= cfg_data[5:0];
                default: begin end
            endcase
        end
    end
    assign cfg_ready = rst_n && !busy;

    /* 32-bit source row assembly.  This buffer is only 96 bytes and is not
     * the feature image; the persistent image itself is the nine BRAM rows
     * below. */
    reg [7:0] source_row_bytes [0:95];
    reg [5:0] load_row;
    reg [6:0] load_word;
    reg load_pending;
    reg [1:0] pack_index;
    reg [3:0] pack_group;
    /* The loader owns a rotating physical bank pointer.  It advances once
     * per completed source row; no row modulo is present on the address or
     * control path. */
    reg [1:0] load_bank;
    // The packed proof ABI stores four NHWC bytes per external word, while
    // the production runner's scalar ABI stores one byte in bits [7:0] of
    // each word.  Preserve the same 96-byte row in the local staging buffer
    // but advance the external row base by 96 or 384 bytes respectively;
    // using a fixed 96-byte stride aliases scalar rows after the first one.
    localparam integer SOURCE_ROW_STRIDE_BYTES = PACKED_INPUT ? 96 : 384;
    wire [31:0] load_addr_offset =
                                    (load_row * SOURCE_ROW_STRIDE_BYTES) +
                                    (load_word << 2);

    assign mem_req_valid = (state == ST_LOAD_REQ) && !load_pending && busy;
    assign mem_req_addr = source_base_reg + load_addr_offset;
    assign mem_resp_ready = (state == ST_LOAD_WAIT) && load_pending && busy;
    wire source_req_fire = mem_req_valid && mem_req_ready;
    wire source_resp_fire = mem_resp_valid && mem_resp_ready;

    /* Explicitly separate the nine memories.  The nested array is still
     * statically indexed by row slot/channel at every write/read site, so
     * Vivado can infer one small block RAM per physical plane. */
    (* ram_style = "block" *) reg [63:0] line_mem_b0_c0 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b0_c1 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b0_c2 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b1_c0 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b1_c1 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b1_c2 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b2_c0 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b2_c1 [0:3];
    (* ram_style = "block" *) reg [63:0] line_mem_b2_c2 [0:3];

    reg [2:0] block_x;
    reg [5:0] block_y;
    reg [63:0] line_q_b0_c0, line_q_b0_c1, line_q_b0_c2;
    reg [63:0] line_q_b1_c0, line_q_b1_c1, line_q_b1_c2;
    reg [63:0] line_q_b2_c0, line_q_b2_c1, line_q_b2_c2;
    reg [63:0] line_qn_b0_c0, line_qn_b0_c1, line_qn_b0_c2;
    reg [63:0] line_qn_b1_c0, line_qn_b1_c1, line_qn_b1_c2;
    reg [63:0] line_qn_b2_c0, line_qn_b2_c1, line_qn_b2_c2;
    reg [63:0] line_qp_b0_c0, line_qp_b0_c1, line_qp_b0_c2;
    reg [63:0] line_qp_b1_c0, line_qp_b1_c1, line_qp_b1_c2;
    reg [63:0] line_qp_b2_c0, line_qp_b2_c1, line_qp_b2_c2;
    reg [2:0] col_word;
    reg [1:0] row_mid_bank;

    /* One physical read per plane per block.  Even blocks fetch the current
     * word and latch the preceding word from the prior block; odd blocks
     * retain the current word and fetch only the following word. */
    always @(posedge clk) begin
        /* The retained previous/current/next words are loaded exactly once
         * per block.  Re-reading during OPERAND/MAC would overwrite the
         * previous-word register with the current word after the first MAC
         * cycle and corrupt the left edge of every even block. */
        if (state == ST_COMP_READ) begin
            if (!block_x[0]) begin
                line_q_b0_c0 <= line_mem_b0_c0[col_word]; line_q_b0_c1 <= line_mem_b0_c1[col_word]; line_q_b0_c2 <= line_mem_b0_c2[col_word];
                line_q_b1_c0 <= line_mem_b1_c0[col_word]; line_q_b1_c1 <= line_mem_b1_c1[col_word]; line_q_b1_c2 <= line_mem_b1_c2[col_word];
                line_q_b2_c0 <= line_mem_b2_c0[col_word]; line_q_b2_c1 <= line_mem_b2_c1[col_word]; line_q_b2_c2 <= line_mem_b2_c2[col_word];
                if (col_word == 0) begin
                    line_qp_b0_c0<={8{input_zero_point_reg}}; line_qp_b0_c1<={8{input_zero_point_reg}}; line_qp_b0_c2<={8{input_zero_point_reg}};
                    line_qp_b1_c0<={8{input_zero_point_reg}}; line_qp_b1_c1<={8{input_zero_point_reg}}; line_qp_b1_c2<={8{input_zero_point_reg}};
                    line_qp_b2_c0<={8{input_zero_point_reg}}; line_qp_b2_c1<={8{input_zero_point_reg}}; line_qp_b2_c2<={8{input_zero_point_reg}};
                end else begin
                    line_qp_b0_c0<=line_q_b0_c0; line_qp_b0_c1<=line_q_b0_c1; line_qp_b0_c2<=line_q_b0_c2;
                    line_qp_b1_c0<=line_q_b1_c0; line_qp_b1_c1<=line_q_b1_c1; line_qp_b1_c2<=line_q_b1_c2;
                    line_qp_b2_c0<=line_q_b2_c0; line_qp_b2_c1<=line_q_b2_c1; line_qp_b2_c2<=line_q_b2_c2;
                end
            end else if (col_word == 3) begin
                line_qn_b0_c0<={8{input_zero_point_reg}}; line_qn_b0_c1<={8{input_zero_point_reg}}; line_qn_b0_c2<={8{input_zero_point_reg}};
                line_qn_b1_c0<={8{input_zero_point_reg}}; line_qn_b1_c1<={8{input_zero_point_reg}}; line_qn_b1_c2<={8{input_zero_point_reg}};
                line_qn_b2_c0<={8{input_zero_point_reg}}; line_qn_b2_c1<={8{input_zero_point_reg}}; line_qn_b2_c2<={8{input_zero_point_reg}};
            end else begin
                line_qn_b0_c0<=line_mem_b0_c0[col_word+1'b1]; line_qn_b0_c1<=line_mem_b0_c1[col_word+1'b1]; line_qn_b0_c2<=line_mem_b0_c2[col_word+1'b1];
                line_qn_b1_c0<=line_mem_b1_c0[col_word+1'b1]; line_qn_b1_c1<=line_mem_b1_c1[col_word+1'b1]; line_qn_b1_c2<=line_mem_b1_c2[col_word+1'b1];
                line_qn_b2_c0<=line_mem_b2_c0[col_word+1'b1]; line_qn_b2_c1<=line_mem_b2_c1[col_word+1'b1]; line_qn_b2_c2<=line_mem_b2_c2[col_word+1'b1];
            end
        end
    end

    reg [63:0] pack_word;
    reg [1:0] pack_channel;
    reg [1:0] pack_word_addr;
    /* Twelve fixed descriptors form one 96-byte row.  Keeping the byte
     * lanes explicit avoids a variable part-select and lets synthesis map
     * each destination to a single local RAM write port. */
    always @* begin
        pack_channel = 0;
        pack_word_addr = 0;
        pack_word = 64'd0;
        case (pack_group)
            4'd0: begin pack_channel=0; pack_word_addr=0;
                pack_word[7:0]=source_row_bytes[0]; pack_word[15:8]=source_row_bytes[3];
                pack_word[23:16]=source_row_bytes[6]; pack_word[31:24]=source_row_bytes[9];
                pack_word[39:32]=source_row_bytes[12]; pack_word[47:40]=source_row_bytes[15];
                pack_word[55:48]=source_row_bytes[18]; pack_word[63:56]=source_row_bytes[21]; end
            4'd1: begin pack_channel=1; pack_word_addr=0;
                pack_word[7:0]=source_row_bytes[1]; pack_word[15:8]=source_row_bytes[4];
                pack_word[23:16]=source_row_bytes[7]; pack_word[31:24]=source_row_bytes[10];
                pack_word[39:32]=source_row_bytes[13]; pack_word[47:40]=source_row_bytes[16];
                pack_word[55:48]=source_row_bytes[19]; pack_word[63:56]=source_row_bytes[22]; end
            4'd2: begin pack_channel=2; pack_word_addr=0;
                pack_word[7:0]=source_row_bytes[2]; pack_word[15:8]=source_row_bytes[5];
                pack_word[23:16]=source_row_bytes[8]; pack_word[31:24]=source_row_bytes[11];
                pack_word[39:32]=source_row_bytes[14]; pack_word[47:40]=source_row_bytes[17];
                pack_word[55:48]=source_row_bytes[20]; pack_word[63:56]=source_row_bytes[23]; end
            4'd3: begin pack_channel=0; pack_word_addr=1;
                pack_word[7:0]=source_row_bytes[24]; pack_word[15:8]=source_row_bytes[27];
                pack_word[23:16]=source_row_bytes[30]; pack_word[31:24]=source_row_bytes[33];
                pack_word[39:32]=source_row_bytes[36]; pack_word[47:40]=source_row_bytes[39];
                pack_word[55:48]=source_row_bytes[42]; pack_word[63:56]=source_row_bytes[45]; end
            4'd4: begin pack_channel=1; pack_word_addr=1;
                pack_word[7:0]=source_row_bytes[25]; pack_word[15:8]=source_row_bytes[28];
                pack_word[23:16]=source_row_bytes[31]; pack_word[31:24]=source_row_bytes[34];
                pack_word[39:32]=source_row_bytes[37]; pack_word[47:40]=source_row_bytes[40];
                pack_word[55:48]=source_row_bytes[43]; pack_word[63:56]=source_row_bytes[46]; end
            4'd5: begin pack_channel=2; pack_word_addr=1;
                pack_word[7:0]=source_row_bytes[26]; pack_word[15:8]=source_row_bytes[29];
                pack_word[23:16]=source_row_bytes[32]; pack_word[31:24]=source_row_bytes[35];
                pack_word[39:32]=source_row_bytes[38]; pack_word[47:40]=source_row_bytes[41];
                pack_word[55:48]=source_row_bytes[44]; pack_word[63:56]=source_row_bytes[47]; end
            4'd6: begin pack_channel=0; pack_word_addr=2;
                pack_word[7:0]=source_row_bytes[48]; pack_word[15:8]=source_row_bytes[51];
                pack_word[23:16]=source_row_bytes[54]; pack_word[31:24]=source_row_bytes[57];
                pack_word[39:32]=source_row_bytes[60]; pack_word[47:40]=source_row_bytes[63];
                pack_word[55:48]=source_row_bytes[66]; pack_word[63:56]=source_row_bytes[69]; end
            4'd7: begin pack_channel=1; pack_word_addr=2;
                pack_word[7:0]=source_row_bytes[49]; pack_word[15:8]=source_row_bytes[52];
                pack_word[23:16]=source_row_bytes[55]; pack_word[31:24]=source_row_bytes[58];
                pack_word[39:32]=source_row_bytes[61]; pack_word[47:40]=source_row_bytes[64];
                pack_word[55:48]=source_row_bytes[67]; pack_word[63:56]=source_row_bytes[70]; end
            4'd8: begin pack_channel=2; pack_word_addr=2;
                pack_word[7:0]=source_row_bytes[50]; pack_word[15:8]=source_row_bytes[53];
                pack_word[23:16]=source_row_bytes[56]; pack_word[31:24]=source_row_bytes[59];
                pack_word[39:32]=source_row_bytes[62]; pack_word[47:40]=source_row_bytes[65];
                pack_word[55:48]=source_row_bytes[68]; pack_word[63:56]=source_row_bytes[71]; end
            4'd9: begin pack_channel=0; pack_word_addr=3;
                pack_word[7:0]=source_row_bytes[72]; pack_word[15:8]=source_row_bytes[75];
                pack_word[23:16]=source_row_bytes[78]; pack_word[31:24]=source_row_bytes[81];
                pack_word[39:32]=source_row_bytes[84]; pack_word[47:40]=source_row_bytes[87];
                pack_word[55:48]=source_row_bytes[90]; pack_word[63:56]=source_row_bytes[93]; end
            4'd10: begin pack_channel=1; pack_word_addr=3;
                pack_word[7:0]=source_row_bytes[73]; pack_word[15:8]=source_row_bytes[76];
                pack_word[23:16]=source_row_bytes[79]; pack_word[31:24]=source_row_bytes[82];
                pack_word[39:32]=source_row_bytes[85]; pack_word[47:40]=source_row_bytes[88];
                pack_word[55:48]=source_row_bytes[91]; pack_word[63:56]=source_row_bytes[94]; end
            default: begin pack_channel=2; pack_word_addr=3;
                pack_word[7:0]=source_row_bytes[74]; pack_word[15:8]=source_row_bytes[77];
                pack_word[23:16]=source_row_bytes[80]; pack_word[31:24]=source_row_bytes[83];
                pack_word[39:32]=source_row_bytes[86]; pack_word[47:40]=source_row_bytes[89];
                pack_word[55:48]=source_row_bytes[92]; pack_word[63:56]=source_row_bytes[95]; end
        endcase
    end

    /* A synchronous read of every physical plane.  Only one selected word is
     * used for a tap, but all nine reads are static and therefore retain
     * independent BRAM locality. */
    /* Local tap cursor.  It advances through the fixed 3x3x3 schedule and
     * is deliberately separate from the MAC cells and from the address
     * generation fabric. */
    reg [5:0] tap_phase;
    /* Keep the four pixel operands physically local to the MAC islands.  The
     * prior routed result showed the sign-extended act_stage_q bits driving
     * hundreds of DSP pins; a bounded fanout request is the smallest local
     * physical experiment before changing the datapath or cycle contract. */
    (* max_fanout = 64 *) reg signed [7:0] act_stage_q [0:3];
    reg [7:0] weight_stage_q [0:15];
    reg [5:0] cell_k_idx;
    wire signed [31:0] acc [0:63];
    reg [1:0] rq_pixel_in_block;
    reg [1:0] rq_group;
    wire [2:0] rq_read_word = col_word;
    reg [63:0] logical_q_top_c0, logical_q_top_c1, logical_q_top_c2;
    reg [63:0] logical_q_mid_c0, logical_q_mid_c1, logical_q_mid_c2;
    reg [63:0] logical_q_bot_c0, logical_q_bot_c1, logical_q_bot_c2;
    reg [63:0] logical_qp_top_c0, logical_qp_top_c1, logical_qp_top_c2;
    reg [63:0] logical_qp_mid_c0, logical_qp_mid_c1, logical_qp_mid_c2;
    reg [63:0] logical_qp_bot_c0, logical_qp_bot_c1, logical_qp_bot_c2;
    reg [63:0] logical_qn_top_c0, logical_qn_top_c1, logical_qn_top_c2;
    reg [63:0] logical_qn_mid_c0, logical_qn_mid_c1, logical_qn_mid_c2;
    reg [63:0] logical_qn_bot_c0, logical_qn_bot_c1, logical_qn_bot_c2;

    /* Static rotation of the three physical row banks.  This is the only
     * row selection in the compute cone; all subsequent byte choices are
     * decoded from the fixed tap/column phase. */
    always @* begin
        logical_q_top_c0 = {8{input_zero_point_reg}};
        logical_q_top_c1 = {8{input_zero_point_reg}};
        logical_q_top_c2 = {8{input_zero_point_reg}};
        logical_q_mid_c0 = 0; logical_q_mid_c1 = 0; logical_q_mid_c2 = 0;
        logical_q_bot_c0 = {8{input_zero_point_reg}};
        logical_q_bot_c1 = {8{input_zero_point_reg}};
        logical_q_bot_c2 = {8{input_zero_point_reg}};
        logical_qp_top_c0 = {8{input_zero_point_reg}};
        logical_qp_top_c1 = {8{input_zero_point_reg}};
        logical_qp_top_c2 = {8{input_zero_point_reg}};
        logical_qp_mid_c0 = 0; logical_qp_mid_c1 = 0; logical_qp_mid_c2 = 0;
        logical_qp_bot_c0 = {8{input_zero_point_reg}};
        logical_qp_bot_c1 = {8{input_zero_point_reg}};
        logical_qp_bot_c2 = {8{input_zero_point_reg}};
        logical_qn_top_c0 = {8{input_zero_point_reg}};
        logical_qn_top_c1 = {8{input_zero_point_reg}};
        logical_qn_top_c2 = {8{input_zero_point_reg}};
        logical_qn_mid_c0 = 0; logical_qn_mid_c1 = 0; logical_qn_mid_c2 = 0;
        logical_qn_bot_c0 = {8{input_zero_point_reg}};
        logical_qn_bot_c1 = {8{input_zero_point_reg}};
        logical_qn_bot_c2 = {8{input_zero_point_reg}};
        case (row_mid_bank)
            2'd0: begin
                logical_q_top_c0=line_q_b2_c0; logical_q_top_c1=line_q_b2_c1; logical_q_top_c2=line_q_b2_c2;
                logical_q_mid_c0=line_q_b0_c0; logical_q_mid_c1=line_q_b0_c1; logical_q_mid_c2=line_q_b0_c2;
                logical_q_bot_c0=line_q_b1_c0; logical_q_bot_c1=line_q_b1_c1; logical_q_bot_c2=line_q_b1_c2;
                logical_qp_top_c0=line_qp_b2_c0; logical_qp_top_c1=line_qp_b2_c1; logical_qp_top_c2=line_qp_b2_c2;
                logical_qp_mid_c0=line_qp_b0_c0; logical_qp_mid_c1=line_qp_b0_c1; logical_qp_mid_c2=line_qp_b0_c2;
                logical_qp_bot_c0=line_qp_b1_c0; logical_qp_bot_c1=line_qp_b1_c1; logical_qp_bot_c2=line_qp_b1_c2;
                logical_qn_top_c0=line_qn_b2_c0; logical_qn_top_c1=line_qn_b2_c1; logical_qn_top_c2=line_qn_b2_c2;
                logical_qn_mid_c0=line_qn_b0_c0; logical_qn_mid_c1=line_qn_b0_c1; logical_qn_mid_c2=line_qn_b0_c2;
                logical_qn_bot_c0=line_qn_b1_c0; logical_qn_bot_c1=line_qn_b1_c1; logical_qn_bot_c2=line_qn_b1_c2;
            end
            2'd1: begin
                logical_q_top_c0=line_q_b0_c0; logical_q_top_c1=line_q_b0_c1; logical_q_top_c2=line_q_b0_c2;
                logical_q_mid_c0=line_q_b1_c0; logical_q_mid_c1=line_q_b1_c1; logical_q_mid_c2=line_q_b1_c2;
                logical_q_bot_c0=line_q_b2_c0; logical_q_bot_c1=line_q_b2_c1; logical_q_bot_c2=line_q_b2_c2;
                logical_qp_top_c0=line_qp_b0_c0; logical_qp_top_c1=line_qp_b0_c1; logical_qp_top_c2=line_qp_b0_c2;
                logical_qp_mid_c0=line_qp_b1_c0; logical_qp_mid_c1=line_qp_b1_c1; logical_qp_mid_c2=line_qp_b1_c2;
                logical_qp_bot_c0=line_qp_b2_c0; logical_qp_bot_c1=line_qp_b2_c1; logical_qp_bot_c2=line_qp_b2_c2;
                logical_qn_top_c0=line_qn_b0_c0; logical_qn_top_c1=line_qn_b0_c1; logical_qn_top_c2=line_qn_b0_c2;
                logical_qn_mid_c0=line_qn_b1_c0; logical_qn_mid_c1=line_qn_b1_c1; logical_qn_mid_c2=line_qn_b1_c2;
                logical_qn_bot_c0=line_qn_b2_c0; logical_qn_bot_c1=line_qn_b2_c1; logical_qn_bot_c2=line_qn_b2_c2;
            end
            default: begin
                logical_q_top_c0=line_q_b1_c0; logical_q_top_c1=line_q_b1_c1; logical_q_top_c2=line_q_b1_c2;
                logical_q_mid_c0=line_q_b2_c0; logical_q_mid_c1=line_q_b2_c1; logical_q_mid_c2=line_q_b2_c2;
                logical_q_bot_c0=line_q_b0_c0; logical_q_bot_c1=line_q_b0_c1; logical_q_bot_c2=line_q_b0_c2;
                logical_qp_top_c0=line_qp_b1_c0; logical_qp_top_c1=line_qp_b1_c1; logical_qp_top_c2=line_qp_b1_c2;
                logical_qp_mid_c0=line_qp_b2_c0; logical_qp_mid_c1=line_qp_b2_c1; logical_qp_mid_c2=line_qp_b2_c2;
                logical_qp_bot_c0=line_qp_b0_c0; logical_qp_bot_c1=line_qp_b0_c1; logical_qp_bot_c2=line_qp_b0_c2;
                logical_qn_top_c0=line_qn_b1_c0; logical_qn_top_c1=line_qn_b1_c1; logical_qn_top_c2=line_qn_b1_c2;
                logical_qn_mid_c0=line_qn_b2_c0; logical_qn_mid_c1=line_qn_b2_c1; logical_qn_mid_c2=line_qn_b2_c2;
                logical_qn_bot_c0=line_qn_b0_c0; logical_qn_bot_c1=line_qn_b0_c1; logical_qn_bot_c2=line_qn_b0_c2;
            end
        endcase
        if (block_y == 0) begin
            logical_q_top_c0={8{input_zero_point_reg}}; logical_q_top_c1={8{input_zero_point_reg}}; logical_q_top_c2={8{input_zero_point_reg}};
            logical_qp_top_c0={8{input_zero_point_reg}}; logical_qp_top_c1={8{input_zero_point_reg}}; logical_qp_top_c2={8{input_zero_point_reg}};
            logical_qn_top_c0={8{input_zero_point_reg}}; logical_qn_top_c1={8{input_zero_point_reg}}; logical_qn_top_c2={8{input_zero_point_reg}};
        end
        if (block_y == IMAGE_H-1) begin
            logical_q_bot_c0={8{input_zero_point_reg}}; logical_q_bot_c1={8{input_zero_point_reg}}; logical_q_bot_c2={8{input_zero_point_reg}};
            logical_qp_bot_c0={8{input_zero_point_reg}}; logical_qp_bot_c1={8{input_zero_point_reg}}; logical_qp_bot_c2={8{input_zero_point_reg}};
            logical_qn_bot_c0={8{input_zero_point_reg}}; logical_qn_bot_c1={8{input_zero_point_reg}}; logical_qn_bot_c2={8{input_zero_point_reg}};
        end
    end

`ifdef STEM_DYNAMIC_LEGACY
    /* Select one 64-bit word, then extract four adjacent pixels.  The
     * left/right and top/bottom padding rules match stem_same_golden(). */
    reg [63:0] selected_line_word;
    reg [63:0] selected_line_word_next;
    reg [63:0] selected_line_word_prev;
    reg signed [7:0] act_vec [0:3];
    integer act_p;
    integer act_kh;
    integer act_kw;
    integer act_ci;
    integer act_src_y;
    integer act_src_x;
    integer act_byte_pos;
    always @* begin
        act_kh = mac_k_idx / 9;
        act_kw = (mac_k_idx % 9) / 3;
        act_ci = mac_k_idx % 3;
        act_src_y = block_y + act_kh - 1;
        if (act_src_y < 0 || act_src_y >= IMAGE_H)
            act_read_bank = 0;
        else
            act_read_bank = act_src_y % 3;
        case (act_read_bank)
            2'd0: case (act_ci)
                0: selected_line_word = line_q_b0_c0;
                1: selected_line_word = line_q_b0_c1;
                default: selected_line_word = line_q_b0_c2;
            endcase
            2'd1: case (act_ci)
                0: selected_line_word = line_q_b1_c0;
                1: selected_line_word = line_q_b1_c1;
                default: selected_line_word = line_q_b1_c2;
            endcase
            default: case (act_ci)
                0: selected_line_word = line_q_b2_c0;
                1: selected_line_word = line_q_b2_c1;
                default: selected_line_word = line_q_b2_c2;
            endcase
        endcase
        case (act_read_bank)
            2'd0: case (act_ci)
                0: selected_line_word_prev = line_qp_b0_c0;
                1: selected_line_word_prev = line_qp_b0_c1;
                default: selected_line_word_prev = line_qp_b0_c2;
            endcase
            2'd1: case (act_ci)
                0: selected_line_word_prev = line_qp_b1_c0;
                1: selected_line_word_prev = line_qp_b1_c1;
                default: selected_line_word_prev = line_qp_b1_c2;
            endcase
            default: case (act_ci)
                0: selected_line_word_prev = line_qp_b2_c0;
                1: selected_line_word_prev = line_qp_b2_c1;
                default: selected_line_word_prev = line_qp_b2_c2;
            endcase
        endcase
        case (act_read_bank)
            2'd0: case (act_ci)
                0: selected_line_word_next = line_qn_b0_c0;
                1: selected_line_word_next = line_qn_b0_c1;
                default: selected_line_word_next = line_qn_b0_c2;
            endcase
            2'd1: case (act_ci)
                0: selected_line_word_next = line_qn_b1_c0;
                1: selected_line_word_next = line_qn_b1_c1;
                default: selected_line_word_next = line_qn_b1_c2;
            endcase
            default: case (act_ci)
                0: selected_line_word_next = line_qn_b2_c0;
                1: selected_line_word_next = line_qn_b2_c1;
                default: selected_line_word_next = line_qn_b2_c2;
            endcase
        endcase
        for (act_p = 0; act_p < 4; act_p = act_p + 1) begin
            act_src_y = block_y + act_kh - 1;
            act_src_x = (block_x * 4) + act_p + act_kw - 1;
            act_byte_pos = act_src_x - ((block_x / 2) * 8);
            if ((act_src_y < 0) || (act_src_y >= IMAGE_H) ||
                (act_src_x < 0) || (act_src_x >= IMAGE_W))
                act_vec[act_p] = input_zero_point_reg;
            else if (act_byte_pos < 0)
                act_vec[act_p] = selected_line_word_prev[((act_byte_pos+8)*8) +: 8];
            else if (act_byte_pos >= 8)
                act_vec[act_p] = selected_line_word_next[((act_byte_pos-8)*8) +: 8];
            else
                act_vec[act_p] = selected_line_word[(act_byte_pos*8) +: 8];
        end
    end
`endif

    /* Fixed byte-lane decode.  Every slice below is a constant part-select;
     * the only dynamic choices are the small, local row/channel/tap cases. */
    function automatic signed [7:0] lane_byte;
        input [63:0] w;
        input [3:0] lane;
        begin
            case (lane)
                4'd0: lane_byte=w[7:0]; 4'd1: lane_byte=w[15:8];
                4'd2: lane_byte=w[23:16]; 4'd3: lane_byte=w[31:24];
                4'd4: lane_byte=w[39:32]; 4'd5: lane_byte=w[47:40];
                4'd6: lane_byte=w[55:48]; default: lane_byte=w[63:56];
            endcase
        end
    endfunction
    function automatic signed [7:0] window_byte;
        input [63:0] prev_w, cur_w, next_w;
        input [2:0] bx;
        input [1:0] kw;
        input [1:0] pp;
        input signed [7:0] zp;
        begin
            if ((bx==0) && (kw==0) && (pp==0)) window_byte=zp;
            else if ((bx==7) && (kw==2) && (pp==3)) window_byte=zp;
            else case ({bx[0],kw,pp})
                5'b00000: window_byte=lane_byte(prev_w,7);
                5'b00001: window_byte=lane_byte(cur_w,0);
                5'b00010: window_byte=lane_byte(cur_w,1);
                5'b00011: window_byte=lane_byte(cur_w,2);
                5'b00100: window_byte=lane_byte(cur_w,0);
                5'b00101: window_byte=lane_byte(cur_w,1);
                5'b00110: window_byte=lane_byte(cur_w,2);
                5'b00111: window_byte=lane_byte(cur_w,3);
                5'b01000: window_byte=lane_byte(cur_w,1);
                5'b01001: window_byte=lane_byte(cur_w,2);
                5'b01010: window_byte=lane_byte(cur_w,3);
                5'b01011: window_byte=lane_byte(cur_w,4);
                5'b10000: window_byte=lane_byte(cur_w,3);
                5'b10001: window_byte=lane_byte(cur_w,4);
                5'b10010: window_byte=lane_byte(cur_w,5);
                5'b10011: window_byte=lane_byte(cur_w,6);
                5'b10100: window_byte=lane_byte(cur_w,4);
                5'b10101: window_byte=lane_byte(cur_w,5);
                5'b10110: window_byte=lane_byte(cur_w,6);
                5'b10111: window_byte=lane_byte(cur_w,7);
                5'b11000: window_byte=lane_byte(cur_w,5);
                5'b11001: window_byte=lane_byte(cur_w,6);
                5'b11010: window_byte=lane_byte(cur_w,7);
                default: window_byte=lane_byte(next_w,0);
            endcase
        end
    endfunction
    reg [1:0] tap_row, tap_col, tap_chan;
    reg [63:0] tap_top_word, tap_mid_word, tap_bot_word;
    reg [63:0] tap_top_prev, tap_mid_prev, tap_bot_prev;
    reg [63:0] tap_top_next, tap_mid_next, tap_bot_next;
    reg [63:0] static_word, static_word_prev, static_word_next;
    reg signed [7:0] static_act_vec [0:3];
    integer static_p;
    always @* begin
        case (tap_chan)
            2'd0: begin
                tap_top_word=logical_q_top_c0; tap_mid_word=logical_q_mid_c0; tap_bot_word=logical_q_bot_c0;
                tap_top_prev=logical_qp_top_c0; tap_mid_prev=logical_qp_mid_c0; tap_bot_prev=logical_qp_bot_c0;
                tap_top_next=logical_qn_top_c0; tap_mid_next=logical_qn_mid_c0; tap_bot_next=logical_qn_bot_c0;
            end
            2'd1: begin
                tap_top_word=logical_q_top_c1; tap_mid_word=logical_q_mid_c1; tap_bot_word=logical_q_bot_c1;
                tap_top_prev=logical_qp_top_c1; tap_mid_prev=logical_qp_mid_c1; tap_bot_prev=logical_qp_bot_c1;
                tap_top_next=logical_qn_top_c1; tap_mid_next=logical_qn_mid_c1; tap_bot_next=logical_qn_bot_c1;
            end
            default: begin
                tap_top_word=logical_q_top_c2; tap_mid_word=logical_q_mid_c2; tap_bot_word=logical_q_bot_c2;
                tap_top_prev=logical_qp_top_c2; tap_mid_prev=logical_qp_mid_c2; tap_bot_prev=logical_qp_bot_c2;
                tap_top_next=logical_qn_top_c2; tap_mid_next=logical_qn_mid_c2; tap_bot_next=logical_qn_bot_c2;
            end
        endcase
        case (tap_row)
            2'd0: begin static_word=tap_top_word; static_word_prev=tap_top_prev; static_word_next=tap_top_next; end
            2'd1: begin static_word=tap_mid_word; static_word_prev=tap_mid_prev; static_word_next=tap_mid_next; end
            default: begin static_word=tap_bot_word; static_word_prev=tap_bot_prev; static_word_next=tap_bot_next; end
        endcase
        for (static_p=0; static_p<4; static_p=static_p+1)
            static_act_vec[static_p] = window_byte(static_word_prev, static_word,
                static_word_next, block_x, tap_col, static_p[1:0], input_zero_point_reg);
    end

    wire signed [7:0] mac_act [0:63];
    wire signed [7:0] mac_wgt [0:63];
    wire signed [31:0] mac_acc [0:63];
    genvar pg;
    generate for (pg = 0; pg < 64; pg = pg + 1) begin : gen_stem_products
        if (!SHARED_ARRAY) begin : gen_local_stem_mac
            assign mac_act[pg] = act_stage_q[pg/16];
            assign mac_wgt[pg] = weight_stage_q[pg%16];
            stem64_mac_cell u_mac (
                .clk(clk), .rst_n(rst_n),
                .en(state == ST_COMP_MAC),
                .clear_acc((cell_k_idx == 0) && (state == ST_COMP_MAC)),
                .act_in(mac_act[pg]), .wgt_in(mac_wgt[pg]), .acc_out(mac_acc[pg])
            );
            assign acc[pg] = mac_acc[pg];
        end else begin : gen_shared_stem_mac_tieoff
            assign mac_act[pg] = 8'sd0;
            assign mac_wgt[pg] = 8'sd0;
            assign mac_acc[pg] = 32'sd0;
            assign acc[pg] = 32'sd0;
        end
    end endgenerate

    /* Exact four-lane requantization. */
    wire [3:0] rq_ready_lane;
    wire [3:0] rq_valid_lane;
    wire signed [7:0] rq_data_lane [0:3];
    wire signed [31:0] rq_acc_vec [0:3];
    wire signed [31:0] rq_bias_vec [0:3];
    wire signed [31:0] rq_mul_vec [0:3];
    wire [5:0] rq_shift_vec [0:3];
    genvar qg;
    generate for (qg = 0; qg < 4; qg = qg + 1) begin : gen_stem_rq
        if (!SHARED_ARRAY) begin : gen_local_stem_rq
            assign rq_acc_vec[qg] = acc[rq_pixel_in_block*16 + rq_group*4 + qg];
            assign rq_bias_vec[qg] = bias_mem[rq_group*4 + qg];
            assign rq_mul_vec[qg] = multiplier_mem[rq_group*4 + qg];
            assign rq_shift_vec[qg] = shift_mem[rq_group*4 + qg];
            requant_activation_unit u_rq (
                .clk(clk), .rst_n(rst_n),
                .valid_in((state == ST_RQ_ISSUE) && rq_all_ready),
                .ready_in(rq_ready_lane[qg]),
                .acc_int32(rq_acc_vec[qg]), .bias_int32(rq_bias_vec[qg]),
                .multiplier_int32(rq_mul_vec[qg]), .shift(rq_shift_vec[qg]),
                .output_zero_point_int32(output_zero_point_reg),
                .activation_min_int32(activation_min_reg),
                .activation_max_int32(activation_max_reg),
                .ready_out(out_wr_ready), .valid_out(rq_valid_lane[qg]),
                .output_int8(rq_data_lane[qg])
            );
        end else begin : gen_shared_stem_rq_tieoff
            assign rq_acc_vec[qg] = 32'sd0;
            assign rq_bias_vec[qg] = 32'sd0;
            assign rq_mul_vec[qg] = 32'sd0;
            assign rq_shift_vec[qg] = 6'd0;
            assign rq_ready_lane[qg] = 1'b1;
            assign rq_valid_lane[qg] = 1'b0;
            assign rq_data_lane[qg] = 8'sd0;
        end
    end endgenerate

    reg [9:0] rq_tag_pixel [0:9];
    reg [3:0] rq_tag_group [0:9];
    reg rq_tag_valid [0:9];
    wire rq_all_ready = &rq_ready_lane;
    wire rq_advance = rq_all_ready;
    wire rq_input_fire = (state == ST_RQ_ISSUE) && rq_all_ready;
    wire rq_output_fire = rq_valid_lane[0] && out_wr_ready;
    assign out_wr_valid = SHARED_ARRAY ? shared_out_valid : rq_valid_lane[0];
    assign out_wr_pixel_idx = SHARED_ARRAY ? shared_out_pixel_idx[9:0] : rq_tag_pixel[9];
    assign out_wr_channel_base = SHARED_ARRAY ? shared_out_channel_base[3:0] : rq_tag_group[9] * 4;
    assign out_wr_data = SHARED_ARRAY ? shared_out_data :
                         {rq_data_lane[3], rq_data_lane[2],
                          rq_data_lane[1], rq_data_lane[0]};
    assign out_wr_byte_en = SHARED_ARRAY ? shared_out_lane_mask : 4'b1111;
    assign out_wr_epoch = epoch_reg;

    /* Shared-array source side.  The scheduler retains the same one-token
     * operand staging as the local implementation; only the owner of the
     * 64 products changes. */
    assign shared_valid_in = SHARED_ARRAY && (state == ST_COMP_MAC);
    assign shared_first_k = (cell_k_idx == 0);
    assign shared_last_k = (cell_k_idx == 26);
    assign shared_k_idx = cell_k_idx;
    assign shared_act_vec = {32'd0, act_stage_q[3], act_stage_q[2],
                             act_stage_q[1], act_stage_q[0]};
    assign shared_wgt_vec16 = {weight_stage_q[15], weight_stage_q[14],
                               weight_stage_q[13], weight_stage_q[12],
                               weight_stage_q[11], weight_stage_q[10],
                               weight_stage_q[9], weight_stage_q[8],
                               weight_stage_q[7], weight_stage_q[6],
                               weight_stage_q[5], weight_stage_q[4],
                               weight_stage_q[3], weight_stage_q[2],
                               weight_stage_q[1], weight_stage_q[0]};
    assign shared_pixel_mask = 8'h0f;
    assign shared_cout_mask = 16'hffff;
    assign shared_pixel_base = (block_y * 11'd32) + (block_x * 11'd4);
    assign shared_cout_base = 9'd0;
    genvar sb;
    generate for (sb=0; sb<16; sb=sb+1) begin : gen_shared_stem_params
        assign shared_bias_vec[(sb*32)+:32] = bias_mem[sb];
        assign shared_multiplier_vec[(sb*32)+:32] = multiplier_mem[sb];
        assign shared_shift_vec[(sb*6)+:6] = shift_mem[sb];
    end endgenerate
    assign shared_out_ready = SHARED_ARRAY && (state == ST_SHARED_WAIT) && out_wr_ready;

    integer ri;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (ri = 0; ri < 10; ri = ri + 1) begin
                rq_tag_valid[ri] <= 1'b0;
                rq_tag_pixel[ri] <= 10'd0;
                rq_tag_group[ri] <= 4'd0;
            end
        end else if (rq_advance) begin
            rq_tag_valid[0] <= rq_input_fire;
            if (rq_input_fire) begin
                rq_tag_pixel[0] <= (block_y * 32) + (block_x * 4) + rq_pixel_in_block;
                rq_tag_group[0] <= rq_group;
            end
            for (ri = 1; ri < 10; ri = ri + 1) begin
                rq_tag_valid[ri] <= rq_tag_valid[ri-1];
                if (rq_tag_valid[ri-1]) begin
                    rq_tag_pixel[ri] <= rq_tag_pixel[ri-1];
                    rq_tag_group[ri] <= rq_tag_group[ri-1];
                end
            end
        end
    end

    reg [31:0] cycles_reg, source_req_count_reg, source_resp_count_reg;
    reg [31:0] output_commit_count_reg, token_count_reg, mac_count_reg;
    reg [31:0] compute_cycles_reg, config_write_count_reg;
    assign metric_cycles = cycles_reg;
    assign metric_source_req_count = source_req_count_reg;
    assign metric_source_resp_count = source_resp_count_reg;
    assign metric_output_commit_count = output_commit_count_reg;
    assign metric_token_count = token_count_reg;
    assign metric_mac_count = mac_count_reg;
    assign metric_compute_cycles = compute_cycles_reg;
    assign metric_config_writes = config_write_count_reg;

    always @(posedge clk) begin
        if (rst_n && cfg_valid && cfg_ready)
            config_write_count_reg <= config_write_count_reg + 1'b1;
    end

    integer ai;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            source_base_reg <= 0;
            input_zero_point_reg <= 0;
            output_zero_point_reg <= 0;
            activation_min_reg <= -32'sd128;
            activation_max_reg <= 32'sd127;
            epoch_reg <= 0;
            load_row <= 0;
            load_word <= 0;
            load_pending <= 0;
            pack_group <= 0;
            block_x <= 0;
            block_y <= 0;
            tap_phase <= 0;
            weight_prefetch_phase <= 0;
            tap_row <= 0;
            tap_col <= 0;
            tap_chan <= 0;
            col_word <= 0;
            row_mid_bank <= 0;
            rq_pixel_in_block <= 0;
            rq_group <= 0;
            cycles_reg <= 0;
            source_req_count_reg <= 0;
            source_resp_count_reg <= 0;
            output_commit_count_reg <= 0;
            token_count_reg <= 0;
            mac_count_reg <= 0;
            compute_cycles_reg <= 0;
            config_write_count_reg <= 0;
            line_q_b0_c0 <= 0; line_q_b0_c1 <= 0; line_q_b0_c2 <= 0;
            line_q_b1_c0 <= 0; line_q_b1_c1 <= 0; line_q_b1_c2 <= 0;
            line_q_b2_c0 <= 0; line_q_b2_c1 <= 0; line_q_b2_c2 <= 0;
        end else begin
            done <= 1'b0;
            if (busy) cycles_reg <= cycles_reg + 1'b1;
            if (source_req_fire) begin
                load_pending <= 1'b1;
                state <= ST_LOAD_WAIT;
                source_req_count_reg <= source_req_count_reg + 1'b1;
            end
            if (source_resp_fire) begin
                if (PACKED_INPUT) begin
                    source_row_bytes[(load_word*4)+0] <= mem_resp_data[7:0];
                    source_row_bytes[(load_word*4)+1] <= mem_resp_data[15:8];
                    source_row_bytes[(load_word*4)+2] <= mem_resp_data[23:16];
                    source_row_bytes[(load_word*4)+3] <= mem_resp_data[31:24];
                end else begin
                    source_row_bytes[load_word] <= mem_resp_data[7:0];
                end
                source_resp_count_reg <= source_resp_count_reg + 1'b1;
                load_pending <= 1'b0;
                if (load_word == ROW_WORDS-1) begin
                    pack_group <= 0;
                    state <= ST_PACK;
                end else begin
                    load_word <= load_word + 1'b1;
                    state <= ST_LOAD_REQ;
                end
            end
            if (state == ST_PACK) begin
                case ({load_bank, pack_channel})
                    4'd0: line_mem_b0_c0[pack_word_addr] <= pack_word;
                    4'd1: line_mem_b0_c1[pack_word_addr] <= pack_word;
                    4'd2: line_mem_b0_c2[pack_word_addr] <= pack_word;
                    4'd4: line_mem_b1_c0[pack_word_addr] <= pack_word;
                    4'd5: line_mem_b1_c1[pack_word_addr] <= pack_word;
                    4'd6: line_mem_b1_c2[pack_word_addr] <= pack_word;
                    4'd8: line_mem_b2_c0[pack_word_addr] <= pack_word;
                    4'd9: line_mem_b2_c1[pack_word_addr] <= pack_word;
                    default: line_mem_b2_c2[pack_word_addr] <= pack_word;
                endcase
                if (pack_group == 11) begin
                    if (load_row == 0) begin
                        /* The first line is followed by the second line
                         * before row zero can be computed; the top border is
                         * represented by the zero-point select in the MAC
                         * stage. */
                        load_row <= 1;
                        load_word <= 0;
                        load_bank <= 1;
                        state <= ST_LOAD_REQ;
                    end else begin
                        /* For rows after the initial two, the block-end
                         * scheduler has already selected this row as the
                         * next bottom line.  Its completion therefore starts
                         * the next output row directly. */
                        block_x <= 0;
                        if (load_bank == 2) load_bank <= 0;
                        else load_bank <= load_bank + 1'b1;
                        state <= ST_COMP_INIT;
                    end
                end else pack_group <= pack_group + 1'b1;
            end
            if (state == ST_COMP_INIT) begin
                tap_phase <= 0;
                weight_prefetch_phase <= 0;
                tap_row <= 0;
                tap_col <= 0;
                tap_chan <= 0;
                col_word <= block_x[2:1];
                /* Logical middle row bank is advanced at output-row commit,
                 * independently of the loader's next-row pointer. */
                cell_k_idx <= 0;
                state <= ST_COMP_READ;
                token_count_reg <= token_count_reg + 27;
            end
            if (state == ST_COMP_READ) begin
                weight_prefetch_phase <= 1;
                tap_phase <= 0;
                state <= ST_COMP_OPERAND;
            end
            if (state == ST_COMP_OPERAND) begin
                /* The line-word mux and the weight row mux terminate in
                 * local operand registers.  MAC cells only see these narrow
                 * registered values, cutting the address/select cone from
                 * the DSP input timing arc. */
                for (ai = 0; ai < 4; ai = ai + 1)
                    act_stage_q[ai] <= static_act_vec[ai];
                for (ai = 0; ai < 8; ai = ai + 1)
                    weight_stage_q[ai] <= weight_rd_data0_raw[(ai*8) +: 8];
                for (ai = 0; ai < 8; ai = ai + 1)
                    weight_stage_q[8+ai] <= weight_rd_data1_raw[(ai*8) +: 8];
                cell_k_idx <= 0;
                tap_phase <= 1;
                tap_row <= 0; tap_col <= 0; tap_chan <= 1;
                weight_prefetch_phase <= 2;
                state <= ST_COMP_MAC;
            end
            if (state == ST_COMP_MAC && (!SHARED_ARRAY || shared_ready_in)) begin
                mac_count_reg <= mac_count_reg + 64;
                compute_cycles_reg <= compute_cycles_reg + 1'b1;
                /* The cell counter describes the registered operands being
                 * consumed this edge; tap_phase describes the next operand
                 * staged concurrently. */
                if (cell_k_idx == 26) begin
                    state <= ST_COMP_FLUSH;
                end else begin
                    for (ai = 0; ai < 4; ai = ai + 1)
                        act_stage_q[ai] <= static_act_vec[ai];
                    for (ai = 0; ai < 8; ai = ai + 1)
                        weight_stage_q[ai] <= weight_rd_data0_raw[(ai*8) +: 8];
                    for (ai = 0; ai < 8; ai = ai + 1)
                        weight_stage_q[8+ai] <= weight_rd_data1_raw[(ai*8) +: 8];
                    cell_k_idx <= cell_k_idx + 1'b1;
                    tap_phase <= tap_phase + 1'b1;
                    weight_prefetch_phase <= weight_prefetch_phase + 1'b1;
                    if (tap_chan == 2) begin
                        tap_chan <= 0;
                        if (tap_col == 2) begin
                            tap_col <= 0;
                            tap_row <= tap_row + 1'b1;
                        end else tap_col <= tap_col + 1'b1;
                    end else tap_chan <= tap_chan + 1'b1;
                end
            end
            if (state == ST_COMP_FLUSH) begin
                rq_pixel_in_block <= 0;
                rq_group <= 0;
                state <= SHARED_ARRAY ? ST_SHARED_WAIT : ST_RQ_ISSUE;
            end
            if (state == ST_RQ_ISSUE && rq_input_fire) begin
                if ((rq_pixel_in_block == 3) && (rq_group == 3)) begin
                    state <= ST_RQ_DRAIN;
                end else if (rq_group == 3) begin
                    rq_group <= 0;
                    rq_pixel_in_block <= rq_pixel_in_block + 1'b1;
                end else begin
                    rq_group <= rq_group + 1'b1;
                end
            end
            if (state == ST_RQ_DRAIN && rq_output_fire &&
                (rq_tag_pixel[9] == (block_y*32 + block_x*4 + 3)) &&
                (rq_tag_group[9] == 3)) begin
                output_commit_count_reg <= output_commit_count_reg + 1'b1;
                if (block_x == 7) begin
                    if (block_y == 31) state <= ST_FINISH;
                    else begin
                        block_x <= 0;
                        block_y <= block_y + 1'b1;
                        if (row_mid_bank == 2) row_mid_bank <= 0;
                        else row_mid_bank <= row_mid_bank + 1'b1;
                        if (block_y < 30) begin
                            load_row <= block_y + 2;
                            load_word <= 0;
                            state <= ST_LOAD_REQ;
                        end else begin
                            state <= ST_COMP_INIT;
                        end
                    end
                end else begin
                    block_x <= block_x + 1'b1;
                    state <= ST_COMP_INIT;
                end
            end else if (rq_output_fire) begin
                output_commit_count_reg <= output_commit_count_reg + 1'b1;
            end
            if (state == ST_SHARED_WAIT && shared_out_valid && out_wr_ready) begin
                output_commit_count_reg <= output_commit_count_reg + 1'b1;
                if ((shared_out_pixel_idx == ((block_y * 32) +
                                               (block_x * 4) + 3)) &&
                    (shared_out_channel_base == 9'd12)) begin
                    if (block_x == 7) begin
                        if (block_y == 31) state <= ST_FINISH;
                        else begin
                            block_x <= 0;
                            block_y <= block_y + 1'b1;
                            if (row_mid_bank == 2) row_mid_bank <= 0;
                            else row_mid_bank <= row_mid_bank + 1'b1;
                            if (block_y < 30) begin
                                load_row <= block_y + 2;
                                load_word <= 0;
                                state <= ST_LOAD_REQ;
                            end else state <= ST_COMP_INIT;
                        end
                    end else begin
                        block_x <= block_x + 1'b1;
                        state <= ST_COMP_INIT;
                    end
                end
            end
            if (state == ST_FINISH) begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= ST_IDLE;
            end
            if (state == ST_IDLE && start) begin
                busy <= 1'b1;
                error <= 1'b0;
                source_base_reg <= source_base_addr;
                input_zero_point_reg <= input_zero_point;
                output_zero_point_reg <= output_zero_point;
                activation_min_reg <= activation_min;
                activation_max_reg <= activation_max;
                epoch_reg <= start_epoch;
                load_row <= 0;
                load_word <= 0;
                load_pending <= 0;
                block_x <= 0;
                block_y <= 0;
                load_bank <= 0;
                row_mid_bank <= 0;
                state <= ST_LOAD_REQ;
                cycles_reg <= 0;
                source_req_count_reg <= 0;
                source_resp_count_reg <= 0;
                output_commit_count_reg <= 0;
                token_count_reg <= 0;
                mac_count_reg <= 0;
                compute_cycles_reg <= 0;
            end
        end
    end
endmodule

/* One physically local MAC cell.  Registering operands at the cell boundary
 * makes the multiply and accumulator recurrence a contained DSP island; the
 * top-level 64-MAC block never builds a 64-way shared multiply cone. */
module stem64_mac_cell (
    input wire clk,
    input wire rst_n,
    input wire en,
    input wire clear_acc,
    input wire signed [7:0] act_in,
    input wire signed [7:0] wgt_in,
    output wire signed [31:0] acc_out
);
    reg signed [7:0] act_reg, wgt_reg;
    reg clear_reg, valid_reg;
    reg signed [31:0] acc_reg;
    (* use_dsp = "yes" *) wire signed [15:0] product = act_reg * wgt_reg;
    wire signed [31:0] product_ext = {{16{product[15]}}, product};
    assign acc_out = acc_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            act_reg <= 0;
            wgt_reg <= 0;
            clear_reg <= 0;
            valid_reg <= 0;
            acc_reg <= 0;
        end else begin
            valid_reg <= en;
            if (en) begin
                act_reg <= act_in;
                wgt_reg <= wgt_in;
                clear_reg <= clear_acc;
            end
            if (valid_reg) begin
                if (clear_reg)
                    acc_reg <= product_ext;
                else
                    acc_reg <= acc_reg + product_ext;
            end
        end
    end
endmodule

`default_nettype wire
