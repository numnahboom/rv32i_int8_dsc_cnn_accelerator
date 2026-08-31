`timescale 1ns/1ps
`default_nettype none

/*
 * Isolated, producer-driven DS dataflow vehicle.
 *
 * The input is the four-byte stream emitted by a 4x8 DW macro.  Two macros
 * (top and bottom) form one 8-pixel PW block.  A descriptor is published only
 * after the bottom macro has written the second four-channel half of the
 * final pixel for a K group.  The descriptor FIFO is deliberately narrow;
 * the PW side never reads a live owner/state bus.
 *
 * This module is a validation vehicle, not a cnn_top replacement.  It keeps
 * the arithmetic ABI of unified64_shared_compute_array and therefore checks
 * the real 64-product PW path, including first_k/last_k across all partial-K
 * groups.  The external testbench supplies non-zero DW data generated from a
 * deterministic reference and packed 8-weight rows.
 */
module ds_group_published_shared64_sweep #(
    parameter integer MAX_GROUPS = 16,
    parameter integer MAX_COUT_TILES = 32,
    parameter integer MAX_BLOCKS = 128,
    parameter integer DESC_DEPTH = 64
) (
    input wire clk,
    input wire rst_n,

    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_pixels,
    input wire [7:0] start_cin,
    input wire [8:0] start_cout,
    input wire start_bank,
    input wire [1:0] start_session,
    input wire [3:0] start_epoch,

    input wire dw_valid,
    output wire dw_ready,
    input wire [7:0] dw_macro,
    input wire [1:0] dw_row,
    input wire [4:0] dw_group,
    input wire dw_channel_half,
    input wire [2:0] dw_pixel,
    input wire [31:0] dw_data,
    input wire [3:0] dw_mask,
    input wire dw_last,

    input wire weight_load_valid,
    output wire weight_load_ready,
    input wire [4:0] weight_load_tile,
    input wire [7:0] weight_load_k,
    input wire signed [63:0] weight_load_vec,

    output wire result_valid,
    input wire result_ready,
    output wire [10:0] result_pixel_idx,
    output wire [8:0] result_channel_base,
    output wire [3:0] result_lane_mask,
    output wire signed [31:0] result_data,

    output reg done,
    output reg error,
    output reg [31:0] perf_total_cycles,
    output reg [31:0] perf_dw_writes,
    output reg [31:0] perf_group_descriptors,
    output reg [31:0] perf_pw_tokens,
    output reg [31:0] perf_output_writes,
    output reg [31:0] perf_output_groups,
    output reg [31:0] perf_preload_rows
);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    localparam integer DESC_PTR_W = (DESC_DEPTH <= 1) ? 1 : $clog2(DESC_DEPTH);
    localparam integer DESC_CNT_W = $clog2(DESC_DEPTH+1);

    reg [1:0] state;
    reg [10:0] pixels_q;
    reg [7:0] cin_q;
    reg [8:0] cout_q;
    reg [1:0] session_q;
    reg [3:0] epoch_q;
    reg input_done_q;
    reg schedule_done_q;
    reg [7:0] block_count_q, row_count_q, group_count_q;
    reg [5:0] cout_tile_count_q;

    /*
     * Physical storage is deliberately shaped as fixed-width row records.
     * The previous [group][row][pixel][half] arrays put a variable part
     * select below several variable array indices.  Vivado expanded that
     * expression into a very large LUT/mux network before it could honour
     * ram_style, and the OOC synth process exhausted host memory.  A row is
     * exactly eight 32-bit pixel beats, so four fixed 256-bit memories are
     * the natural banked representation:
     *
     *   address = {group[3:0], row[1:0]}
     *   data    = {pixel7, ..., pixel0}
     *
     * The DW macro emits one pixel beat at a time.  The eight beats are
     * assembled in a small write register and committed once at pixel 7;
     * this keeps arbitrary bank/half selection out of the BRAM data mux and
     * leaves only one narrow row write per completed half.  The producer
     * contract is pixel-ordered within each half (the same contract used by
     * the 4x8 macro), while the read side remains fully row-addressed.
     */
    localparam integer WEIGHT_DEPTH = MAX_COUT_TILES * 128;
    localparam integer SCRATCH_DEPTH = MAX_GROUPS * 4;
