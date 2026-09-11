`timescale 1ns/1ps
`default_nettype none

/*
 * v6 common fetch/storage bank.
 *
 * The v5/v6 scheduler used unpacked byte arrays directly in operand
 * expressions.  That is convenient for a behavioral model, but it gives the
 * implementation tool a large replicated read/mux cone instead of a real
 * memory.  This boundary keeps the logical D4 layout explicit while making
 * every physical store a collection of narrow, independently addressed
 * banks:
 *
 *   input   : eight spatial banks, 2048 x 8
 *   scratch0: sixteen channel banks, 2048 x 8
 *   scratch1: eight spatial banks, 256 x 32
 *   weights : four 32-bit banks, with independent dedicated/pool read ports
 *             (one 128-bit vector per accepted K address)
 *
 * Reads use a registered response contract by default, matching the physical
 * XPM ``READ_LATENCY_B(1)`` implementation in simulation and synthesis.
 * ``SYNC_READ=0`` remains an explicit legacy/combinational model for isolated
 * compatibility tests only.  Under SYNTHESIS all memories below are XPM
 * block RAMs and therefore always have one registered read cycle.  Payload is
 * intentionally not reset; only response-valid state is reset.
 *
 * Address maps:
 *   input logical byte a: bank=a[6:4] (x modulo 8), row=(a>>7)*16+a[3:0]
 *   scratch0 logical byte for pixel p/group g/channel c:
 *       bank=c, row=p*2+g
 *   scratch1 logical word for pixel p/group g/word q:
 *       bank=p[2:0], row=(p>>3)*8+g*4+q
 *   weight row: expand group/k at rows 0..31, project group/k at 64..127;
 *       bank=output_channel/4 and byte lane=output_channel%4.
 */
