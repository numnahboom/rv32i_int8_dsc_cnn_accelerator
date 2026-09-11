`timescale 1ns/1ps
`default_nettype none

/*
 * Isolated, producer-driven DS dataflow vehicle.
 *
 * The input is the four-byte stream emitted by a 4x8 DW macro.  Two macros
 * (top and bottom) form one 8-pixel PW block.  A publication token is generated
 * only after the bottom macro has written the second four-channel half of the
 * final pixel for a K group.  The PW side consumes only tagged completed
 * row/group slots.
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
    parameter integer DESC_DEPTH = 64,
    parameter integer USE_EXTERNAL_MEM = 0
) (
    input wire clk,
    input wire rst_n,

    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_pixels,
    /* Output geometry is part of the schedule contract.  A linear pixel
     * count is insufficient for a four-pixel-wide tail: one eight-pixel PW
     * block must remain inside one DW row so the scratch row can be consumed
     * without crossing its synchronous read boundary. */
    input wire [10:0] start_output_height,
    input wire [10:0] start_output_width,
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

    /* Per-output-channel PW requant parameters are loaded before start.  The
     * shared array consumes an eight-lane slice selected by pw_tile_q, so
     * this preserves the scalar descriptor parameter ABI without carrying a
     * wide dynamic parameter mux through the producer path. */
    input wire pw_param_load_valid,
    output wire pw_param_load_ready,
    input wire [8:0] pw_param_load_channel,
    input wire signed [31:0] pw_param_load_bias,
    input wire signed [31:0] pw_param_load_multiplier,
    input wire [5:0] pw_param_load_shift,
    /* In the bridge configuration the adapter owns the physical memories.
     * These are one-cycle request/response ports; response address is the
     * tile-tagged parameter row, so the cache cannot consume a stale tile. */
    output wire pw_weight_req_valid,
    output wire pw_weight_req_ready,
    output wire [11:0] pw_weight_req_addr,
    /* A request-register adapter flushes a held response when the sweep
     * leaves S_RUN (for example while the tagged parameter tile is reloaded).
     * This is internal to the bridge and keeps a stale XPM response from
     * crossing a tile/layer fence. */
    output wire pw_weight_req_cancel,
    input wire pw_weight_resp_valid,
    input wire [11:0] pw_weight_resp_addr,
    input wire signed [63:0] pw_weight_resp_data,
    output wire pw_param_req_valid,
    output wire pw_param_req_ready,
    output wire [7:0] pw_param_req_addr,
    input wire pw_param_resp_valid,
    input wire [7:0] pw_param_resp_addr,
    input wire [71:0] pw_param_resp_data,
    input wire signed [31:0] pw_output_zero_point_int32,
    input wire signed [31:0] pw_activation_min_int32,
    input wire signed [31:0] pw_activation_max_int32,

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
    localparam [2:0] S_IDLE = 3'd0, S_RUN = 3'd1, S_DONE = 3'd2,
                     S_PARAM = 3'd3, S_SETUP_GEOM = 3'd4,
                     S_SETUP_ROWS = 3'd5, S_SETUP_TARGET = 3'd6;

    reg [2:0] state;
    reg [10:0] pixels_q;
    reg [10:0] output_height_q, output_width_q;
    reg [10:0] tile_cols_q;
    reg [7:0] cin_q;
    reg [8:0] cout_q;
    reg [10:0] raw_pixels_q, raw_output_height_q, raw_output_width_q;
    reg [7:0] raw_cin_q;
    reg [8:0] raw_cout_q;
    reg setup_fence_q;
    reg [1:0] session_q;
    reg [3:0] epoch_q;
    reg input_done_q;
    reg schedule_done_q;
    reg [7:0] block_count_q, row_count_q, group_count_q;
    reg [5:0] cout_tile_count_q;

    /* Shape setup is intentionally split from the start handshake.  The
     * runner commits raw descriptor fields first, then this FSM publishes
     * geometry, row count, and the output-group fence in separate cycles.
     * This keeps the descriptor-derived multipliers out of the start->target
     * register timing interval and gives the fence an explicit valid point. */
    wire [10:0] setup_out_h_calc = (raw_output_height_q == 0) ?
                                    ((raw_pixels_q + 7) >> 3) :
                                    raw_output_height_q;
    wire [10:0] setup_out_w_calc = (raw_output_width_q == 0) ?
                                    11'd8 : raw_output_width_q;
    wire [10:0] setup_tile_cols_calc = (setup_out_w_calc + 7) >> 3;
    wire [7:0] setup_block_count_calc = (setup_out_h_calc + 3) >> 2;
    wire [7:0] setup_group_count_calc = (raw_cin_q + 7) >> 3;
    wire [5:0] setup_cout_tile_count_calc = (raw_cout_q + 7) >> 3;
    wire [15:0] setup_geometry_rows_calc =
        ({8'd0,block_count_q} * {5'd0,tile_cols_q}) * 16'd4;
    wire [7:0] setup_legacy_rows_calc = (raw_pixels_q + 7) >> 3;

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
    localparam integer PW_PARAM_DEPTH = MAX_COUT_TILES * 8;
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

    /* Direct-index publication tokens retain each completed row/group. */
    reg [MAX_GROUPS-1:0] published0 [0:3], published1 [0:3];
    reg [3:0] slot_generation0 [0:3][0:MAX_GROUPS-1];
    reg [3:0] slot_generation1 [0:3][0:MAX_GROUPS-1];
    /* The epoch/session fence is resolved when a row is published, rather
     * than re-comparing the wide generation array in the per-token address
     * cone.  slot_generation remains the retained tag used to identify the
     * publication; slot_epoch_valid is its registered validity result and is
     * cleared together with the slot on bank reuse. */
    reg slot_epoch_valid0 [0:3][0:MAX_GROUPS-1];
    reg slot_epoch_valid1 [0:3][0:MAX_GROUPS-1];
    reg [1:0] bank_session0, bank_session1;
    reg [3:0] bank_epoch0, bank_epoch1;