`ifndef SYNTHESIS
    (* ram_style = "block" *) reg signed [63:0] weight_mem [0:WEIGHT_DEPTH-1];
    (* ram_style = "block" *) reg [255:0] scratch0_top [0:SCRATCH_DEPTH-1];
    (* ram_style = "block" *) reg [255:0] scratch0_bottom [0:SCRATCH_DEPTH-1];
    (* ram_style = "block" *) reg [255:0] scratch1_top [0:SCRATCH_DEPTH-1];
    (* ram_style = "block" *) reg [255:0] scratch1_bottom [0:SCRATCH_DEPTH-1];
`else
    /* The implementation view uses explicit synchronous XPM SDP memories.
     * The read data is intentionally one registered BRAM response behind
     * the address; this OOC vehicle is a physical storage screen, while the
     * untimed reference view above remains the cycle-accurate contract. */
    wire signed [63:0] weight_mem_rd;
    wire [255:0] scratch0_top_rd, scratch0_bottom_rd;
    wire [255:0] scratch1_top_rd, scratch1_bottom_rd;
`endif
    /*
     * The XPMs below have READ_LATENCY_B=1.  Keep the untimed reference
     * view on the same contract: a request is sampled at an edge and its
     * response is visible during the following cycle.  The registered data
     * is qualified by the local publication token below, so a stalled PW
     * consumer holds both the data and its schedule token.
     */
`ifndef SYNTHESIS
    reg signed [63:0] weight_mem_rd;
    reg [255:0] scratch0_top_rd, scratch0_bottom_rd;
    reg [255:0] scratch1_top_rd, scratch1_bottom_rd;