module edgembconv_hwacandidate_d4_vstream_v6_common_bank #(
    parameter integer SYNC_READ = 1,
    parameter integer ENABLE_ACTIVATION_BANKS = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cfg_valid,
    input  wire [2:0]  cfg_kind,
    input  wire [15:0] cfg_addr,
    input  wire [31:0] cfg_data,

    input  wire [7:0]  input_rd_valid,
    input  wire [87:0] input_rd_addr_vec,
    output wire [63:0] input_rd_data_vec,
    output wire        input_rd_resp_valid,

    input  wire        scratch0_rd_valid,
    input  wire [10:0] scratch0_rd_addr,
    output wire [127:0] scratch0_rd_data,
    output wire        scratch0_rd_resp_valid,

    input  wire [15:0] scratch0_wr_valid_vec,
    input  wire [10:0] scratch0_wr_addr,
    input  wire [127:0] scratch0_wr_data_vec,

    input  wire [7:0]  scratch1_rd_valid,
    input  wire [63:0] scratch1_rd_addr_vec,
    output wire [255:0] scratch1_rd_data_vec,
    output wire        scratch1_rd_resp_valid,

    input  wire        scratch1_wr_valid,
    input  wire [2:0]  scratch1_wr_bank,
    input  wire [7:0]  scratch1_wr_addr,
    input  wire [31:0] scratch1_wr_data,

    input  wire        ded_weight_rd_valid,
    input  wire        ded_weight_project,
    input  wire        ded_weight_group,
    input  wire [5:0]  ded_weight_k,
    input  wire [15:0] ded_weight_rd_desc,
    output wire        ded_weight_rd_ready,
    input  wire        ded_weight_rd_resp_ready,
    output wire [127:0] ded_weight_rd_data,
    output wire [15:0] ded_weight_rd_resp_desc,
    output wire        ded_weight_rd_resp_valid,

    input  wire        pool_weight_rd_valid,
    input  wire        pool_weight_project,
    input  wire        pool_weight_group,
    input  wire [5:0]  pool_weight_k,
    input  wire [15:0] pool_weight_rd_desc,
    output wire        pool_weight_rd_ready,
    input  wire        pool_weight_rd_resp_ready,
    output wire [127:0] pool_weight_rd_data,
    output wire [15:0] pool_weight_rd_resp_desc,
    output wire        pool_weight_rd_resp_valid
);
    localparam [2:0] CFG_INPUT = 3'd0;
    localparam [2:0] CFG_PW_WEIGHT = 3'd1;

    /* Derived configuration addresses are deliberately bit operations.  The
     * input layout is 32x32 pixels x 16 channels, so a[15:7] is the bank-row
     * group and a[6:4] is the spatial bank. */
    wire input_cfg_fire = cfg_valid && (cfg_kind == CFG_INPUT);
    wire [2:0] input_cfg_bank = cfg_addr[6:4];
    wire [10:0] input_cfg_row = {cfg_addr[15:7], 4'd0} + cfg_addr[3:0];

    wire weight_cfg_fire = cfg_valid && (cfg_kind == CFG_PW_WEIGHT) &&
                           ((cfg_addr >= 16'd2048 && cfg_addr < 16'd2560) ||
                            (cfg_addr >= 16'd3072 && cfg_addr < 16'd4096));
    wire weight_cfg_project = (cfg_addr >= 16'd3072);
    wire [11:0] weight_cfg_offset = weight_cfg_project ?
                                     (cfg_addr - 16'd3072) :
                                     (cfg_addr - 16'd2048);
    wire [5:0] weight_cfg_k = weight_cfg_project ?
                               {1'b0, weight_cfg_offset[4:0]} :
                               weight_cfg_offset[3:0];
    wire [4:0] weight_cfg_channel = weight_cfg_project ?
                                     (weight_cfg_offset / 32) :
                                     (weight_cfg_offset / 16);
    wire [1:0] weight_cfg_bank = weight_cfg_channel[4:2];
    wire [1:0] weight_cfg_lane = weight_cfg_channel[1:0];
    wire [6:0] weight_cfg_row = weight_cfg_project ?
                                 (7'd64 + ((weight_cfg_offset / 512) * 32) +
                                  weight_cfg_k) :
                                 (((weight_cfg_offset / 256) * 16) +
                                  weight_cfg_k);
    wire [3:0] weight_cfg_be = (4'b0001 << weight_cfg_lane);

    wire ded_weight_rd_fire;
    wire pool_weight_rd_fire;

    /* The behavioral implementation is intentionally sparse-reset. */
`ifndef SYNTHESIS
    (* ram_style = "block" *) reg signed [7:0] input_mem [0:7][0:2047];
    (* ram_style = "block" *) reg signed [7:0] scratch0_mem [0:15][0:2047];
    (* ram_style = "block" *) reg [31:0] scratch1_mem [0:7][0:255];
    (* ram_style = "block" *) reg [31:0] ded_weight_mem [0:3][0:127];
    (* ram_style = "block" *) reg [31:0] pool_weight_mem [0:3][0:127];
`else
    wire signed [7:0] input_dout [0:7];
    wire signed [7:0] scratch0_dout [0:15];
    wire [31:0] scratch1_dout [0:7];
    wire [31:0] ded_weight_dout [0:3];
    wire [31:0] pool_weight_dout [0:3];

    genvar ib;
    generate
      if (ENABLE_ACTIVATION_BANKS) begin : gen_activation_banks
      for (ib = 0; ib < 8; ib = ib + 1) begin : gen_input_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(2048*8),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk), .ena(input_cfg_fire && input_cfg_bank == ib[2:0]),
          .wea(input_cfg_fire && input_cfg_bank == ib[2:0]),
          .addra(input_cfg_row), .dina(cfg_data[7:0]),
          .clkb(clk), .enb(input_rd_valid[ib]),
          .addrb(input_rd_addr_vec[ib*11 +: 11]), .doutb(input_dout[ib]),
          .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      for (ib = 0; ib < 16; ib = ib + 1) begin : gen_scratch0_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(2048*8),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(8),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk), .ena(scratch0_wr_valid_vec[ib]),
          .wea(scratch0_wr_valid_vec[ib]),
          .addra(scratch0_wr_addr), .dina(scratch0_wr_data_vec[ib*8 +: 8]),
          .clkb(clk), .enb(scratch0_rd_valid), .addrb(scratch0_rd_addr),
          .doutb(scratch0_dout[ib]), .regceb(1'b1), .rstb(!rst_n),
          .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      for (ib = 0; ib < 8; ib = ib + 1) begin : gen_scratch1_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(8), .ADDR_WIDTH_B(8), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(256*32),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
          .WRITE_MODE_B("read_first")
        ) u_mem (
          .clka(clk), .ena(scratch1_wr_valid && scratch1_wr_bank == ib[2:0]),
          .wea(scratch1_wr_valid && scratch1_wr_bank == ib[2:0]),
          .addra(scratch1_wr_addr), .dina(scratch1_wr_data),
          .clkb(clk), .enb(scratch1_rd_valid[ib]),
          .addrb(scratch1_rd_addr_vec[ib*8 +: 8]), .doutb(scratch1_dout[ib]),
          .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0),
          .sbiterrb(), .dbiterrb()
        );
      end
      end
      for (ib = 0; ib < 4; ib = ib + 1) begin : gen_weight_xpm
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(7), .ADDR_WIDTH_B(7), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(128*32),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
          .WRITE_MODE_B("read_first")
        ) u_ded_mem (
          .clka(clk), .ena(weight_cfg_fire && weight_cfg_bank == ib[1:0]),
          .wea(weight_cfg_fire && weight_cfg_bank == ib[1:0] ? weight_cfg_be : 4'b0000),
          .addra(weight_cfg_row), .dina({4{cfg_data[7:0]}}),
          .clkb(clk), .enb(ded_weight_rd_fire),
          .addrb((ded_weight_project ? 7'd64 : 7'd0) +
                 (ded_weight_group ? (ded_weight_project ? 7'd32 : 7'd16) : 7'd0) +
                 ded_weight_k), .doutb(ded_weight_dout[ib]), .regceb(1'b1),
          .rstb(!rst_n), .sleep(1'b0), .injectsbiterra(1'b0),
          .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb()
        );
        xpm_memory_sdpram #(
          .ADDR_WIDTH_A(7), .ADDR_WIDTH_B(7), .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(128*32),
          .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1),
          .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(32),
          .WRITE_MODE_B("read_first")
        ) u_pool_mem (
          .clka(clk), .ena(weight_cfg_fire && weight_cfg_bank == ib[1:0]),
          .wea(weight_cfg_fire && weight_cfg_bank == ib[1:0] ? weight_cfg_be : 4'b0000),
          .addra(weight_cfg_row), .dina({4{cfg_data[7:0]}}),
          .clkb(clk), .enb(pool_weight_rd_fire),
          .addrb((pool_weight_project ? 7'd64 : 7'd0) +
                 (pool_weight_group ? (pool_weight_project ? 7'd32 : 7'd16) : 7'd0) +
                 pool_weight_k), .doutb(pool_weight_dout[ib]), .regceb(1'b1),
          .rstb(!rst_n), .sleep(1'b0), .injectsbiterra(1'b0),
          .injectdbiterra(1'b0), .sbiterrb(), .dbiterrb()
        );
      end
    endgenerate
`endif

    reg input_resp_q, scratch0_resp_q, scratch1_resp_q;
    reg ded_weight_resp_q, pool_weight_resp_q;
    reg [15:0] ded_weight_resp_desc_q, pool_weight_resp_desc_q;
    reg [127:0] scratch0_data_q;
    reg [63:0] input_data_q;
    reg [255:0] scratch1_data_q;
    reg [127:0] ded_weight_data_q, pool_weight_data_q;
    reg [127:0] scratch0_data_comb;
    reg [63:0] input_data_comb;
    reg [255:0] scratch1_data_comb;
    reg [127:0] ded_weight_data_comb, pool_weight_data_comb;

    /* Each weight side is a one-entry synchronous response queue.  The
     * request may be replaced on the same edge that the paired consumer takes
     * the current response; otherwise the physical XPM latency remains
     * visible to the scheduler. */
    assign ded_weight_rd_ready = SYNC_READ ?
        (!ded_weight_resp_q || ded_weight_rd_resp_ready) : 1'b1;
    assign pool_weight_rd_ready = SYNC_READ ?
        (!pool_weight_resp_q || pool_weight_rd_resp_ready) : 1'b1;
    assign ded_weight_rd_fire = ded_weight_rd_valid && ded_weight_rd_ready;
    assign pool_weight_rd_fire = pool_weight_rd_valid && pool_weight_rd_ready;

`ifndef SYNTHESIS
    integer b;
    always @(posedge clk) begin
      if (!rst_n) begin
        input_resp_q <= 1'b0;
        scratch0_resp_q <= 1'b0;
        scratch1_resp_q <= 1'b0;
        ded_weight_resp_q <= 1'b0;
        pool_weight_resp_q <= 1'b0;
        ded_weight_resp_desc_q <= 16'd0;
        pool_weight_resp_desc_q <= 16'd0;
      end else begin
        input_resp_q <= |input_rd_valid;
        scratch0_resp_q <= scratch0_rd_valid;
        scratch1_resp_q <= |scratch1_rd_valid;
        if (ded_weight_resp_q && ded_weight_rd_resp_ready)
          ded_weight_resp_q <= 1'b0;
        if (pool_weight_resp_q && pool_weight_rd_resp_ready)
          pool_weight_resp_q <= 1'b0;
        if (ded_weight_rd_fire) begin
          ded_weight_resp_q <= 1'b1;
          ded_weight_resp_desc_q <= ded_weight_rd_desc;
        end
        if (pool_weight_rd_fire) begin
          pool_weight_resp_q <= 1'b1;
          pool_weight_resp_desc_q <= pool_weight_rd_desc;
        end
        if (SYNC_READ) begin
          if (|input_rd_valid)
            for (b = 0; b < 8; b = b + 1)
              if (input_rd_valid[b])
                input_data_q[b*8 +: 8] <= input_mem[b][input_rd_addr_vec[b*11 +: 11]];
          if (scratch0_rd_valid)
            for (b = 0; b < 16; b = b + 1)
              scratch0_data_q[b*8 +: 8] <= scratch0_mem[b][scratch0_rd_addr];
          if (|scratch1_rd_valid)
            for (b = 0; b < 8; b = b + 1)
              if (scratch1_rd_valid[b])
                scratch1_data_q[b*32 +: 32] <= scratch1_mem[b][scratch1_rd_addr_vec[b*8 +: 8]];
          if (ded_weight_rd_fire)
            for (b = 0; b < 4; b = b + 1)
              ded_weight_data_q[b*32 +: 32] <= ded_weight_mem[b][
                (ded_weight_project ? 7'd64 : 7'd0) +
                (ded_weight_group ? (ded_weight_project ? 7'd32 : 7'd16) : 7'd0) +
                ded_weight_k];
          if (pool_weight_rd_fire)
            for (b = 0; b < 4; b = b + 1)
              pool_weight_data_q[b*32 +: 32] <= pool_weight_mem[b][
                (pool_weight_project ? 7'd64 : 7'd0) +
                (pool_weight_group ? (pool_weight_project ? 7'd32 : 7'd16) : 7'd0) +
                pool_weight_k];
        end
      end
    end
    always @* begin
      for (b = 0; b < 8; b = b + 1)
        input_data_comb[b*8 +: 8] = input_mem[b][input_rd_addr_vec[b*11 +: 11]];
      for (b = 0; b < 16; b = b + 1)
        scratch0_data_comb[b*8 +: 8] = scratch0_mem[b][scratch0_rd_addr];
      for (b = 0; b < 8; b = b + 1)
        scratch1_data_comb[b*32 +: 32] = scratch1_mem[b][scratch1_rd_addr_vec[b*8 +: 8]];
      for (b = 0; b < 4; b = b + 1) begin
        ded_weight_data_comb[b*32 +: 32] = ded_weight_mem[b][
          (ded_weight_project ? 7'd64 : 7'd0) +
          (ded_weight_group ? (ded_weight_project ? 7'd32 : 7'd16) : 7'd0) +
          ded_weight_k];
        pool_weight_data_comb[b*32 +: 32] = pool_weight_mem[b][
          (pool_weight_project ? 7'd64 : 7'd0) +
          (pool_weight_group ? (pool_weight_project ? 7'd32 : 7'd16) : 7'd0) +
          pool_weight_k];
      end
    end
    always @(posedge clk) begin
      if (rst_n) begin
        if (input_cfg_fire) input_mem[input_cfg_bank][input_cfg_row] <= cfg_data[7:0];
        for (b = 0; b < 16; b = b + 1)
          if (scratch0_wr_valid_vec[b])
            scratch0_mem[b][scratch0_wr_addr] <= scratch0_wr_data_vec[b*8 +: 8];
        if (scratch1_wr_valid) scratch1_mem[scratch1_wr_bank][scratch1_wr_addr] <= scratch1_wr_data;
        if (weight_cfg_fire) begin
          if (weight_cfg_be[0]) begin ded_weight_mem[weight_cfg_bank][weight_cfg_row][7:0] <= cfg_data[7:0]; pool_weight_mem[weight_cfg_bank][weight_cfg_row][7:0] <= cfg_data[7:0]; end
          if (weight_cfg_be[1]) begin ded_weight_mem[weight_cfg_bank][weight_cfg_row][15:8] <= cfg_data[7:0]; pool_weight_mem[weight_cfg_bank][weight_cfg_row][15:8] <= cfg_data[7:0]; end
          if (weight_cfg_be[2]) begin ded_weight_mem[weight_cfg_bank][weight_cfg_row][23:16] <= cfg_data[7:0]; pool_weight_mem[weight_cfg_bank][weight_cfg_row][23:16] <= cfg_data[7:0]; end
          if (weight_cfg_be[3]) begin ded_weight_mem[weight_cfg_bank][weight_cfg_row][31:24] <= cfg_data[7:0]; pool_weight_mem[weight_cfg_bank][weight_cfg_row][31:24] <= cfg_data[7:0]; end
        end
      end
    end
`else
    always @(posedge clk) begin
      if (!rst_n) begin
        input_resp_q <= 1'b0;
        scratch0_resp_q <= 1'b0;
        scratch1_resp_q <= 1'b0;
        ded_weight_resp_q <= 1'b0;
        pool_weight_resp_q <= 1'b0;
        ded_weight_resp_desc_q <= 16'd0;
        pool_weight_resp_desc_q <= 16'd0;
      end else begin
        input_resp_q <= |input_rd_valid;
        scratch0_resp_q <= scratch0_rd_valid;
        scratch1_resp_q <= |scratch1_rd_valid;
        if (ded_weight_resp_q && ded_weight_rd_resp_ready)
          ded_weight_resp_q <= 1'b0;
        if (pool_weight_resp_q && pool_weight_rd_resp_ready)
          pool_weight_resp_q <= 1'b0;
        if (ded_weight_rd_fire) begin
          ded_weight_resp_q <= 1'b1;
          ded_weight_resp_desc_q <= ded_weight_rd_desc;
        end
        if (pool_weight_rd_fire) begin
          pool_weight_resp_q <= 1'b1;
          pool_weight_resp_desc_q <= pool_weight_rd_desc;
        end
      end
    end
`endif

`ifndef SYNTHESIS
    assign input_rd_resp_valid = SYNC_READ ? input_resp_q : |input_rd_valid;
    assign scratch0_rd_resp_valid = SYNC_READ ? scratch0_resp_q : scratch0_rd_valid;
    assign scratch1_rd_resp_valid = SYNC_READ ? scratch1_resp_q : |scratch1_rd_valid;
    assign ded_weight_rd_resp_valid = SYNC_READ ? ded_weight_resp_q : ded_weight_rd_valid;
    assign pool_weight_rd_resp_valid = SYNC_READ ? pool_weight_resp_q : pool_weight_rd_valid;
    assign input_rd_data_vec = SYNC_READ ? input_data_q : input_data_comb;
    assign scratch0_rd_data = SYNC_READ ? scratch0_data_q : scratch0_data_comb;
    assign scratch1_rd_data_vec = SYNC_READ ? scratch1_data_q : scratch1_data_comb;
    assign ded_weight_rd_data = SYNC_READ ? ded_weight_data_q : ded_weight_data_comb;
    assign pool_weight_rd_data = SYNC_READ ? pool_weight_data_q : pool_weight_data_comb;
    assign ded_weight_rd_resp_desc = SYNC_READ ? ded_weight_resp_desc_q : ded_weight_rd_desc;
    assign pool_weight_rd_resp_desc = SYNC_READ ? pool_weight_resp_desc_q : pool_weight_rd_desc;
`else
    assign input_rd_resp_valid = input_resp_q;
    assign scratch0_rd_resp_valid = scratch0_resp_q;
    assign scratch1_rd_resp_valid = scratch1_resp_q;
    assign ded_weight_rd_resp_valid = ded_weight_resp_q;
    assign pool_weight_rd_resp_valid = pool_weight_resp_q;
    genvar od;
    generate
      for (od = 0; od < 8; od = od + 1) begin : gen_input_out
        assign input_rd_data_vec[od*8 +: 8] = input_dout[od];
        assign scratch1_rd_data_vec[od*32 +: 32] = scratch1_dout[od];
      end
      for (od = 0; od < 16; od = od + 1)
        assign scratch0_rd_data[od*8 +: 8] = scratch0_dout[od];
      for (od = 0; od < 4; od = od + 1) begin : gen_weight_out
        assign ded_weight_rd_data[od*32 +: 32] = ded_weight_dout[od];
        assign pool_weight_rd_data[od*32 +: 32] = pool_weight_dout[od];
      end
      assign ded_weight_rd_resp_desc = ded_weight_resp_desc_q;
      assign pool_weight_rd_resp_desc = pool_weight_resp_desc_q;
    endgenerate
`endif
endmodule

`default_nettype wire