`ifndef SYNTHESIS
    reg signed [31:0] pw_bias_mem [0:PW_PARAM_DEPTH-1];
    reg signed [31:0] pw_multiplier_mem [0:PW_PARAM_DEPTH-1];
    reg [5:0] pw_shift_mem [0:PW_PARAM_DEPTH-1];
`endif

    /* Only two eight-lane parameter tiles are retained in the external-memory
     * implementation.  The next tile may be filled while the current tile is
     * being consumed; first_k..last_k always select the tagged current cache. */
    reg signed [31:0] pw_bias_cache [0:1][0:7];
    reg signed [31:0] pw_multiplier_cache [0:1][0:7];
    reg [5:0] pw_shift_cache [0:1][0:7];
    reg [2:0] param_req_lane_q;
    reg [2:0] param_resp_count_q;
    reg [5:0] param_cache_tile_q [0:1];
    reg [1:0] param_cache_valid_q;
    reg param_active_bank_q, param_load_bank_q;
    reg param_prefetch_active_q;
    reg [2:0] param_prefetch_lane_q;
    reg [5:0] param_prefetch_tile_q;
    reg external_weight_ready_q;
    reg [5:0] pw_tile_q;

    wire start_fire = start_valid && start_ready;
    assign start_ready = rst_n && (state == S_IDLE) &&
                         (USE_EXTERNAL_MEM || !weight_load_valid);
    assign weight_load_ready = rst_n && !USE_EXTERNAL_MEM &&
                               (state == S_IDLE) && !start_valid;
    wire weight_load_fire = weight_load_valid && weight_load_ready;
    assign pw_param_load_ready = rst_n && !USE_EXTERNAL_MEM && (state == S_IDLE) &&
                                 !start_valid && !weight_load_valid;
    wire pw_param_load_fire = pw_param_load_valid && pw_param_load_ready;

    /* These three ports are assigned below, after the registered schedule
     * cursor/response handshake wires have been formed. */
    assign pw_weight_req_ready = 1'b1;
    assign pw_weight_req_cancel = rst_n && USE_EXTERNAL_MEM &&
                                  (state != S_RUN);
    assign pw_param_req_valid = rst_n && USE_EXTERNAL_MEM &&
        ((state == S_PARAM && (param_req_lane_q < 8)) ||
         (state == S_RUN && param_prefetch_active_q && (param_prefetch_lane_q < 8)));
    assign pw_param_req_ready = 1'b1;
    assign pw_param_req_addr = (state == S_PARAM) ?
        {pw_tile_q[4:0],param_req_lane_q} :
        {param_prefetch_tile_q[4:0],param_prefetch_lane_q};

    wire dw_bank = dw_macro[0];
    wire same_bank_block = dw_bank ?
        (bank_busy1 && bank_block1 == dw_macro) :
        (bank_busy0 && bank_block0 == dw_macro);
    wire bank_free = dw_bank ? !bank_busy1 : !bank_busy0;
    wire group_last_beat = dw_channel_half && (dw_pixel == 3'd7);
    wire slot_occupied = dw_bank ? published1[dw_row][dw_group] :
                                   published0[dw_row][dw_group];
    wire slot_commit_room = !group_last_beat || !slot_occupied;
    assign dw_ready = rst_n && (state == S_RUN) && slot_commit_room &&
                      (bank_free || same_bank_block);
    wire dw_fire = dw_valid && dw_ready;
    wire group_desc_fire = dw_fire && group_last_beat;

    /* PW schedule is block -> Cout tile -> K group -> K row. */
    reg [7:0] pw_row_block_q;
    /* Macro coordinates advance with the row-block cursor.  Keeping them as
     * scheduler state removes the runtime divide/modulo by tile_cols_q from
     * the pixel-base and mask path into the shared arithmetic bank. */
    reg [10:0] pw_macro_row_q, pw_macro_col_q;
    reg [4:0] pw_group_q;
    reg [3:0] pw_k_q;
    wire [7:0] pw_macro_q = pw_row_block_q >> 2;
    wire [1:0] pw_row_q = pw_row_block_q[1:0];
    /* The PW rowblock cursor is macro-major: four DW rows per 4x8 macro,
     * then the next horizontal macro.  Carrying the output geometry lets the
     * result pixel tag stay in the external NHWC linear space while scratch
     * ownership remains {macro,row}. */
    wire [15:0] pw_macro_row_calc = {5'd0,pw_macro_row_q};
    wire [15:0] pw_macro_col_calc = {5'd0,pw_macro_col_q};
    wire [15:0] pw_global_y_calc = (pw_macro_row_calc << 2) + pw_row_q;
    wire [15:0] pw_global_x_calc = pw_macro_col_calc << 3;
    wire [31:0] pw_pixel_base_calc = pw_global_y_calc * output_width_q +
                                      pw_global_x_calc;
    wire [10:0] pw_pixel_base = pw_pixel_base_calc[10:0];
    wire [15:0] pw_x_rem = (pw_global_x_calc < output_width_q) ?
                           (output_width_q - pw_global_x_calc) : 16'd0;
    wire pw_bank = pw_macro_q[0];
    /* Carry the schedule-owned geometry through the arithmetic island.  The
     * tag is captured with the first K token of a block and held until all
     * sixteen requant beats drain, so publication control never has to
     * divide the returned linear pixel index by output_width_q. */
    wire [3:0] pw_valid_pixels = (pw_global_y_calc >= output_height_q) ?
                                  4'd0 :
                                  ((pw_x_rem >= 16'd8) ? 4'd8 : pw_x_rem[3:0]);
    wire pw_last_cout = (pw_tile_q + 1'b1 >= cout_tile_count_q);
    wire pw_last_row = (pw_row_q == 2'd3) ||
                       (pw_global_y_calc + 1'b1 >= output_height_q);
    wire [8:0] pw_spatial_tag =
        {pw_valid_pixels, pw_last_cout, pw_last_row, pw_row_q, pw_bank};
    wire [7:0] pixel_mask_q = (pw_global_y_calc >= output_height_q) ? 8'd0 :
        ((pw_x_rem >= 16'd8) ? 8'hff :
         ((pw_x_rem == 0) ? 8'd0 : ((8'h01 << pw_x_rem) - 1'b1)));
    wire [11:0] cout_rem = {3'd0,cout_q} - {3'd0, pw_tile_q, 3'd0};
    wire [7:0] cout_mask_q = (cout_rem >= 12'd8) ? 8'hff :
        ((cout_rem == 0) ? 8'd0 : ((8'h01 << cout_rem) - 1'b1));
    wire pw_slot_valid = pw_bank ? published1[pw_row_q][pw_group_q] :
                                   published0[pw_row_q][pw_group_q];
    wire pw_owner_match = pw_bank ?
        (bank_busy1 && (bank_block1 == pw_macro_q) &&
         (bank_session1 == session_q) && (bank_epoch1 == epoch_q)) :
        (bank_busy0 && (bank_block0 == pw_macro_q) &&
         (bank_session0 == session_q) && (bank_epoch0 == epoch_q));
    wire [3:0] pw_slot_generation = pw_bank ?
        slot_generation1[pw_row_q][pw_group_q] :
        slot_generation0[pw_row_q][pw_group_q];
    wire pw_slot_epoch_valid = pw_bank ?
        slot_epoch_valid1[pw_row_q][pw_group_q] :
        slot_epoch_valid0[pw_row_q][pw_group_q];
    wire pw_published = pw_slot_valid && pw_slot_epoch_valid &&
                        pw_owner_match;
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
    /* Fixed rowstore lookup.  k is bounded by 127 and never participates in
     * a division or dynamic physical address calculation. */
    /* Flattened physical addresses keep tile selection out of a nested
     * variable array dereference.  Only the low four group bits are used;
     * start validation bounds groups to MAX_GROUPS (16 in this vehicle). */
    wire [11:0] pw_weight_addr = {pw_tile_q[4:0], pw_group_q[3:0], pw_k_q[2:0]};

    /* The request-register bridge repeats a held response while the shared
     * core or the expected scratch row is stalled.  Address-tag matching is
     * therefore part of the token fence: after a look-ahead request is
     * captured, the bridge may still present the previous response for one
     * cycle while its XPM read completes. */
    wire pw_weight_resp_match = (pw_weight_resp_addr == pw_weight_addr);
    (* max_fanout = 64 *) wire pw_token_valid =
        (state == S_RUN) && setup_fence_q && !schedule_done_q && pw_published &&
        (!USE_EXTERNAL_MEM || (external_weight_ready_q &&
                               pw_weight_resp_valid &&
                               pw_weight_resp_match));

    /* Look ahead on the cycle which consumes a response.  This lets the
     * synchronous BRAM accept the next address at the same edge, preserving
     * II=1 in the common case without pretending that BRAM reads are
     * combinational. */
    wire [7:0] rd_issue_row_block;
    wire [5:0] rd_issue_tile;
    wire [4:0] rd_issue_group;
    wire [3:0] rd_issue_k;
    wire core_ready;
    wire pw_token_fire = pw_token_valid && core_ready;
    wire [7:0] rd_next_row = (pw_row_block_q + 1'b1);
    wire [5:0] rd_next_tile = (pw_tile_q + 1'b1);
    wire [4:0] rd_next_group = (pw_group_q + 1'b1);
    wire [3:0] rd_next_k = (pw_k_q + 1'b1);
    assign rd_issue_k = (!pw_token_fire) ? pw_k_q :
                         (pw_final_k ? 4'd0 : rd_next_k[3:0]);
    assign rd_issue_group = (!pw_token_fire) ? pw_group_q :
                            (pw_final_k && pw_final_group ? 5'd0 :
                             (pw_final_k ? rd_next_group : pw_group_q));
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
    /* A request is issued when the previous response is first accepted, so
     * the bridge can capture the look-ahead address at that edge.  At a tile
     * boundary the sweep deliberately drains/flushes the old request before
     * the parameter cache changes bank; the next S_RUN cycle issues the new
     * tile's first address. */
    /* The one-cycle look-ahead request is sampled directly by the external
     * synchronous-memory adapter.  Its response address is registered at the
     * same read edge, keeping each weight tagged through output stalls. */
    assign pw_weight_req_valid = rst_n && USE_EXTERNAL_MEM && (state == S_RUN);
    assign pw_weight_req_addr = rd_issue_weight_addr;
    wire [5:0] rd_issue_scratch_addr =
        {rd_issue_group[3:0], rd_issue_row_block[1:0]};
    wire rd_issue_bank = (rd_issue_row_block[7:2] & 1'b1);
`ifndef SYNTHESIS
    wire signed [63:0] pw_wgt_row = USE_EXTERNAL_MEM ? pw_weight_resp_data : weight_mem_rd;
`else
    wire signed [63:0] pw_wgt_row = pw_weight_resp_data;
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

    if (!USE_EXTERNAL_MEM) begin : gen_legacy_weight_bram
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
    end
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

    reg signed [511:0] pw_bias_vec, pw_multiplier_vec;
    reg [95:0] pw_shift_vec;
    integer zi;
    always @* begin
        pw_bias_vec = 512'sd0;
        pw_multiplier_vec = 512'sd0;
        pw_shift_vec = 96'd0;
        for (zi = 0; zi < 8; zi = zi + 1) begin
            pw_bias_vec[zi*32 +: 32] = pw_bias_cache[param_active_bank_q][zi];
            pw_multiplier_vec[zi*32 +: 32] = pw_multiplier_cache[param_active_bank_q][zi];
            pw_shift_vec[zi*6 +: 6] = pw_shift_cache[param_active_bank_q][zi];
        end
    end

    wire core_valid;
    wire [10:0] core_pixel;
    wire [8:0] core_cout;
    wire [3:0] core_mask;
    wire signed [31:0] core_data;
    wire [8:0] core_spatial_tag;
    wire [2:0] core_inner_pixel;
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
        .pixel_base(pw_pixel_base), .spatial_tag(pw_spatial_tag),
        .cout_base({pw_tile_q,3'd0}),
        .bias_vec(pw_bias_vec), .multiplier_vec(pw_multiplier_vec),
        .shift_vec(pw_shift_vec), .output_zero_point_int32(pw_output_zero_point_int32),
        .activation_min_int32(pw_activation_min_int32), .activation_max_int32(pw_activation_max_int32),
        .ready_out(result_ready), .valid_out(core_valid),
        .out_pixel_idx(core_pixel), .out_channel_base(core_cout),
        .out_lane_mask(core_mask), .out_data(core_data),
        .out_spatial_tag(core_spatial_tag), .out_inner_pixel(core_inner_pixel),
        .busy(core_busy),
        .metric_token_count(core_metric_tokens),
        .metric_masked_mac_count(core_metric_macs),
        .metric_commit_count(core_metric_commits)
    );
    /* The shared core drains a fixed 8x8 block.  For a partial horizontal
     * row, its masked pixels still advance internally but are not external
     * output words; this preserves the exact output-word ledger. */
    assign result_valid = core_valid && (|core_mask);
    assign result_pixel_idx = core_pixel;
    assign result_channel_base = core_cout;
    assign result_lane_mask = core_mask;
    assign result_data = core_data;
    wire result_fire = result_valid && result_ready;
    wire [3:0] core_valid_pixels = core_spatial_tag[8:5];
    wire core_last_cout = core_spatial_tag[4];
    wire core_last_row = core_spatial_tag[3];
    wire [1:0] core_row_calc = core_spatial_tag[2:1];
    wire core_bank = core_spatial_tag[0];
    /* A shared-core drain is one 8-pixel horizontal macro, not a complete
     * output row.  Final-pixel accounting and scratch-bank release must
     * therefore fire at every eight-pixel macro boundary; waiting for the
     * full row would leave macro 0 holding bank 0 while macro 2 tries to
     * reuse it.  The producer-owned valid-pixel count covers a narrow
     * horizontal tail without reconstructing x from the linear index. */
    wire core_last_valid_pixel =
        ({1'b0,core_inner_pixel} + 4'd1 >= core_valid_pixels);
    /* A result group is one spatial 8-pixel block for one Cout tile, so its
     * completion does not require the final Cout tile.  Scratch release is a
     * stricter fence: only the last Cout tile may release a spatial row. */
`ifdef DEBUG_LEGACY_RELEASE
    /* Diagnostic A/B only: this is the pre-spatial-tag release predicate.
     * It is useful for separating bank-lifetime changes from the registered
     * metadata fence; the normal path uses producer-owned geometry tags. */
    wire result_group_final = result_fire &&
        (core_pixel[2:0] == 3'd7) && (core_cout[2:0] == 3'd4);
    wire result_row_final = result_group_final &&
        ({3'd0,core_cout} + 9'd4 >= cout_q);
`else
    wire result_group_final = result_fire && core_last_valid_pixel;
    wire result_row_final = result_group_final && core_last_cout && core_last_row;
`endif

    /* Output-group count is used only for the layer fence and metrics. */
    reg [31:0] completed_output_groups_q;
    /* Captured layer fence.  Keeping the shape multiplication at start
     * removes cout_tile_count/row_count arithmetic from the hot RUN->DONE
     * state-decision cone. */
    reg [31:0] target_output_groups_q;
    reg input_last_seen_q;
    integer ri, rj, rk;
`ifdef DEBUG_SHARED_TRACE
    /* Short, simulation-only trace for the first publication gap in each
     * sweep.  It is intentionally local to this vehicle so the production
     * datapath and its normal counters are untouched. */
    integer trace_gap_seen;
    integer trace_gap_window;
    integer trace_pub_count;
    integer trace_rel_count;
    integer trace_gap_active;
    integer trace_gap_start_cycle;
    integer trace_gap_start_row;
    integer trace_gap_start_tile;
    integer trace_gap_start_group;
    integer trace_gap_start_k;
    integer trace_gap_start_bank;
    integer trace_gap_start_dw_macro;
    integer trace_gap_start_dw_row;
    integer trace_gap_start_dw_group;
    integer trace_gap_start_dw_half;
    integer trace_gap_start_dw_pixel;
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; error <= 1'b0;
`ifndef SYNTHESIS
            weight_mem_rd <= 0;
            scratch0_top_rd <= 0; scratch0_bottom_rd <= 0;
            scratch1_top_rd <= 0; scratch1_bottom_rd <= 0;
`endif
            pixels_q <= 0; output_height_q <= 0; output_width_q <= 0;
            tile_cols_q <= 0; cin_q <= 0; cout_q <= 0;
            raw_pixels_q <= 0; raw_output_height_q <= 0; raw_output_width_q <= 0;
            raw_cin_q <= 0; raw_cout_q <= 0; setup_fence_q <= 1'b0;
            session_q <= 0; epoch_q <= 0; input_done_q <= 0;
            schedule_done_q <= 0; block_count_q <= 0; row_count_q <= 0; group_count_q <= 0;
            cout_tile_count_q <= 0;
            bank_busy0 <= 0; bank_busy1 <= 0; bank_block0 <= 0; bank_block1 <= 0;
            bank_session0 <= 0; bank_session1 <= 0;
            bank_epoch0 <= 0; bank_epoch1 <= 0;
            for (ri = 0; ri < 4; ri = ri + 1) begin
                published0[ri] <= 0; published1[ri] <= 0;
                for (rj = 0; rj < MAX_GROUPS; rj = rj + 1) begin
                    slot_generation0[ri][rj] <= 0;
                    slot_generation1[ri][rj] <= 0;
                end
            end
`ifndef SYNTHESIS
            if (!USE_EXTERNAL_MEM) begin
                for (ri = 0; ri < PW_PARAM_DEPTH; ri = ri + 1) begin
                    pw_bias_mem[ri] = 0;
                    /* Preserve the isolated sweep's historical unit scale when
                     * a narrow testbench intentionally omits parameter loads. */
                    pw_multiplier_mem[ri] = 32'sh4000_0000;
                    pw_shift_mem[ri] = 0;
                end
            end
`endif
            for (ri = 0; ri < 8; ri = ri + 1) begin
                pw_bias_cache[0][ri] <= 0; pw_bias_cache[1][ri] <= 0;
                pw_multiplier_cache[0][ri] <= 32'sh4000_0000;
                pw_multiplier_cache[1][ri] <= 32'sh4000_0000;
                pw_shift_cache[0][ri] <= 0; pw_shift_cache[1][ri] <= 0;
            end
            param_req_lane_q <= 0; param_resp_count_q <= 0;
            param_cache_tile_q[0] <= 0; param_cache_tile_q[1] <= 0;
            param_cache_valid_q <= 0; param_active_bank_q <= 0; param_load_bank_q <= 0;
            param_prefetch_active_q <= 0; param_prefetch_lane_q <= 0;
            param_prefetch_tile_q <= 0;
            external_weight_ready_q <= 1'b0;
            pw_row_block_q <= 0; pw_macro_row_q <= 0; pw_macro_col_q <= 0;
            pw_tile_q <= 0; pw_group_q <= 0; pw_k_q <= 0;
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
`ifdef DEBUG_SHARED_TRACE
            trace_gap_seen = 0;
            trace_gap_window = 0;
            trace_pub_count = 0;
            trace_rel_count = 0;
            trace_gap_active = 0;
            trace_gap_start_cycle = 0;
            trace_gap_start_row = 0;
            trace_gap_start_tile = 0;
            trace_gap_start_group = 0;
            trace_gap_start_k = 0;
            trace_gap_start_bank = 0;
            trace_gap_start_dw_macro = 0;
            trace_gap_start_dw_row = 0;
            trace_gap_start_dw_group = 0;
            trace_gap_start_dw_half = 0;
            trace_gap_start_dw_pixel = 0;
`endif
        end else begin
            done <= 1'b0;
            if (USE_EXTERNAL_MEM)
                external_weight_ready_q <= (state == S_RUN);
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
`ifndef SYNTHESIS
            if (pw_param_load_fire && !USE_EXTERNAL_MEM &&
                (pw_param_load_channel < PW_PARAM_DEPTH)) begin
                pw_bias_mem[pw_param_load_channel] <= pw_param_load_bias;
                pw_multiplier_mem[pw_param_load_channel] <= pw_param_load_multiplier;
                pw_shift_mem[pw_param_load_channel] <= pw_param_load_shift;
            end
`endif
            if (start_fire) begin
                if ((start_pixels == 0) || (start_cin == 0) || (start_cout == 0) ||
                    (start_pixels > MAX_BLOCKS*32) || (start_cin > MAX_GROUPS*8) ||
                    (start_cout > MAX_COUT_TILES*8)) begin
                    error <= 1'b1; done <= 1'b1;
                end else begin
                    state <= S_SETUP_GEOM;
                    external_weight_ready_q <= 1'b0;
                    raw_pixels_q <= start_pixels;
                    raw_output_height_q <= start_output_height;
                    raw_output_width_q <= start_output_width;
                    raw_cin_q <= start_cin;
                    raw_cout_q <= start_cout;
                    setup_fence_q <= 1'b0;
                    session_q <= start_session; epoch_q <= start_epoch;
                    pixels_q <= 0; output_height_q <= 0; output_width_q <= 0;
                    tile_cols_q <= 0; cin_q <= 0; cout_q <= 0;
                    block_count_q <= 0; row_count_q <= 0; group_count_q <= 0;
                    cout_tile_count_q <= 0; target_output_groups_q <= 0;
                    input_done_q <= 0; schedule_done_q <= 0; input_last_seen_q <= 0;
                    bank_busy0 <= 0; bank_busy1 <= 0;
                    bank_session0 <= start_session; bank_session1 <= start_session;
                    bank_epoch0 <= start_epoch; bank_epoch1 <= start_epoch;
                    for (ri = 0; ri < 4; ri = ri + 1) begin
                        published0[ri] <= 0; published1[ri] <= 0;
                        for (rj = 0; rj < MAX_GROUPS; rj = rj + 1) begin
                            slot_generation0[ri][rj] <= 0;
                            slot_generation1[ri][rj] <= 0;
                            slot_epoch_valid0[ri][rj] <= 1'b0;
                            slot_epoch_valid1[ri][rj] <= 1'b0;
                        end
                    end
                    pw_row_block_q <= 0; pw_macro_row_q <= 0; pw_macro_col_q <= 0;
                    pw_tile_q <= 0; pw_group_q <= 0; pw_k_q <= 0;
                    param_req_lane_q <= 0; param_resp_count_q <= 0;
                    param_cache_tile_q[0] <= 0; param_cache_tile_q[1] <= 0;
                    param_cache_valid_q <= 0; param_active_bank_q <= 0; param_load_bank_q <= 0;
                    param_prefetch_active_q <= 0; param_prefetch_lane_q <= 0;
                    param_prefetch_tile_q <= 0;
                    completed_output_groups_q <= 0;
                    perf_total_cycles <= 0; perf_dw_writes <= 0;
                    perf_group_descriptors <= 0; perf_pw_tokens <= 0;
                    perf_output_writes <= 0; perf_output_groups <= 0;
`ifdef DEBUG_SHARED_TRACE
                    trace_gap_seen = 0;
                    trace_gap_window = 0;
                    trace_pub_count = 0;
                    trace_rel_count = 0;
                    trace_gap_active = 0;
                    trace_gap_start_cycle = 0;
                    trace_gap_start_row = 0;
                    trace_gap_start_tile = 0;
                    trace_gap_start_group = 0;
                    trace_gap_start_k = 0;
                    trace_gap_start_bank = 0;
                    trace_gap_start_dw_macro = 0;
                    trace_gap_start_dw_row = 0;
                    trace_gap_start_dw_group = 0;
                    trace_gap_start_dw_half = 0;
                    trace_gap_start_dw_pixel = 0;
`endif
                end
            end

            if (state == S_SETUP_GEOM) begin
                /* First commit: dimensions and tile/channel counts.  The
                 * values are sourced from the raw start record, never from
                 * live descriptor wires. */
                pixels_q <= raw_pixels_q;
                output_height_q <= setup_out_h_calc;
                output_width_q <= setup_out_w_calc;
                tile_cols_q <= setup_tile_cols_calc;
                block_count_q <= setup_block_count_calc;
                group_count_q <= setup_group_count_calc;
                cout_tile_count_q <= setup_cout_tile_count_calc;
                cin_q <= raw_cin_q;
                cout_q <= raw_cout_q;
                state <= S_SETUP_ROWS;
            end else if (state == S_SETUP_ROWS) begin
                /* Second commit: physical row traversal count.  The legacy
                 * linear API preserves its exact valid-row behavior; the
                 * geometry API uses padded 4-row macro storage. */
                row_count_q <= (raw_output_height_q == 0) ?
                               setup_legacy_rows_calc :
                               setup_geometry_rows_calc[7:0];
                state <= S_SETUP_TARGET;
            end else if (state == S_SETUP_TARGET) begin
                /* Final commit/fence: every output-group target is derived
                 * from already registered row/tile counts. */
                target_output_groups_q <=
                    ({24'd0,row_count_q} * {26'd0,cout_tile_count_q});
                setup_fence_q <= 1'b1;
                state <= USE_EXTERNAL_MEM ? S_PARAM : S_RUN;
            end

            /* External parameter store: eight narrow synchronous reads form
             * a tile-tagged current cache.  The inactive cache is prefetched
             * while the current tile is running; it is never modified while
             * first_k..last_k is consuming the active tile. */
            if (USE_EXTERNAL_MEM && (state == S_PARAM)) begin
                if (pw_param_resp_valid &&
                    (pw_param_resp_addr[7:3] == pw_tile_q[4:0])) begin
                    pw_bias_cache[param_load_bank_q][pw_param_resp_addr[2:0]] <= pw_param_resp_data[31:0];
                    pw_multiplier_cache[param_load_bank_q][pw_param_resp_addr[2:0]] <= pw_param_resp_data[63:32];
                    pw_shift_cache[param_load_bank_q][pw_param_resp_addr[2:0]] <= pw_param_resp_data[64 +: 6];
                    if (pw_param_resp_addr[2:0] == 3'd7) begin
                        param_cache_tile_q[param_load_bank_q] <= pw_tile_q;
                        param_cache_valid_q[param_load_bank_q] <= 1'b1;
                        param_active_bank_q <= param_load_bank_q;
                        state <= S_RUN;
                        if (pw_tile_q + 1'b1 < cout_tile_count_q) begin
                            param_prefetch_active_q <= 1'b1;
                            param_prefetch_lane_q <= 0;
                            param_prefetch_tile_q <= pw_tile_q + 1'b1;
                            param_cache_valid_q[~param_load_bank_q] <= 1'b0;
                        end else param_prefetch_active_q <= 1'b0;
                    end
                end
                if (pw_param_req_valid && pw_param_req_ready &&
                    (param_req_lane_q != 3'd7))
                    param_req_lane_q <= param_req_lane_q + 1'b1;
            end else if (USE_EXTERNAL_MEM && (state == S_RUN) &&
                         param_prefetch_active_q) begin
                if (pw_param_resp_valid &&
                    (pw_param_resp_addr[7:3] == param_prefetch_tile_q[4:0]) &&
                    (pw_param_resp_addr[2:0] == param_prefetch_lane_q)) begin
                    pw_bias_cache[~param_active_bank_q][param_prefetch_lane_q] <= pw_param_resp_data[31:0];
                    pw_multiplier_cache[~param_active_bank_q][param_prefetch_lane_q] <= pw_param_resp_data[63:32];
                    pw_shift_cache[~param_active_bank_q][param_prefetch_lane_q] <= pw_param_resp_data[64 +: 6];
                    if (param_prefetch_lane_q == 3'd7) begin
                        param_cache_tile_q[~param_active_bank_q] <= param_prefetch_tile_q;
                        param_cache_valid_q[~param_active_bank_q] <= 1'b1;
                        param_prefetch_active_q <= 1'b0;
                    end else param_prefetch_lane_q <= param_prefetch_lane_q + 1'b1;
                end
            end

            if (state == S_RUN)
                perf_total_cycles <= perf_total_cycles + 1'b1;

`ifdef DEBUG_SHARED_TRACE
            if (state == S_RUN) begin
                if (group_desc_fire && (trace_pub_count < 128)) begin
                    $display("TRACE_PUBLISH cycle=%0d macro=%0d row=%0d group=%0d bank=%0d half=%0d pixel=%0d pw=%0d/%0d/%0d/%0d pub0=%h/%h/%h/%h pub1=%h/%h/%h/%h busy=%0d/%0d block=%0d/%0d",
                             perf_total_cycles, dw_macro, dw_row, dw_group,
                             dw_bank, dw_channel_half, dw_pixel,
                             pw_row_block_q, pw_tile_q, pw_group_q, pw_k_q,
                             published0[0], published0[1], published0[2], published0[3],
                             published1[0], published1[1], published1[2], published1[3],
                             bank_busy0, bank_busy1, bank_block0, bank_block1);
                    trace_pub_count = trace_pub_count + 1;
                end
                if (result_row_final && (trace_rel_count < 128)) begin
                    $display("TRACE_RELEASE cycle=%0d core_pixel=%0d core_cout=%0d row=%0d bank=%0d last_row=%0d pw=%0d/%0d/%0d/%0d pub0=%h/%h/%h/%h pub1=%h/%h/%h/%h busy=%0d/%0d block=%0d/%0d",
                             perf_total_cycles, core_pixel, core_cout,
                             core_row_calc, core_bank, core_last_row,
                             pw_row_block_q, pw_tile_q, pw_group_q, pw_k_q,
                             published0[0], published0[1], published0[2], published0[3],
                             published1[0], published1[1], published1[2], published1[3],
                             bank_busy0, bank_busy1, bank_block0, bank_block1);
                    trace_rel_count = trace_rel_count + 1;
                end
                /* Summarize only non-trivial publication gaps.  A one-cycle
                 * gap is the expected edge on which a final DW beat sets the
                 * publication bit; longer intervals expose the producer/
                 * scheduler imbalance that regressed the fullnet cycle count. */
                if ((trace_pub_count > 0) && !schedule_done_q) begin
                    if (!pw_slot_valid && !trace_gap_active) begin
                        trace_gap_active = 1;
                        trace_gap_start_cycle = perf_total_cycles;
                        trace_gap_start_row = pw_row_block_q;
                        trace_gap_start_tile = pw_tile_q;
                        trace_gap_start_group = pw_group_q;
                        trace_gap_start_k = pw_k_q;
                        trace_gap_start_bank = pw_bank;
                        trace_gap_start_dw_macro = dw_macro;
                        trace_gap_start_dw_row = dw_row;
                        trace_gap_start_dw_group = dw_group;
                        trace_gap_start_dw_half = dw_channel_half;
                        trace_gap_start_dw_pixel = dw_pixel;
                    end else if (pw_slot_valid && trace_gap_active) begin
                        if ((perf_total_cycles - trace_gap_start_cycle) >= 4)
                            $display("TRACE_LONG_GAP start=%0d end=%0d dur=%0d pw_start=%0d/%0d/%0d/%0d bank=%0d dw_start=%0d/%0d/%0d/%0d/%0d pw_end=%0d/%0d/%0d/%0d pub0=%h/%h/%h/%h pub1=%h/%h/%h/%h busy=%0d/%0d block=%0d/%0d",
                                     trace_gap_start_cycle, perf_total_cycles,
                                     perf_total_cycles - trace_gap_start_cycle,
                                     trace_gap_start_row, trace_gap_start_tile,
                                     trace_gap_start_group, trace_gap_start_k,
                                     trace_gap_start_bank,
                                     trace_gap_start_dw_macro,
                                     trace_gap_start_dw_row,
                                     trace_gap_start_dw_group,
                                     trace_gap_start_dw_half,
                                     trace_gap_start_dw_pixel,
                                     pw_row_block_q, pw_tile_q,
                                     pw_group_q, pw_k_q,
                                     published0[0], published0[1], published0[2], published0[3],
                                     published1[0], published1[1], published1[2], published1[3],
                                     bank_busy0, bank_busy1, bank_block0, bank_block1);
                        trace_gap_active = 0;
                    end
                end
                /* Ignore the initial empty schedule window; the useful gap is
                 * the first one after at least one row/group was published. */
                if (!trace_gap_seen && (trace_pub_count > 0) &&
                    !schedule_done_q && !pw_slot_valid) begin
                    $display("TRACE_FIRST_GAP cycle=%0d dw=%0d/%0d/%0d/%0d/%0d/%0d/%0d ready=%0d pw=%0d/%0d/%0d/%0d bank=%0d slot=%0d owner=%0d gen=%0d/%0d token=%0d/%0d pub0=%h/%h/%h/%h pub1=%h/%h/%h/%h busy=%0d/%0d block=%0d/%0d",
                             perf_total_cycles, dw_valid, dw_macro, dw_row,
                             dw_group, dw_channel_half, dw_pixel, dw_last,
                             dw_ready, pw_row_block_q, pw_tile_q,
                             pw_group_q, pw_k_q, pw_bank, pw_slot_valid,
                             pw_owner_match, pw_slot_generation, epoch_q,
                             pw_token_valid, pw_token_fire,
                             published0[0], published0[1], published0[2], published0[3],
                             published1[0], published1[1], published1[2], published1[3],
                             bank_busy0, bank_busy1, bank_block0, bank_block1);
                    trace_gap_seen = 1;
                    trace_gap_window = 12;
                end else if (trace_gap_window > 0) begin
                    $display("TRACE_GAP_FOLLOW cycle=%0d dw=%0d/%0d/%0d/%0d/%0d/%0d/%0d ready=%0d pw=%0d/%0d/%0d/%0d bank=%0d slot=%0d owner=%0d gen=%0d/%0d token=%0d/%0d pub0=%h/%h/%h/%h pub1=%h/%h/%h/%h busy=%0d/%0d block=%0d/%0d",
                             perf_total_cycles, dw_valid, dw_macro, dw_row,
                             dw_group, dw_channel_half, dw_pixel, dw_last,
                             dw_ready, pw_row_block_q, pw_tile_q,
                             pw_group_q, pw_k_q, pw_bank, pw_slot_valid,
                             pw_owner_match, pw_slot_generation, epoch_q,
                             pw_token_valid, pw_token_fire,
                             published0[0], published0[1], published0[2], published0[3],
                             published1[0], published1[1], published1[2], published1[3],
                             bank_busy0, bank_busy1, bank_block0, bank_block1);
                    trace_gap_window = trace_gap_window - 1;
                end
            end
`endif
            if (dw_fire) begin
                perf_dw_writes <= perf_dw_writes + 1'b1;
                if (dw_last) begin input_done_q <= 1'b1; input_last_seen_q <= 1'b1; end
                if (dw_bank) begin
                    if (!bank_busy1) begin
                        bank_busy1 <= 1'b1; bank_block1 <= dw_macro;
                        /* A bank may be reused by a later spatial macro
                         * after its previous rows were drained.  Clear the
                         * direct publication map at ownership handoff so
                         * stale rows cannot satisfy the new macro's PW
                         * schedule before its DW producer commits them. */
                        for (ri = 0; ri < 4; ri = ri + 1) begin
                            published1[ri] <= 0;
                            for (rj = 0; rj < MAX_GROUPS; rj = rj + 1)
                                begin
                                    slot_generation1[ri][rj] <= 0;
                                    slot_epoch_valid1[ri][rj] <= 1'b0;
                                end
                        end
                    end
                end else begin
                    if (!bank_busy0) begin
                        bank_busy0 <= 1'b1; bank_block0 <= dw_macro;
                        for (ri = 0; ri < 4; ri = ri + 1) begin
                            published0[ri] <= 0;
                            for (rj = 0; rj < MAX_GROUPS; rj = rj + 1)
                                begin
                                    slot_generation0[ri][rj] <= 0;
                                    slot_epoch_valid0[ri][rj] <= 1'b0;
                                end
                        end
                    end
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
`ifndef SYNTHESIS
                /* The behavioral RAM view is word-addressable.  Preserve
                 * each group/half stream beat independently; a single
                 * shared row assembly register would let the last lane
                 * overwrite the other three lane streams. */
                if (dw_bank) begin
                    if (dw_channel_half)
                        scratch1_bottom[{dw_group[3:0],dw_row}]
                            [dw_pixel*32 +: 32] <= dw_data;
                    else
                        scratch1_top[{dw_group[3:0],dw_row}]
                            [dw_pixel*32 +: 32] <= dw_data;
                end else begin
                    if (dw_channel_half)
                        scratch0_bottom[{dw_group[3:0],dw_row}]
                            [dw_pixel*32 +: 32] <= dw_data;
                    else
                        scratch0_top[{dw_group[3:0],dw_row}]
                            [dw_pixel*32 +: 32] <= dw_data;
                end
`endif
                if (group_desc_fire) begin
                    if (dw_bank) begin
                        published1[dw_row][dw_group] <= 1'b1;
                        slot_generation1[dw_row][dw_group] <= epoch_q;
                        slot_epoch_valid1[dw_row][dw_group] <=
                            (epoch_q == bank_epoch1) &&
                            (session_q == bank_session1);
                    end else begin
                        published0[dw_row][dw_group] <= 1'b1;
                        slot_generation0[dw_row][dw_group] <= epoch_q;
                        slot_epoch_valid0[dw_row][dw_group] <=
                            (epoch_q == bank_epoch0) &&
                            (session_q == bank_session0);
                    end
                    perf_group_descriptors <= perf_group_descriptors + 1'b1;
                end
            end

            if (pw_token_fire) begin
                perf_pw_tokens <= perf_pw_tokens + 1'b1;
                if (pw_final_k) begin
                    pw_k_q <= 0;
                    if (pw_final_group) begin
                        pw_group_q <= 0;
                        if (USE_EXTERNAL_MEM) begin
                            if (pw_tile_q + 1'b1 < cout_tile_count_q &&
                                param_cache_valid_q[~param_active_bank_q] &&
                                (param_cache_tile_q[~param_active_bank_q] == pw_tile_q + 1'b1)) begin
                                param_active_bank_q <= ~param_active_bank_q;
                                if (pw_tile_q + 2 < cout_tile_count_q) begin
                                    param_prefetch_active_q <= 1'b1;
                                    param_prefetch_lane_q <= 0;
                                    param_prefetch_tile_q <= pw_tile_q + 2;
                                    param_cache_valid_q[param_active_bank_q] <= 1'b0;
                                end else param_prefetch_active_q <= 1'b0;
                            end else if (pw_tile_q + 1 < cout_tile_count_q) begin
                                state <= S_PARAM; param_req_lane_q <= 0;
                                param_resp_count_q <= 0;
                                param_load_bank_q <= ~param_active_bank_q;
                                param_cache_valid_q[~param_active_bank_q] <= 1'b0;
                                param_prefetch_active_q <= 1'b0;
                            end
                        end
                        if (pw_tile_q + 1'b1 >= cout_tile_count_q) begin
                            pw_tile_q <= 0;
                            if (pw_row_block_q + 1 >= row_count_q) begin
                                schedule_done_q <= 1'b1;
                            end else begin
                                /* The two-entry parameter cache is streamed
                                 * in Cout-tile order.  At the end of a spatial
                                 * row/macro sequence the next tile is tile 0,
                                 * not tile+1; the final tile of the previous
                                 * row therefore cannot remain active.  Force
                                 * a tagged reload before admitting tile 0 so
                                 * a cache holding the prior row's final tile
                                 * (for example tile 3) cannot be reused for
                                 * the new row. */
                                if (USE_EXTERNAL_MEM) begin
                                    state <= S_PARAM;
                                    param_req_lane_q <= 0;
                                    param_resp_count_q <= 0;
                                    param_load_bank_q <= ~param_active_bank_q;
                                    param_cache_valid_q[~param_active_bank_q] <= 1'b0;
                                    param_prefetch_active_q <= 1'b0;
                                end
                                pw_row_block_q <= pw_row_block_q + 1'b1;
                                if (pw_row_q == 2'd3) begin
                                    if (pw_macro_col_q + 1'b1 >= tile_cols_q) begin
                                        pw_macro_col_q <= 0;
                                        pw_macro_row_q <= pw_macro_row_q + 1'b1;
                                    end else begin
                                        pw_macro_col_q <= pw_macro_col_q + 1'b1;
                                    end
                                end
                            end
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
                    if (core_bank) begin
                        published1[core_row_calc] <= 0;
                        for (rj = 0; rj < MAX_GROUPS; rj = rj + 1)
                            slot_epoch_valid1[core_row_calc][rj] <= 1'b0;
                        if (core_last_row)
                            bank_busy1 <= 1'b0;
                    end else begin
                        published0[core_row_calc] <= 0;
                        for (rj = 0; rj < MAX_GROUPS; rj = rj + 1)
                            slot_epoch_valid0[core_row_calc][rj] <= 1'b0;
                        if (core_last_row)
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