`endif
    reg [31:0] scratch_wr_word0, scratch_wr_word1;
    reg [31:0] scratch_wr_word2, scratch_wr_word3;
    reg [31:0] scratch_wr_word4, scratch_wr_word5;
    reg [31:0] scratch_wr_word6, scratch_wr_word7;
    reg bank_busy0, bank_busy1;
    reg [7:0] bank_block0, bank_block1;

    /* Published bits are reached only through the narrow FIFO below. */
    reg [MAX_GROUPS-1:0] published0 [0:3], published1 [0:3];
    reg desc_bank [0:DESC_DEPTH-1];
    reg [1:0] desc_session [0:DESC_DEPTH-1];
    reg [3:0] desc_epoch [0:DESC_DEPTH-1];
    reg [7:0] desc_block [0:DESC_DEPTH-1];
    reg [7:0] desc_macro [0:DESC_DEPTH-1];
    reg [2:0] desc_row [0:DESC_DEPTH-1];
    reg [4:0] desc_group [0:DESC_DEPTH-1];
    reg [7:0] desc_k_base [0:DESC_DEPTH-1];
    reg [7:0] desc_k_count [0:DESC_DEPTH-1];
    reg [7:0] desc_mask [0:DESC_DEPTH-1];
    reg desc_commit [0:DESC_DEPTH-1];
    reg [DESC_PTR_W-1:0] desc_wr_ptr, desc_rd_ptr;
    reg [DESC_CNT_W-1:0] desc_count;
    /* A published descriptor is acknowledged immediately, but advance the
     * descriptor cursor from a registered pulse.  This keeps the dynamic
     * descriptor-array match cone off the desc_rd_ptr next-state path. */
    reg desc_pop_pending;

    wire start_fire = start_valid && start_ready;
    assign start_ready = rst_n && (state == S_IDLE) && !weight_load_valid;
    assign weight_load_ready = rst_n && (state == S_IDLE) && !start_valid;
    wire weight_load_fire = weight_load_valid && weight_load_ready;

    wire dw_bank = dw_macro[0];
    wire same_bank_block = dw_bank ?
        (bank_busy1 && bank_block1 == dw_macro) :
        (bank_busy0 && bank_block0 == dw_macro);
    wire bank_free = dw_bank ? !bank_busy1 : !bank_busy0;
    wire desc_room = (desc_count < DESC_DEPTH);
    assign dw_ready = rst_n && (state == S_RUN) && desc_room &&
                      (bank_free || same_bank_block);
    wire dw_fire = dw_valid && dw_ready;
    wire group_last_beat = dw_channel_half && (dw_pixel == 3'd7);
    wire group_desc_fire = dw_fire && group_last_beat;

    /* PW schedule is block -> Cout tile -> K group -> K row. */
    reg [7:0] pw_row_block_q;
    reg [5:0] pw_tile_q;
    reg [4:0] pw_group_q;
    reg [3:0] pw_k_q;
    wire [10:0] pw_pixel_base = {pw_row_block_q,3'd0};
    wire [11:0] pw_pixel_rem = {1'b0,pixels_q} - {1'b0,pw_pixel_base};
    wire [7:0] pixel_mask_q = (pw_pixel_rem >= 12'd8) ? 8'hff :
        ((pw_pixel_rem == 0) ? 8'd0 : ((8'h01 << pw_pixel_rem) - 1'b1));
    wire [11:0] cout_rem = {3'd0,cout_q} - {3'd0, pw_tile_q, 3'd0};
    wire [7:0] cout_mask_q = (cout_rem >= 12'd8) ? 8'hff :
        ((cout_rem == 0) ? 8'd0 : ((8'h01 << cout_rem) - 1'b1));
    wire [7:0] pw_macro_q = pw_row_block_q >> 2;
    wire [1:0] pw_row_q = pw_row_block_q[1:0];
    wire pw_bank = pw_macro_q[0];
    wire pw_published = pw_bank ? published1[pw_row_q][pw_group_q] :
                                  published0[pw_row_q][pw_group_q];
    wire pw_final_group = (pw_group_q + 1'b1 >= group_count_q);
    wire [7:0] pw_group_k_count = pw_final_group ?
        (cin_q - ({3'd0,pw_group_q} << 3)) : 8'd8;
    wire pw_final_k = (pw_k_q + 1'b1 >= pw_group_k_count);
    /* A synchronous BRAM response is continuously present one cycle after
     * the address sampled at the read port.  The published bit is the local
     * response-valid token: a row is published only after its final write,
     * and the read address is held on that row while the shared array is
     * stalled.  This keeps the simulation and XPM views on identical
     * registered-memory semantics without adding a per-token bubble. */
    /* Valid fans into the 64-product bank enables.  Ask synthesis to keep
     * this control net local/replicated; otherwise a row publication bit can
     * become a long cross-array route even though the arithmetic ABI is
     * unchanged. */
    (* max_fanout = 64 *) wire pw_token_valid =
        (state == S_RUN) && !schedule_done_q && pw_published;

    /* Narrow descriptor consumer.  It turns publication into a local bit and
     * removes all descriptor/owner metadata from the arithmetic input cone. */
    wire desc_head_valid = (desc_count != 0);
    wire desc_head_match = desc_head_valid &&
        (desc_macro[desc_rd_ptr] == pw_macro_q) &&
        (desc_row[desc_rd_ptr] == pw_row_q) &&
        (desc_session[desc_rd_ptr] == session_q) &&
        (desc_epoch[desc_rd_ptr] == epoch_q) &&
        (desc_group[desc_rd_ptr] == pw_group_q) &&
        !pw_published;
    wire desc_pop_fire = (state == S_RUN) && desc_head_match;

    /* Fixed rowstore lookup.  k is bounded by 127 and never participates in
     * a division or dynamic physical address calculation. */
    /* Flattened physical addresses keep tile selection out of a nested
     * variable array dereference.  Only the low four group bits are used;
     * start validation bounds groups to MAX_GROUPS (16 in this vehicle). */
    wire [11:0] pw_weight_addr = {pw_tile_q[4:0], pw_group_q[3:0], pw_k_q[2:0]};
    /* Look ahead on the cycle which consumes a response.  This lets the
     * synchronous BRAM accept the next address at the same edge, preserving
     * II=1 in the common case without pretending that BRAM reads are
     * combinational. */
    wire [7:0] rd_issue_row_block;
    wire [5:0] rd_issue_tile;
    wire [4:0] rd_issue_group;
    wire [3:0] rd_issue_k;
    wire pw_token_fire = pw_token_valid && core_ready;
    wire [7:0] rd_next_row = (pw_row_block_q + 1'b1);
    wire [5:0] rd_next_tile = (pw_tile_q + 1'b1);
    wire [4:0] rd_next_group = (pw_group_q + 1'b1);
    wire [3:0] rd_next_k = (pw_k_q + 1'b1);
    assign rd_issue_k = (!pw_token_fire) ? pw_k_q :
                         (pw_final_k ? 4'd0 : rd_next_k[3:0]);
    assign rd_issue_group = (!pw_token_fire) ? pw_group_q :
                            (pw_final_k ?
                             (pw_final_group ? 5'd0 : rd_next_group) :
                             pw_group_q);
    assign rd_issue_tile = (!pw_token_fire) ? pw_tile_q :
                           (pw_final_k && pw_final_group &&
                            (pw_tile_q + 1'b1 >= cout_tile_count_q) ?
                            6'd0 :
                            (pw_final_k && pw_final_group ?
                             rd_next_tile : pw_tile_q));
    assign rd_issue_row_block = (!pw_token_fire) ? pw_row_block_q :
                                (pw_final_k && pw_final_group &&
                                 (pw_tile_q + 1'b1 >= cout_tile_count_q) ?
                                 rd_next_row : pw_row_block_q);
    wire [11:0] rd_issue_weight_addr =
        {rd_issue_tile[4:0], rd_issue_group[3:0], rd_issue_k[2:0]};
    wire [5:0] rd_issue_scratch_addr =
        {rd_issue_group[3:0], rd_issue_row_block[1:0]};
    wire rd_issue_bank = (rd_issue_row_block[7:2] & 1'b1);
`ifndef SYNTHESIS
    wire signed [63:0] pw_wgt_row = weight_mem_rd;
`else
    wire signed [63:0] pw_wgt_row = weight_mem_rd;
`endif
    wire [5:0] pw_scratch_addr = {pw_group_q[3:0], pw_row_q};
`ifndef SYNTHESIS
    wire [255:0] pw_top_row = pw_bank ? scratch1_top_rd : scratch0_top_rd;
    wire [255:0] pw_bottom_row = pw_bank ? scratch1_bottom_rd : scratch0_bottom_rd;
`else
    wire [255:0] pw_top_row = pw_bank ? scratch1_top_rd : scratch0_top_rd;
    wire [255:0] pw_bottom_row = pw_bank ? scratch1_bottom_rd : scratch0_bottom_rd;
`endif

    /* A four-way byte selector is substantially smaller than a variable
     * part-select over the complete 256-bit row.  The eight pixel words are
     * statically sliced, so synthesis sees eight local 32-bit muxes. */
    function automatic [7:0] row_byte;
        input [31:0] word;
        input [1:0] byte_index;
        begin
            case (byte_index)
                2'd0: row_byte = word[7:0];
                2'd1: row_byte = word[15:8];
                2'd2: row_byte = word[23:16];
                default: row_byte = word[31:24];
            endcase
        end
    endfunction

`ifdef SYNTHESIS
    /* Fixed physical memory ports.  The four scratch instances are
     * independent {bank,half} regions, so a bank/half select cannot create a
     * 1024-entry variable read mux.  XPM maps each 256-bit row to local
     * RAMB36 primitives and provides the explicit one-cycle read boundary. */
    wire [255:0] scratch_wr_data =
        {dw_data, scratch_wr_word6, scratch_wr_word5, scratch_wr_word4,
         scratch_wr_word3, scratch_wr_word2, scratch_wr_word1,
         scratch_wr_word0};
    wire scratch_row_write_fire = dw_fire && (dw_pixel == 3'd7);
    genvar sm;
    generate
        for (sm = 0; sm < 4; sm = sm + 1) begin : gen_scratch_bram
            wire sm_bank = sm[1];
            wire sm_half = sm[0];
            wire sm_write = scratch_row_write_fire && (dw_bank == sm_bank) &&
                            (dw_channel_half == sm_half);
            wire [255:0] sm_read_data;
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A(6), .ADDR_WIDTH_B(6), .AUTO_SLEEP_TIME(0),
                .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
                .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
                .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
                .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
                .MEMORY_SIZE(SCRATCH_DEPTH*256), .MESSAGE_CONTROL(0),
                .READ_DATA_WIDTH_B(256), .READ_LATENCY_B(1),
                .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
                .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
                .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
                .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(256),
                .WRITE_MODE_B("read_first")
            ) u_scratch_mem (
                /* Keep the BRAM read port enabled throughout RUN.  The
                 * request/response valid protocol below qualifies the data;
                 * using the narrow state bit here prevents the long
                 * scheduler->ENARDEN control cone from becoming a timing
                 * path while preserving synchronous read behavior. */
                .clka(clk), .clkb(clk), .ena(sm_write), .enb(state == S_RUN),
                .addra({dw_group[3:0],dw_row}), .addrb(rd_issue_scratch_addr),
                .dina(scratch_wr_data), .wea(32'hffff_ffff),
                .doutb(sm_read_data), .regceb(1'b1), .rstb(!rst_n),
                .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
                .dbiterrb(), .sbiterrb()
            );
            if (sm == 0) begin : gen_scratch0_top
                assign scratch0_top_rd = sm_read_data;
            end else if (sm == 1) begin : gen_scratch0_bottom
                assign scratch0_bottom_rd = sm_read_data;
            end else if (sm == 2) begin : gen_scratch1_top
                assign scratch1_top_rd = sm_read_data;
            end else begin : gen_scratch1_bottom
                assign scratch1_bottom_rd = sm_read_data;
            end
        end
    endgenerate

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(WEIGHT_DEPTH*64), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(64),
        .WRITE_MODE_B("read_first")
    ) u_weight_mem (
        .clka(clk), .clkb(clk), .ena(weight_load_fire),
        .enb(state == S_RUN), .addra({weight_load_tile,weight_load_k[6:0]}),
        .addrb(rd_issue_weight_addr), .dina(weight_load_vec), .wea(8'hff),
        .doutb(weight_mem_rd), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`endif

    reg signed [63:0] pw_act_vec;
    integer ap;
    always @* begin
        pw_act_vec = 64'sd0;
        for (ap = 0; ap < 8; ap = ap + 1) begin
            if (pw_k_q < 4)
                pw_act_vec[ap*8 +: 8] = row_byte(pw_top_row[ap*32 +: 32], pw_k_q[1:0]);
            else
                pw_act_vec[ap*8 +: 8] = row_byte(pw_bottom_row[ap*32 +: 32], pw_k_q[1:0]);
        end
    end

    reg signed [511:0] zero_bias, unit_multiplier;
    reg [95:0] zero_shift;
    integer zi;
    always @* begin
        zero_bias = 512'sd0;
        unit_multiplier = 512'sd0;
        zero_shift = 96'd0;
        for (zi = 0; zi < 16; zi = zi + 1)
            unit_multiplier[zi*32 +: 32] = 32'sh4000_0000;
    end

    wire core_ready;
    wire core_valid;
    wire [10:0] core_pixel;
    wire [8:0] core_cout;
    wire [3:0] core_mask;
    wire signed [31:0] core_data;
    wire core_busy;
    wire [31:0] core_metric_tokens, core_metric_macs, core_metric_commits;

    unified64_shared_compute_array u_shared_ds (
        .clk(clk), .rst_n(rst_n), .mode_stem(1'b0),
        .valid_in(pw_token_valid), .ready_in(core_ready),
        .first_k((pw_group_q == 0) && (pw_k_q == 0)),
        .last_k(pw_final_group && pw_final_k),
        .k_idx(({3'd0,pw_group_q} << 3) + pw_k_q),
        .act_vec(pw_act_vec), .wgt_vec16({64'd0,pw_wgt_row}),
        .pixel_mask(pixel_mask_q), .cout_mask({8'd0,cout_mask_q}),
        .pixel_base(pw_pixel_base),
        .cout_base({pw_tile_q,3'd0}),
        .bias_vec(zero_bias), .multiplier_vec(unit_multiplier),
        .shift_vec(zero_shift), .output_zero_point_int32(32'sd0),
        .activation_min_int32(-32'sd128), .activation_max_int32(32'sd127),
        .ready_out(result_ready), .valid_out(core_valid),
        .out_pixel_idx(core_pixel), .out_channel_base(core_cout),
        .out_lane_mask(core_mask), .out_data(core_data), .busy(core_busy),
        .metric_token_count(core_metric_tokens),
        .metric_masked_mac_count(core_metric_macs),
        .metric_commit_count(core_metric_commits)
    );
    assign result_valid = core_valid;
    assign result_pixel_idx = core_pixel;
    assign result_channel_base = core_cout;
    assign result_lane_mask = core_mask;
    assign result_data = core_data;
    wire result_fire = result_valid && result_ready;
    wire result_group_final = result_fire &&
        (core_pixel[2:0] == 3'd7) && (core_cout[2:0] == 3'd4);
    wire result_row_final = result_group_final &&
        ({3'd0,core_cout} + 9'd4 >= cout_q);

    /* Output-group count is used only for the layer fence and metrics. */
    reg [31:0] completed_output_groups_q;
    /* Captured layer fence.  Keeping the shape multiplication at start
     * removes cout_tile_count/row_count arithmetic from the hot RUN->DONE
     * state-decision cone. */
    reg [31:0] target_output_groups_q;
    reg input_last_seen_q;
    integer ri, rj, rk;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; error <= 1'b0;
`ifndef SYNTHESIS
            weight_mem_rd <= 0;
            scratch0_top_rd <= 0; scratch0_bottom_rd <= 0;
            scratch1_top_rd <= 0; scratch1_bottom_rd <= 0;
`endif
            pixels_q <= 0; cin_q <= 0; cout_q <= 0;
            session_q <= 0; epoch_q <= 0; input_done_q <= 0;
            schedule_done_q <= 0; block_count_q <= 0; row_count_q <= 0; group_count_q <= 0;
            cout_tile_count_q <= 0;
            bank_busy0 <= 0; bank_busy1 <= 0; bank_block0 <= 0; bank_block1 <= 0;
            for (ri = 0; ri < 4; ri = ri + 1) begin
                published0[ri] <= 0; published1[ri] <= 0;
            end
            desc_wr_ptr <= 0; desc_rd_ptr <= 0; desc_count <= 0;
            desc_pop_pending <= 1'b0;
            pw_row_block_q <= 0; pw_tile_q <= 0; pw_group_q <= 0; pw_k_q <= 0;
            scratch_wr_word0 <= 0; scratch_wr_word1 <= 0;
            scratch_wr_word2 <= 0; scratch_wr_word3 <= 0;
            scratch_wr_word4 <= 0; scratch_wr_word5 <= 0;
            scratch_wr_word6 <= 0; scratch_wr_word7 <= 0;
            completed_output_groups_q <= 0; target_output_groups_q <= 0;
            input_last_seen_q <= 0;
            perf_total_cycles <= 0; perf_dw_writes <= 0;
            perf_group_descriptors <= 0; perf_pw_tokens <= 0;
            perf_output_writes <= 0; perf_output_groups <= 0;
            perf_preload_rows <= 0;
            for (ri = 0; ri < DESC_DEPTH; ri = ri + 1) begin
                desc_bank[ri] <= 0; desc_session[ri] <= 0; desc_epoch[ri] <= 0;
                desc_block[ri] <= 0; desc_macro[ri] <= 0;
                desc_row[ri] <= 0; desc_group[ri] <= 0; desc_k_base[ri] <= 0;
                desc_k_count[ri] <= 0; desc_mask[ri] <= 0; desc_commit[ri] <= 0;
            end
        end else begin
            done <= 1'b0;
            /* Model the synchronous XPM read ports in the Verilator view.
             * The nonblocking assignments intentionally observe the old
             * array contents on a simultaneous row write, matching the
             * READ_FIRST physical configuration. */
            if (state == S_RUN) begin
`ifndef SYNTHESIS
                /* XPM is READ_FIRST and the nonblocking ordering below
                 * observes the pre-edge contents on a simultaneous write. */
                weight_mem_rd <= weight_mem[rd_issue_weight_addr];
                scratch0_top_rd <= scratch0_top[rd_issue_scratch_addr];
                scratch0_bottom_rd <= scratch0_bottom[rd_issue_scratch_addr];
                scratch1_top_rd <= scratch1_top[rd_issue_scratch_addr];
                scratch1_bottom_rd <= scratch1_bottom[rd_issue_scratch_addr];
`endif
            end
            if (weight_load_fire) begin
`ifndef SYNTHESIS
                weight_mem[{weight_load_tile, weight_load_k[6:0]}] <= weight_load_vec;
`endif
                perf_preload_rows <= perf_preload_rows + 1'b1;
            end
            if (start_fire) begin
                if ((start_pixels == 0) || (start_cin == 0) || (start_cout == 0) ||
                    (start_pixels > MAX_BLOCKS*32) || (start_cin > MAX_GROUPS*8) ||
                    (start_cout > MAX_COUT_TILES*8)) begin
                    error <= 1'b1; done <= 1'b1;
                end else begin
                    state <= S_RUN;
                    pixels_q <= start_pixels; cin_q <= start_cin; cout_q <= start_cout;
                    session_q <= start_session; epoch_q <= start_epoch;
                    block_count_q <= (start_pixels + 31) >> 5;
                    row_count_q <= (start_pixels + 7) >> 3;
                    group_count_q <= (start_cin + 7) >> 3;
                    cout_tile_count_q <= (start_cout + 7) >> 3;
                    target_output_groups_q <= ((start_pixels + 7) >> 3) *
                                              ((start_cout + 7) >> 3);
                    input_done_q <= 0; schedule_done_q <= 0; input_last_seen_q <= 0;
                    bank_busy0 <= 0; bank_busy1 <= 0;
                    for (ri = 0; ri < 4; ri = ri + 1) begin
                        published0[ri] <= 0; published1[ri] <= 0;
                    end
                    desc_wr_ptr <= 0; desc_rd_ptr <= 0; desc_count <= 0;
                    desc_pop_pending <= 1'b0;
                    pw_row_block_q <= 0; pw_tile_q <= 0; pw_group_q <= 0; pw_k_q <= 0;
                    completed_output_groups_q <= 0;
                    perf_total_cycles <= 0; perf_dw_writes <= 0;
                    perf_group_descriptors <= 0; perf_pw_tokens <= 0;
                    perf_output_writes <= 0; perf_output_groups <= 0;
                end
            end

            if (state == S_RUN)
                perf_total_cycles <= perf_total_cycles + 1'b1;
            if (dw_fire) begin
                perf_dw_writes <= perf_dw_writes + 1'b1;
                if (dw_last) begin input_done_q <= 1'b1; input_last_seen_q <= 1'b1; end
                if (dw_bank) begin
                    if (!bank_busy1) begin bank_busy1 <= 1'b1; bank_block1 <= dw_macro; end
                end else begin
                    if (!bank_busy0) begin bank_busy0 <= 1'b1; bank_block0 <= dw_macro; end
                end
                /* Assemble one fixed row record.  Pixel order is part of
                 * the 4x8 producer ABI; at pixel 7 the old word registers
                 * contain pixels 0..6 and the current beat supplies pixel 7. */
                case (dw_pixel)
                    3'd0: scratch_wr_word0 <= dw_data;
                    3'd1: scratch_wr_word1 <= dw_data;
                    3'd2: scratch_wr_word2 <= dw_data;
                    3'd3: scratch_wr_word3 <= dw_data;
                    3'd4: scratch_wr_word4 <= dw_data;
                    3'd5: scratch_wr_word5 <= dw_data;
                    3'd6: scratch_wr_word6 <= dw_data;
                    default: scratch_wr_word7 <= dw_data;
                endcase
                if (dw_pixel == 3'd7) begin
`ifndef SYNTHESIS
                    if (dw_bank) begin
                        if (dw_channel_half)
                            scratch1_bottom[{dw_group[3:0],dw_row}] <=
                                {dw_data, scratch_wr_word6, scratch_wr_word5,
                                 scratch_wr_word4, scratch_wr_word3,
                                 scratch_wr_word2, scratch_wr_word1,
                                 scratch_wr_word0};
                        else
                            scratch1_top[{dw_group[3:0],dw_row}] <=
                                {dw_data, scratch_wr_word6, scratch_wr_word5,
                                 scratch_wr_word4, scratch_wr_word3,
                                 scratch_wr_word2, scratch_wr_word1,
                                 scratch_wr_word0};
                    end else begin
                        if (dw_channel_half)
                            scratch0_bottom[{dw_group[3:0],dw_row}] <=
                                {dw_data, scratch_wr_word6, scratch_wr_word5,
                                 scratch_wr_word4, scratch_wr_word3,
                                 scratch_wr_word2, scratch_wr_word1,
                                 scratch_wr_word0};
                        else
                            scratch0_top[{dw_group[3:0],dw_row}] <=
                                {dw_data, scratch_wr_word6, scratch_wr_word5,
                                 scratch_wr_word4, scratch_wr_word3,
                                 scratch_wr_word2, scratch_wr_word1,
                                 scratch_wr_word0};
                    end
`endif
                end
                if (group_desc_fire) begin
                    desc_bank[desc_wr_ptr] <= dw_bank;
                    desc_session[desc_wr_ptr] <= session_q;
                    desc_epoch[desc_wr_ptr] <= epoch_q;
                    desc_block[desc_wr_ptr] <= dw_macro;
                    desc_macro[desc_wr_ptr] <= dw_macro;
                    desc_row[desc_wr_ptr] <= dw_row;
                    desc_group[desc_wr_ptr] <= dw_group;
                    desc_k_base[desc_wr_ptr] <= {3'd0,dw_group,3'd0};
                    desc_k_count[desc_wr_ptr] <=
                        (dw_group + 1'b1 >= group_count_q) ?
                        (cin_q - ({3'd0,dw_group} << 3)) : 8'd8;
                    desc_mask[desc_wr_ptr] <= pixel_mask_q;
                    desc_commit[desc_wr_ptr] <= 1'b1;
                    desc_wr_ptr <= desc_wr_ptr + 1'b1;
                    perf_group_descriptors <= perf_group_descriptors + 1'b1;
                end
            end
            if (desc_pop_fire) begin
                if (desc_bank[desc_rd_ptr])
                    published1[desc_row[desc_rd_ptr]][desc_group[desc_rd_ptr]] <= 1'b1;
                else
                    published0[desc_row[desc_rd_ptr]][desc_group[desc_rd_ptr]] <= 1'b1;
                desc_pop_pending <= 1'b1;
            end
            /* The publication above makes desc_pop_fire false for this
             * descriptor during the intervening cycle.  Advancing from the
             * registered pulse adds one descriptor bubble but removes the
             * long pointer->array-match->pointer route. */
            if (desc_pop_pending) begin
                desc_rd_ptr <= desc_rd_ptr + 1'b1;
                desc_pop_pending <= 1'b0;
            end
            case ({group_desc_fire, desc_pop_fire})
                2'b10: desc_count <= desc_count + 1'b1;
                2'b01: desc_count <= desc_count - 1'b1;
                default: ;
            endcase

            if (pw_token_fire) begin
                perf_pw_tokens <= perf_pw_tokens + 1'b1;
                if (pw_final_k) begin
                    pw_k_q <= 0;
                    if (pw_final_group) begin
                        pw_group_q <= 0;
                        if (pw_tile_q + 1'b1 >= cout_tile_count_q) begin
                            pw_tile_q <= 0;
                            if (pw_row_block_q + 1'b1 >= row_count_q)
                                schedule_done_q <= 1'b1;
                            else
                                pw_row_block_q <= pw_row_block_q + 1'b1;
                        end else begin
                            pw_tile_q <= pw_tile_q + 1'b1;
                        end
                    end else begin
                        pw_group_q <= pw_group_q + 1'b1;
                    end
                end else begin
                    pw_k_q <= pw_k_q + 1'b1;
                end
            end

            if (result_fire) begin
                perf_output_writes <= perf_output_writes + 1'b1;
                if (result_group_final) begin
                    perf_output_groups <= perf_output_groups + 1'b1;
                    completed_output_groups_q <= completed_output_groups_q + 1'b1;
                end
                /* A row remains published while all Cout tiles reuse it.
                 * Release the row only after the final Cout tile; release
                 * the bank after the final row of the 4x8 macro. */
                if (result_row_final) begin
                    if (core_pixel[5]) begin
                        published1[core_pixel[4:3]] <= 0;
                        if ((core_pixel[4:3] == 2'd3) ||
                            (core_pixel[10:3] + 1'b1 >= row_count_q))
                            bank_busy1 <= 1'b0;
                    end else begin
                        published0[core_pixel[4:3]] <= 0;
                        if ((core_pixel[4:3] == 2'd3) ||
                            (core_pixel[10:3] + 1'b1 >= row_count_q))
                            bank_busy0 <= 1'b0;
                    end
                end
            end

            if (!start_fire && input_done_q && schedule_done_q && !core_busy &&
                (completed_output_groups_q >= target_output_groups_q)) begin
                state <= S_DONE;
            end
            if (state == S_DONE) begin done <= 1'b1; state <= S_IDLE; end
        end
    end
endmodule

`default_nettype wire
