`timescale 1ns/1ps
`default_nettype none

/*
 * Memory-oriented streaming DSBlock.
 *
 * Configuration is loaded through a scalar indexed write port.  Large input
 * and pointwise-weight payloads live in BRAM-backed buffers instead of packed
 * module ports.  The compute path is:
 *
 * input BRAM -> streaming DW -> BRAM DW tile -> PW 8x8 -> pipelined requant
 */
module ds_block_tile_engine_new #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17,
    /* Compile-time alternate PW datapath.  The default remains the retained
     * replay engine; the unified64 variant is selected only by the new
     * runner integration build so existing users keep the exact old ABI. */
    parameter USE_UNIFIED64 = 0,
    /* Route unified PW through the layer-runner shared arithmetic island. */
    parameter USE_SHARED_ARRAY = 0,
    /* Use the persistent activation-window row feeder for the unified PW
     * path.  Zero preserves the existing replay engine exactly. */
    parameter USE_PERSISTENT_FEED = 0
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_wr_en,
    output wire               cfg_ready,
    output wire               cfg_weight_word_ready,
    input  wire [3:0]         cfg_target,
    input  wire [15:0]        cfg_index,
    input  wire [31:0]        cfg_data,
    input  wire               cfg_vec4_wr_en,
    input  wire [15:0]        cfg_vec4_index,
    input  wire [31:0]        cfg_vec4_data,
    input  wire               cfg_weight_word_wr_en,
    input  wire               cfg_weight_word_target,
    input  wire [15:0]        cfg_weight_word_index,
    input  wire [31:0]        cfg_weight_word_data,
    input  wire [3:0]         cfg_weight_word_be,
    input  wire               start,
    output reg                busy,
    output reg                done,
    output reg                error,

    input  wire [3:0]         out_h,
    input  wire [3:0]         out_w,
    input  wire [7:0]         channels,
    input  wire [15:0]        out_channels,
    input  wire [1:0]         stride,
    input  wire signed [7:0]  input_zero_point,

    input  wire signed [31:0] dw_output_zero_point,
    input  wire signed [31:0] dw_activation_min,
    input  wire signed [31:0] dw_activation_max,
    input  wire signed [31:0] pw_output_zero_point,
    input  wire signed [31:0] pw_activation_min,
    input  wire signed [31:0] pw_activation_max,

    output wire               out_wr_en,
    output wire [5:0]         out_wr_pixel_idx,
    output wire [7:0]         out_wr_channel_idx,
    output wire signed [7:0]  out_wr_data_int8,

    // When the four requant lanes are a contiguous, aligned channel group,
    // expose them as one atomic 32-bit output transaction.  The legacy
    // scalar output remains active for every other group.
    output wire               out_wr_vec4_en,
    output wire [5:0]         out_wr_vec4_pixel_idx,
    output wire [7:0]         out_wr_vec4_channel_idx,
    output wire [31:0]        out_wr_vec4_data_int8,

    output reg [31:0]         perf_total_cycles,
    output reg [31:0]         perf_dw_cycles,
    output reg [31:0]         perf_pw_cycles,
    output reg [31:0]         perf_pw_issue_cycles,
    output wire               shared_valid_in,
    input wire                shared_ready_in,
    output wire               shared_first_k,
    output wire               shared_last_k,
    output wire [7:0]         shared_k_idx,
    output wire signed [63:0] shared_act_vec,
    output wire signed [127:0] shared_wgt_vec16,
    output wire [7:0]         shared_pixel_mask,
    output wire [15:0]        shared_cout_mask,
    output wire [10:0]        shared_pixel_base,
    output wire [8:0]         shared_cout_base,
    output wire signed [511:0] shared_bias_vec,
    output wire signed [511:0] shared_multiplier_vec,
    output wire [95:0]        shared_shift_vec,
    input wire                shared_out_valid,
    output wire               shared_out_ready,
    input wire [10:0]         shared_out_pixel_idx,
    input wire [8:0]          shared_out_channel_base,
    input wire [3:0]           shared_out_lane_mask,
    input wire signed [31:0]  shared_out_data
);
    localparam CFG_INPUT      = 4'd0;
    localparam CFG_DW_WEIGHT  = 4'd1;
    localparam CFG_DW_BIAS    = 4'd2;
    localparam CFG_DW_MUL     = 4'd3;
    localparam CFG_DW_SHIFT   = 4'd4;
    localparam CFG_PW_WEIGHT  = 4'd5;
    localparam CFG_PW_BIAS    = 4'd6;
    localparam CFG_PW_MUL     = 4'd7;
    localparam CFG_PW_SHIFT   = 4'd8;

    localparam ST_IDLE            = 5'd0;
    localparam ST_DW_PARAM_LOAD   = 5'd1;
    localparam ST_DW_INPUT_REQ    = 5'd2;
    localparam ST_DW_INPUT_FEED   = 5'd3;
    localparam ST_DW_WAIT         = 5'd4;
    localparam ST_PW_INIT         = 5'd5;
    localparam ST_PW_READ         = 5'd6;
    localparam ST_PW_FEED         = 5'd7;
    localparam ST_PW_WAIT         = 5'd8;
    localparam ST_RQ_ISSUE        = 5'd9;
    localparam ST_RQ_DRAIN        = 5'd10;
    localparam ST_ADVANCE         = 5'd11;
    localparam ST_DONE            = 5'd12;
    localparam ST_ERROR           = 5'd13;
    localparam ST_DW_PARAM_CAPTURE = 5'd14;
    localparam ST_DW_PARAM_READ    = 5'd15;

    localparam DW_LANES = 16;
    localparam PW_LANES = 8;
    localparam CHANNEL_TILES = MAX_CIN / DW_LANES;

    reg [4:0] state;

    reg [3:0] out_h_reg;
    reg [3:0] out_w_reg;
    reg [7:0] channels_reg;
    reg [8:0] out_channels_reg;
    reg [1:0] stride_reg;
    /* A local physical copy prevents the DW line-buffer control cone from
     * routing back to the top-level configuration register.  It is captured
     * with the other start-time parameters, well before DW input begins. */
    (* keep = "true" *) reg [1:0] dw_stride_engine_reg;
    (* keep = "true" *) reg [3:0] dw_out_h_engine_reg;
    (* keep = "true" *) reg [3:0] dw_out_w_engine_reg;
    (* keep = "true" *) reg [6:0] dw_channel_engine_reg;
    (* keep = "true" *) reg [7:0] persistent_output_pixels_reg;
    reg signed [7:0] input_zero_point_reg;
    reg signed [31:0] dw_output_zero_point_reg;
    reg signed [31:0] dw_activation_min_reg;
    reg signed [31:0] dw_activation_max_reg;
    reg signed [31:0] pw_output_zero_point_reg;
    reg signed [31:0] pw_activation_min_reg;
    reg signed [31:0] pw_activation_max_reg;

    (* ram_style = "distributed" *)
    reg signed [7:0] dw_weight_mem [0:(MAX_CIN*9)-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] dw_bias_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] dw_multiplier_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg [5:0] dw_shift_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] pw_bias_mem [0:MAX_COUT-1];
    (* ram_style = "distributed" *)
    reg signed [31:0] pw_multiplier_mem [0:MAX_COUT-1];
    (* ram_style = "distributed" *)
    reg [5:0] pw_shift_mem [0:MAX_COUT-1];

    wire input_buf_wr_en;
    wire input_buf_rd_en;
    wire [8:0] input_buf_rd_pixel;
    wire [$clog2(CHANNEL_TILES)-1:0] input_buf_rd_channel_tile;
    wire input_buf_rd_valid;
    wire signed [(DW_LANES*8)-1:0] input_buf_rd_data;
    wire signed [(DW_LANES*8)-1:0] dw_pixel_vec;

    wire pw_weight_wr_en;
    wire pw_weight_word_wr_en;
    wire pw_weight_word_ready;
    wire pw_weight_rd_en;
    wire pw_weight_rd_valid;
    wire signed [63:0] pw_weight_rd_data;

    reg [6:0] dw_channel_base;
    reg [3:0] dw_param_lane;
    reg [3:0] dw_param_kernel;
    reg [7:0] dw_param_channel_reg;
    reg [10:0] dw_param_addr_reg;
    reg signed [7:0] dw_param_weight_reg;
    reg signed [31:0] dw_param_bias_reg;
    reg signed [31:0] dw_param_multiplier_reg;
    reg [5:0] dw_param_shift_reg;
    reg [4:0] stream_x;
    reg [4:0] stream_y;
    wire [4:0] stream_in_h;
    wire [4:0] stream_in_w;
    wire [8:0] stream_pixel_idx;

    reg signed [(DW_LANES*9*8)-1:0] dw_weight_vec;
    reg signed [(DW_LANES*32)-1:0] dw_bias_vec;
    reg signed [(DW_LANES*32)-1:0] dw_multiplier_vec;
    reg        [(DW_LANES*6)-1:0] dw_shift_vec;
    /* Keep the kernel read select local to one lane, then commit the
     * completed lane through a fixed destination case.  This avoids the
     * lane*kernel variable part-select on the full 1152-bit bus. */
    reg signed [71:0] dw_weight_lane_tmp;

    wire dw_valid_in;
    wire dw_ready_in;
    wire dw_valid_out;
    wire [5:0] dw_out_pixel_idx;
    wire [6:0] dw_out_channel_idx;
    wire signed [7:0] dw_out_data_int8;
    wire dw_busy;
    wire dw_done;
    wire dw_output_accept;
    wire dw_valid_out_vec4;
    wire [5:0] dw_out_pixel_idx_vec4;
    wire [6:0] dw_out_channel_idx_vec4;
    wire signed [31:0] dw_out_data_int8_vec4;
    wire dw_output_accept_vec4;

    wire dw_buf_wr_en;
    wire dw_buf_rd_en;
    wire dw_buf_rd_valid;
    wire signed [63:0] dw_buf_rd_data;

    wire persistent_source_rd_en;
    wire [5:0] persistent_source_rd_pixel_base;
    wire [7:0] persistent_source_rd_channel_idx;
    wire persistent_source_rd_valid;
    wire signed [63:0] persistent_source_rd_data;
    wire persistent_weight_rd_en;
    wire [8:0] persistent_weight_rd_cout_base;
    wire [7:0] persistent_weight_rd_channel_idx;
    wire persistent_weight_rd_valid;
    wire signed [63:0] persistent_weight_rd_data;
    wire persistent_start;
    wire persistent_done;
    wire persistent_busy;
    wire persistent_error;
    wire persistent_token_valid;
    wire persistent_token_ready;
    wire persistent_token_first;
    wire persistent_token_last;
    wire [7:0] persistent_token_k;
    wire signed [63:0] persistent_token_act;
    wire signed [63:0] persistent_token_wgt;
    wire [7:0] persistent_token_pixel;
    wire [8:0] persistent_token_cout;
    wire [7:0] persistent_token_pixel_mask;
    wire [7:0] persistent_token_cout_mask;
    wire [7:0] persistent_block_pixel;
    wire [8:0] persistent_block_cout;
    wire [31:0] persistent_source_window_reads;
    wire [31:0] persistent_window_reuse;
    wire [31:0] persistent_token_count;

    reg [5:0] pw_pixel_base;
    reg [8:0] pw_cout_base;
    reg [7:0] pw_read_idx;
    reg [7:0] pw_k_idx;
    wire [7:0] pw_pixel_mask;
    wire [7:0] pw_cout_mask;
    wire pw_read_issue;
    wire pw_valid_in;
    wire pw_ready_in;
    wire pw_valid_out;
    wire signed [2047:0] pw_psum_out;
    wire [63:0] pw_lane_mask_out;
    wire pw_fire;

    /* The legacy array consumes the one-cycle BRAM response immediately.
     * unified64 can apply a real bank-ownership backpressure while it drains
     * a completed block, so its ingress needs one elastic holding entry.  A
     * raw BRAM valid pulse must never be allowed to disappear while
     * unified_pw_ready_in is low. */
    reg unified_input_stage_valid;
    reg signed [63:0] unified_input_stage_act;
    reg signed [63:0] unified_input_stage_wgt;
    wire signed [63:0] pw_act_vec = USE_UNIFIED64 ?
                                     unified_input_stage_act : dw_buf_rd_data;
    wire signed [63:0] pw_wgt_vec = USE_UNIFIED64 ?
                                     unified_input_stage_wgt : pw_weight_rd_data;

    /* Unified 8x8 output-stationary PW replacement.  It consumes the same
     * one-channel/8-pixel DW tile-buffer rows and the same packed 8-weight
     * rows as the legacy array, so only the reduction/commit schedule changes.
     * The generate below ensures the alternate build does not instantiate
     * both 64-DSP arrays. */
    wire unified_pw_ready_in;
    wire unified_pw_valid_out;
    wire unified_pw_busy;
    wire [3:0] unified_pw_out_row;
    wire unified_pw_out_beat;
    wire [10:0] unified_pw_out_pixel;
    wire [8:0] unified_pw_out_cout;
    wire [3:0] unified_pw_out_mask;
    wire signed [31:0] unified_pw_out_data;
    /* The compact unified64 engine's production ABI exposes the row/half
     * tags as absolute pixel/channel bases.  The final beat of every 8x8
     * block is therefore the +7 pixel, +4 channel beat; this remains true for
     * spatial and Cout tails because masked beats are still emitted. */
    wire unified_pw_final_fire = unified_pw_valid_out &&
                                  (unified_pw_out_pixel ==
                                   ({5'd0,pw_pixel_base} + 11'd7)) &&
                                  (unified_pw_out_cout ==
                                   (pw_cout_base + 9'd4));
    wire pw_core_ready = USE_UNIFIED64 ? unified_pw_ready_in : pw_ready_in;
    wire pw_core_valid_out = USE_UNIFIED64 ? unified_pw_valid_out : pw_valid_out;

    wire rq4_valid_in;
    wire rq4_ready_in;
    wire [3:0] rq4_valid_out;
    reg [3:0] rq4_ready_out;
    wire rq4_busy;
    wire [23:0] rq4_pixel_vec;
    wire [31:0] rq4_cout_vec;
    wire signed [31:0] rq4_data_vec;
    reg [1:0] rq4_sel_lane;
    wire [255:0] rq4_bias_vec;
    wire [255:0] rq4_multiplier_vec;
    wire [47:0] rq4_shift_vec;
    /* Compatibility trace aliases retained for existing directed benches;
     * they are observational only and do not participate in control. */
    wire rq_fire = rq4_valid_in && rq4_ready_in;
    wire [6:0] rq_pixel_idx_wide = pw_pixel_base;
    wire [9:0] rq_cout_idx_wide = pw_cout_base;
    wire signed [2047:0] rq_psum_shift = pw_psum_out;

    wire [7:0] output_pixels;
    wire pw_phase_state;
    wire rq4_vec4_eligible;

    integer cfg_addr;
    integer param_channel;
    genvar input_lane_g;
    genvar rq_param_g;
    genvar pw_mask_g;

    assign cfg_ready = !busy;
    assign cfg_weight_word_ready = !busy &&
                                   (cfg_weight_word_target ?
                                    pw_weight_word_ready : 1'b1);
    assign input_buf_wr_en = cfg_wr_en && cfg_ready && (cfg_target == CFG_INPUT);
    assign pw_weight_wr_en = cfg_wr_en && cfg_ready && (cfg_target == CFG_PW_WEIGHT);
    assign pw_weight_word_wr_en = cfg_weight_word_wr_en && cfg_ready &&
                                  cfg_weight_word_target;

    assign stream_in_h = (({1'b0, out_h_reg} - 5'd1) * stride_reg) + 5'd3;
    assign stream_in_w = (({1'b0, out_w_reg} - 5'd1) * stride_reg) + 5'd3;
    assign stream_pixel_idx = (stream_y * MAX_IN_W) + stream_x;
    assign input_buf_rd_en = (state == ST_DW_INPUT_REQ);
    assign input_buf_rd_pixel = stream_pixel_idx;
    assign input_buf_rd_channel_tile = dw_channel_base[6:4];

    generate
        for (input_lane_g = 0; input_lane_g < DW_LANES; input_lane_g = input_lane_g + 1) begin : gen_input_mask
            assign dw_pixel_vec[(input_lane_g*8) +: 8] =
                ((dw_channel_base + input_lane_g) < channels_reg)
                ? input_buf_rd_data[(input_lane_g*8) +: 8]
                : input_zero_point_reg;
        end
    endgenerate

    assign dw_valid_in = (state == ST_DW_INPUT_FEED);
    assign dw_output_accept = dw_valid_out;
    assign dw_buf_wr_en =
        dw_output_accept && ({1'b0, dw_out_channel_idx} < channels_reg);
    assign dw_output_accept_vec4 = dw_valid_out_vec4;

    assign output_pixels = out_h_reg * out_w_reg;
    generate
        for (pw_mask_g = 0; pw_mask_g < 8; pw_mask_g = pw_mask_g + 1) begin : gen_pw_tail_mask
            assign pw_pixel_mask[pw_mask_g] =
                (({2'b0, pw_pixel_base} + pw_mask_g) < output_pixels);
            assign pw_cout_mask[pw_mask_g] =
                (({6'b0, pw_cout_base} + pw_mask_g) < out_channels_reg);
        end
    endgenerate
    // Prime both synchronous BRAMs once, then issue the next K entry in the
    // same cycle that the current entry is accepted by the MAC array.  Keeping
    // the read and feed indices separate removes the former READ/FEED bubble
    // without changing the BRAM's one-cycle read contract.
    assign pw_read_issue = !USE_PERSISTENT_FEED &&
        (state == ST_PW_READ) ||
        (!USE_PERSISTENT_FEED && (state == ST_PW_FEED) && pw_fire &&
         ({1'b0, pw_read_idx} < channels_reg));
    assign dw_buf_rd_en = USE_PERSISTENT_FEED ? persistent_source_rd_en : pw_read_issue;
    assign pw_weight_rd_en = USE_PERSISTENT_FEED ? persistent_weight_rd_en : pw_read_issue;
    assign pw_valid_in = USE_UNIFIED64 ?
                         ((state == ST_PW_FEED) && unified_input_stage_valid) :
                         ((state == ST_PW_FEED) &&
                          dw_buf_rd_valid && pw_weight_rd_valid);
    assign pw_fire = pw_valid_in && pw_core_ready;

    assign shared_valid_in = USE_SHARED_ARRAY &&
                             (USE_PERSISTENT_FEED ? persistent_token_valid : pw_valid_in);
    assign shared_first_k = USE_PERSISTENT_FEED ? persistent_token_first : (pw_k_idx == 8'd0);
    assign shared_last_k = USE_PERSISTENT_FEED ? persistent_token_last :
                           ((pw_k_idx + 8'd1) >= channels_reg);
    assign shared_k_idx = USE_PERSISTENT_FEED ? persistent_token_k : pw_k_idx;
    assign shared_act_vec = USE_PERSISTENT_FEED ? persistent_token_act : pw_act_vec;
    assign shared_wgt_vec16 = USE_PERSISTENT_FEED ? {64'd0, persistent_token_wgt} :
                              {64'd0, pw_wgt_vec};
    assign shared_pixel_mask = USE_PERSISTENT_FEED ? persistent_token_pixel_mask : pw_pixel_mask;
    assign shared_cout_mask = USE_PERSISTENT_FEED ? {8'd0, persistent_token_cout_mask} :
                              {8'd0, pw_cout_mask};
    assign shared_pixel_base = USE_PERSISTENT_FEED ? {3'd0, persistent_token_pixel} :
                               {5'd0, pw_pixel_base};
    assign shared_cout_base = USE_PERSISTENT_FEED ? persistent_token_cout : pw_cout_base;
    genvar shared_param_g;
    generate for (shared_param_g=0; shared_param_g<16; shared_param_g=shared_param_g+1) begin : gen_shared_ds_params
        if (shared_param_g < 8) begin : gen_shared_ds_param_valid
            assign shared_bias_vec[(shared_param_g*32)+:32] = rq4_bias_vec[(shared_param_g*32)+:32];
            assign shared_multiplier_vec[(shared_param_g*32)+:32] = rq4_multiplier_vec[(shared_param_g*32)+:32];
            assign shared_shift_vec[(shared_param_g*6)+:6] = rq4_shift_vec[(shared_param_g*6)+:6];
        end else begin : gen_shared_ds_param_zero
            assign shared_bias_vec[(shared_param_g*32)+:32] = 32'sd0;
            assign shared_multiplier_vec[(shared_param_g*32)+:32] = 32'sd0;
            assign shared_shift_vec[(shared_param_g*6)+:6] = 6'd0;
        end
    end endgenerate
    /* DS output commits are accepted by the runner's SRAM write port without
     * backpressure.  Keep the shared drain running while the PW feeder moves
     * on to later blocks; waiting for ST_PW_WAIT here would deadlock the
     * two-bank overlap when an earlier block is being drained. */
    assign shared_out_ready = USE_SHARED_ARRAY;

    assign rq4_valid_in = (state == ST_PW_WAIT) && pw_valid_out;
    assign rq4_vec4_eligible = (rq4_valid_out == 4'b1111) &&
                               (rq4_pixel_vec[5:0] == rq4_pixel_vec[11:6]) &&
                               (rq4_pixel_vec[5:0] == rq4_pixel_vec[17:12]) &&
                               (rq4_pixel_vec[5:0] == rq4_pixel_vec[23:18]) &&
                               (rq4_cout_vec[1:0] == 2'b00) &&
                               (rq4_cout_vec[15:8] == (rq4_cout_vec[7:0] + 8'd1)) &&
                               (rq4_cout_vec[23:16] == (rq4_cout_vec[15:8] + 8'd1)) &&
                               (rq4_cout_vec[31:24] == (rq4_cout_vec[23:16] + 8'd1));
    assign out_wr_vec4_en = USE_UNIFIED64 ? unified_pw_valid_out :
                            rq4_vec4_eligible;
    assign out_wr_vec4_pixel_idx = USE_UNIFIED64 ? unified_pw_out_pixel[5:0] :
                                   rq4_pixel_vec[5:0];
    assign out_wr_vec4_channel_idx = USE_UNIFIED64 ? unified_pw_out_cout[7:0] :
                                     rq4_cout_vec[7:0];
    assign out_wr_vec4_data_int8 = USE_UNIFIED64 ? unified_pw_out_data :
                                   rq4_data_vec;
    assign out_wr_en = !USE_UNIFIED64 && (|rq4_valid_out) &&
                       !rq4_vec4_eligible;
    assign out_wr_pixel_idx = rq4_pixel_vec[(rq4_sel_lane * 6) +: 6];
    assign out_wr_channel_idx = rq4_cout_vec[(rq4_sel_lane * 8) +: 8];
    assign out_wr_data_int8 = rq4_data_vec[(rq4_sel_lane * 8) +: 8];

    always @* begin
        rq4_sel_lane = 2'd0;
        if (rq4_valid_out[0]) rq4_sel_lane = 2'd0;
        else if (rq4_valid_out[1]) rq4_sel_lane = 2'd1;
        else if (rq4_valid_out[2]) rq4_sel_lane = 2'd2;
        else if (rq4_valid_out[3]) rq4_sel_lane = 2'd3;
        rq4_ready_out = 4'b0;
        if (rq4_vec4_eligible)
            rq4_ready_out = 4'b1111;
        else if (|rq4_valid_out)
            rq4_ready_out[rq4_sel_lane] = 1'b1;
    end

    generate
        for (rq_param_g = 0; rq_param_g < 8; rq_param_g = rq_param_g + 1) begin : gen_rq_param_vec
            if (rq_param_g < MAX_COUT) begin : gen_valid_param
            assign rq4_bias_vec[(rq_param_g*32) +: 32] =
                    pw_bias_mem[(USE_PERSISTENT_FEED ? persistent_block_cout : pw_cout_base) + rq_param_g];
                assign rq4_multiplier_vec[(rq_param_g*32) +: 32] =
                    pw_multiplier_mem[(USE_PERSISTENT_FEED ? persistent_block_cout : pw_cout_base) + rq_param_g];
                assign rq4_shift_vec[(rq_param_g*6) +: 6] =
                    pw_shift_mem[(USE_PERSISTENT_FEED ? persistent_block_cout : pw_cout_base) + rq_param_g];
            end else begin : gen_zero_param
                assign rq4_bias_vec[(rq_param_g*32) +: 32] = 32'sd0;
                assign rq4_multiplier_vec[(rq_param_g*32) +: 32] = 32'd0;
                assign rq4_shift_vec[(rq_param_g*6) +: 6] = 6'd0;
            end
        end
    endgenerate

    assign pw_phase_state =
        (state == ST_PW_INIT) ||
        (state == ST_PW_READ) ||
        (state == ST_PW_FEED) ||
        (state == ST_PW_WAIT) ||
        (state == ST_RQ_ISSUE) ||
        (state == ST_RQ_DRAIN) ||
        (state == ST_ADVANCE);

    ds_input_tile_buffer_bram #(
        .MAX_CIN(MAX_CIN),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W),
        .LANES(DW_LANES)
    ) u_input_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(input_buf_wr_en),
        .wr_linear_idx(cfg_index),
        .wr_data_int8(cfg_data[7:0]),
        .wr_vec4_en(cfg_vec4_wr_en && cfg_ready),
        .wr_vec4_linear_idx(cfg_vec4_index),
        .wr_vec4_data_int8(cfg_vec4_data),
        .rd_en(input_buf_rd_en),
        .rd_pixel_idx(input_buf_rd_pixel),
        .rd_channel_tile(input_buf_rd_channel_tile),
        .rd_valid(input_buf_rd_valid),
        .rd_data_vector(input_buf_rd_data)
    );

    pw_weight_buffer_bram #(
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .LANES(PW_LANES)
    ) u_pw_weight_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(pw_weight_wr_en),
        .wr_linear_idx(cfg_index[14:0]),
        .wr_data_int8(cfg_data[7:0]),
        .wr_word_en(pw_weight_word_wr_en),
        .wr_word_index(cfg_weight_word_index[14:0]),
        .wr_word_data_int8(cfg_weight_word_data),
        .wr_word_be(cfg_weight_word_be),
        .wr_word_ready(pw_weight_word_ready),
        .rd_en(pw_weight_rd_en),
        .rd_cout_base(USE_PERSISTENT_FEED ? persistent_weight_rd_cout_base : pw_cout_base),
        .rd_channel_idx(USE_PERSISTENT_FEED ? persistent_weight_rd_channel_idx : pw_read_idx),
        .rd_valid(pw_weight_rd_valid),
        .rd_data_vector(pw_weight_rd_data)
    );

    dw_tile_fusion_engine_vector4 #(
        .DW_LANES(DW_LANES),
        .VECTOR4_OUTPUT(1'b1)
    ) u_dw_engine (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(dw_valid_in),
        .ready_in(dw_ready_in),
        .x_idx(stream_x),
        .y_idx(stream_y),
        .pixel_vec_in(dw_pixel_vec),
        .out_h(dw_out_h_engine_reg),
        .out_w(dw_out_w_engine_reg),
        .stride(dw_stride_engine_reg),
        .channel_base(dw_channel_engine_reg),
        .weight_vec(dw_weight_vec),
        .bias_vec(dw_bias_vec),
        .multiplier_vec(dw_multiplier_vec),
        .shift_vec(dw_shift_vec),
        .output_zero_point(dw_output_zero_point_reg),
        .activation_min(dw_activation_min_reg),
        .activation_max(dw_activation_max_reg),
        .ready_out(1'b1),
        .ready_out_vec4(1'b1),
        .valid_out(dw_valid_out),
        .out_pixel_idx(dw_out_pixel_idx),
        .out_channel_idx(dw_out_channel_idx),
        .out_data_int8(dw_out_data_int8),
        .valid_out_vec4(dw_valid_out_vec4),
        .out_pixel_idx_vec4(dw_out_pixel_idx_vec4),
        .out_channel_idx_vec4(dw_out_channel_idx_vec4),
        .out_data_int8_vec4(dw_out_data_int8_vec4),
        .busy(dw_busy),
        .done(dw_done)
    );

    dw_tile_buffer_bram u_dw_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(dw_buf_wr_en),
        .wr_pixel_idx(dw_out_pixel_idx),
        .wr_channel_idx(dw_out_channel_idx),
        .wr_data_int8(dw_out_data_int8),
        .wr_vec4_en(dw_output_accept_vec4),
        .wr_vec4_pixel_idx(dw_out_pixel_idx_vec4),
        .wr_vec4_channel_idx(dw_out_channel_idx_vec4),
        .wr_vec4_data_int8(dw_out_data_int8_vec4),
        .wr_vec4_byte_en({
            (dw_out_channel_idx_vec4 + 7'd3 < channels_reg),
            (dw_out_channel_idx_vec4 + 7'd2 < channels_reg),
            (dw_out_channel_idx_vec4 + 7'd1 < channels_reg),
            (dw_out_channel_idx_vec4 < channels_reg)
        }),
        .rd_en(dw_buf_rd_en),
        .rd_pixel_base(USE_PERSISTENT_FEED ? persistent_source_rd_pixel_base : pw_pixel_base),
        .rd_channel_idx(USE_PERSISTENT_FEED ? persistent_source_rd_channel_idx[6:0] : pw_read_idx[6:0]),
        .rd_valid(dw_buf_rd_valid),
        .rd_data_vector(dw_buf_rd_data)
    );

    assign persistent_source_rd_valid = dw_buf_rd_valid;
    assign persistent_source_rd_data = dw_buf_rd_data;
    assign persistent_weight_rd_valid = pw_weight_rd_valid;
    assign persistent_weight_rd_data = pw_weight_rd_data;

    /* Persistent row-feed mode owns PW block sequencing after DW completes.
     * The existing unified64/shared array remains the arithmetic owner, so
     * this module only replaces source/weight issue and token metadata. */
    assign persistent_start = USE_PERSISTENT_FEED && (state == ST_PW_INIT);
    ds_persistent_pw_row_feed #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT), .MAX_PIXELS(64)
    ) u_persistent_pw_feed (
        .clk(clk), .rst_n(rst_n), .start(persistent_start),
        .busy(persistent_busy), .done(persistent_done), .error(persistent_error),
        .channels(channels_reg), .out_channels(out_channels_reg),
        .output_pixels(USE_PERSISTENT_FEED ? persistent_output_pixels_reg : output_pixels),
        .source_rd_en(persistent_source_rd_en),
        .source_rd_pixel_base(persistent_source_rd_pixel_base),
        .source_rd_channel_idx(persistent_source_rd_channel_idx),
        .source_rd_valid(persistent_source_rd_valid), .source_rd_data(persistent_source_rd_data),
        .weight_rd_en(persistent_weight_rd_en),
        .weight_rd_cout_base(persistent_weight_rd_cout_base),
        .weight_rd_channel_idx(persistent_weight_rd_channel_idx),
        .weight_rd_valid(persistent_weight_rd_valid), .weight_rd_data(persistent_weight_rd_data),
        .token_valid(persistent_token_valid), .token_ready(persistent_token_ready),
        .token_first(persistent_token_first), .token_last(persistent_token_last),
        .token_k_idx(persistent_token_k), .token_act_vec(persistent_token_act),
        .token_wgt_vec(persistent_token_wgt), .token_pixel_base(persistent_token_pixel),
        .token_cout_base(persistent_token_cout), .token_pixel_mask(persistent_token_pixel_mask),
        .token_cout_mask(persistent_token_cout_mask),
        .result_valid(shared_out_valid), .result_ready(1'b1),
        .result_pixel_idx(shared_out_pixel_idx), .result_channel_base(shared_out_channel_base),
        .result_lane_mask(shared_out_lane_mask), .block_pixel_base(persistent_block_pixel),
        .block_cout_base(persistent_block_cout),
        .metric_source_window_reads(persistent_source_window_reads),
        .metric_window_reuse(persistent_window_reuse), .metric_token_count(persistent_token_count)
    );
    assign persistent_token_ready = USE_PERSISTENT_FEED && shared_ready_in;

    generate
        if (!USE_UNIFIED64) begin : gen_legacy_pw
            pw_direct_8x8_dsp u_pw_array (
                .clk(clk),
                .rst_n(rst_n),
                .valid_in(pw_valid_in),
                .ready_in(pw_ready_in),
                .first_k(pw_k_idx == 8'd0),
                .last_k((pw_k_idx + 8'd1) >= channels_reg),
                .k_idx(pw_k_idx),
                .pixel_mask(pw_pixel_mask),
                .cout_mask(pw_cout_mask),
                .act_vec(pw_act_vec),
                .wgt_vec(pw_wgt_vec),
                .ready_out(rq4_ready_in),
                .valid_out(pw_valid_out),
                .psum_out(pw_psum_out),
                .lane_mask_out(pw_lane_mask_out)
            );

            requant_activation_vector4 u_pw_requant_vector4 (
                .clk(clk),
                .rst_n(rst_n),
                .valid_in(rq4_valid_in),
                .ready_in(rq4_ready_in),
                .psum_in(pw_psum_out),
                .pixel_base(pw_pixel_base),
                .cout_base(pw_cout_base),
                .output_pixels(output_pixels),
                .output_channels(out_channels_reg),
                .bias_vec(rq4_bias_vec),
                .multiplier_vec(rq4_multiplier_vec),
                .shift_vec(rq4_shift_vec),
                .output_zero_point_int32(pw_output_zero_point_reg),
                .activation_min_int32(pw_activation_min_reg),
                .activation_max_int32(pw_activation_max_reg),
                .valid_out(rq4_valid_out),
                .ready_out(rq4_ready_out),
                .out_pixel_idx_vec(rq4_pixel_vec),
                .out_channel_idx_vec(rq4_cout_vec),
                .out_data_int8_vec(rq4_data_vec),
                .busy(rq4_busy)
            );
        end else if (USE_SHARED_ARRAY) begin : gen_shared_unified64_pw
            /* The physical MAC/RQ owner is instantiated once by the layer
             * runner.  This branch retains the existing PW FSM and its
             * output ABI while exporting only the narrow DS transaction. */
            assign unified_pw_ready_in = shared_ready_in;
            assign unified_pw_valid_out = shared_out_valid;
            assign unified_pw_out_pixel = shared_out_pixel_idx;
            assign unified_pw_out_cout = shared_out_channel_base;
            assign unified_pw_out_mask = shared_out_lane_mask;
            assign unified_pw_out_data = shared_out_data;
            assign unified_pw_busy = 1'b0;
        end else begin : gen_unified64_pw
            unified64_tile_engine u_unified64_pw (
                .clk(clk), .rst_n(rst_n),
                .valid_in(pw_valid_in), .ready_in(unified_pw_ready_in),
                .first_k(pw_k_idx == 8'd0),
                .last_k((pw_k_idx + 8'd1) >= channels_reg),
                .k_idx(pw_k_idx), .pixel_mask(pw_pixel_mask),
                .cout_mask(pw_cout_mask), .act_vec(dw_buf_rd_data),
                .wgt_vec(pw_weight_rd_data), .pixel_base({5'd0,pw_pixel_base}),
                .cout_base(pw_cout_base), .bias_vec(rq4_bias_vec),
                .multiplier_vec(rq4_multiplier_vec), .shift_vec(rq4_shift_vec),
                .output_zero_point_int32(pw_output_zero_point_reg),
                .activation_min_int32(pw_activation_min_reg),
                .activation_max_int32(pw_activation_max_reg),
                .ready_out(1'b1), .valid_out(unified_pw_valid_out),
                .out_pixel_idx(unified_pw_out_pixel),
                .out_channel_base(unified_pw_out_cout),
                .out_lane_mask(unified_pw_out_mask),
                .out_data(unified_pw_out_data), .busy(unified_pw_busy),
                .metric_token_count(), .metric_masked_mac_count(),
                .metric_commit_count(), .metric_output_stall_count(),
                .metric_overlap_count(), .metric_peak_occupancy(),
                .metric_nonzero_token_count()
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready) begin
            cfg_addr = cfg_index;
            case (cfg_target)
                CFG_DW_WEIGHT: begin
                    if (cfg_addr < (MAX_CIN * 9)) begin
                        dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    end
                end
                CFG_DW_BIAS: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_bias_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_DW_MUL: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_multiplier_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_DW_SHIFT: begin
                    if (cfg_addr < MAX_CIN) begin
                        dw_shift_mem[cfg_addr] <= cfg_data[5:0];
                    end
                end
                CFG_PW_BIAS: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_bias_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_PW_MUL: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_multiplier_mem[cfg_addr] <= cfg_data;
                    end
                end
                CFG_PW_SHIFT: begin
                    if (cfg_addr < MAX_COUT) begin
                        pw_shift_mem[cfg_addr] <= cfg_data[5:0];
                    end
                end
            default: begin
            end
            endcase
        end
        // Packed DW words are retired through the scalar parameter port by
        // the layer runner.  Keeping this word ABI PW-only avoids a second
        // four-way write mux over the 1152-byte DW parameter array; PW still
        // forwards to its layout-aware canonical BRAM unpacker above.
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            out_h_reg <= 4'd0;
            out_w_reg <= 4'd0;
            channels_reg <= 8'd0;
            out_channels_reg <= 9'd0;
            stride_reg <= 2'd1;
            dw_stride_engine_reg <= 2'd1;
            dw_out_h_engine_reg <= 4'd0;
            dw_out_w_engine_reg <= 4'd0;
            dw_channel_engine_reg <= 7'd0;
            persistent_output_pixels_reg <= 8'd0;
            input_zero_point_reg <= 8'sd0;
            dw_output_zero_point_reg <= 32'sd0;
            dw_activation_min_reg <= 32'sd0;
            dw_activation_max_reg <= 32'sd0;
            pw_output_zero_point_reg <= 32'sd0;
            pw_activation_min_reg <= 32'sd0;
            pw_activation_max_reg <= 32'sd0;
            dw_channel_base <= 7'd0;
            dw_param_lane <= 4'd0;
            dw_param_kernel <= 4'd0;
            dw_param_channel_reg <= 8'd0;
            dw_param_addr_reg <= 11'd0;
            dw_param_weight_reg <= 8'sd0;
            dw_param_bias_reg <= 32'sd0;
            dw_param_multiplier_reg <= 32'sd0;
            dw_param_shift_reg <= 6'd0;
            stream_x <= 5'd0;
            stream_y <= 5'd0;
            dw_weight_vec <= {(DW_LANES*9*8){1'b0}};
            dw_bias_vec <= {(DW_LANES*32){1'b0}};
            dw_multiplier_vec <= {(DW_LANES*32){1'b0}};
            dw_shift_vec <= {(DW_LANES*6){1'b0}};
            dw_weight_lane_tmp <= 72'sd0;
            pw_pixel_base <= 6'd0;
            pw_cout_base <= 9'd0;
            pw_read_idx <= 8'd0;
            pw_k_idx <= 8'd0;
            unified_input_stage_valid <= 1'b0;
            unified_input_stage_act <= 64'd0;
            unified_input_stage_wgt <= 64'd0;
            perf_total_cycles <= 32'd0;
            perf_dw_cycles <= 32'd0;
            perf_pw_cycles <= 32'd0;
            perf_pw_issue_cycles <= 32'd0;
        end else begin
            done <= 1'b0;

            if (USE_UNIFIED64) begin
                if (state != ST_PW_FEED) begin
                    unified_input_stage_valid <= 1'b0;
                end else if (dw_buf_rd_valid && pw_weight_rd_valid) begin
                    unified_input_stage_act <= dw_buf_rd_data;
                    unified_input_stage_wgt <= pw_weight_rd_data;
                    unified_input_stage_valid <= 1'b1;
                end else if (pw_fire) begin
                    unified_input_stage_valid <= 1'b0;
                end
            end


            if (busy) begin
                perf_total_cycles <= perf_total_cycles + 32'd1;
                if (pw_phase_state) begin
                    perf_pw_cycles <= perf_pw_cycles + 32'd1;
                end else begin
                    perf_dw_cycles <= perf_dw_cycles + 32'd1;
                end
                if (pw_fire) begin
                    perf_pw_issue_cycles <= perf_pw_issue_cycles + 32'd1;
                end
            end

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        out_h_reg <= out_h;
                        out_w_reg <= out_w;
                        channels_reg <= channels;
                        out_channels_reg <= out_channels[8:0];
                        stride_reg <= stride;
                        dw_stride_engine_reg <= stride;
                        dw_out_h_engine_reg <= out_h;
                        dw_out_w_engine_reg <= out_w;
                        dw_channel_engine_reg <= 7'd0;
                        persistent_output_pixels_reg <= out_h * out_w;
                        input_zero_point_reg <= input_zero_point;
                        dw_output_zero_point_reg <= dw_output_zero_point;
                        dw_activation_min_reg <= dw_activation_min;
                        dw_activation_max_reg <= dw_activation_max;
                        pw_output_zero_point_reg <= pw_output_zero_point;
                        pw_activation_min_reg <= pw_activation_min;
                        pw_activation_max_reg <= pw_activation_max;
                        perf_total_cycles <= 32'd0;
                        perf_dw_cycles <= 32'd0;
                        perf_pw_cycles <= 32'd0;
                        perf_pw_issue_cycles <= 32'd0;
                        error <= 1'b0;
                        if ((out_h == 4'd0) ||
                            (out_w == 4'd0) ||
                            (out_h > 4'd8) ||
                            (out_w > 4'd8) ||
                            (channels == 8'd0) ||
                            (channels > MAX_CIN) ||
                            (out_channels == 16'd0) ||
                            (out_channels > MAX_COUT) ||
                            ((stride != 2'd1) && (stride != 2'd2))) begin
                            busy <= 1'b1;
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end else begin
                            busy <= 1'b1;
                            dw_channel_base <= 7'd0;
                            dw_channel_engine_reg <= 7'd0;
                            dw_param_lane <= 4'd0;
                            dw_param_kernel <= 4'd0;
                            dw_param_channel_reg <= 8'd0;
                            dw_param_addr_reg <= 11'd0;
                            dw_param_weight_reg <= 8'sd0;
                            dw_param_bias_reg <= 32'sd0;
                            dw_param_multiplier_reg <= 32'sd0;
                            dw_param_shift_reg <= 6'd0;
                            dw_weight_vec <= {(DW_LANES*9*8){1'b0}};
                            dw_bias_vec <= {(DW_LANES*32){1'b0}};
                            dw_multiplier_vec <= {(DW_LANES*32){1'b0}};
                            dw_shift_vec <= {(DW_LANES*6){1'b0}};
                            dw_weight_lane_tmp <= 72'sd0;
                            state <= ST_DW_PARAM_LOAD;
                        end
                    end
                end

                ST_DW_PARAM_LOAD: begin
                    /* Register both the channel and packed byte address
                     * before reading the distributed parameter store. */
                    dw_param_channel_reg <= dw_channel_base + dw_param_lane;
                    dw_param_addr_reg <=
                        ((dw_channel_base + dw_param_lane) * 11'd9) + dw_param_kernel;
                    state <= ST_DW_PARAM_READ;
                end

                ST_DW_PARAM_READ: begin
                    /* The registered address breaks the lane/control cone
                     * before the RAM output register. */
                    dw_param_weight_reg <= dw_weight_mem[dw_param_addr_reg];
                    if (dw_param_channel_reg < channels_reg) begin
                        dw_param_bias_reg <= dw_bias_mem[dw_param_channel_reg];
                        dw_param_multiplier_reg <= dw_multiplier_mem[dw_param_channel_reg];
                        dw_param_shift_reg <= dw_shift_mem[dw_param_channel_reg];
                    end else begin
                        dw_param_bias_reg <= 32'sd0;
                        dw_param_multiplier_reg <= 32'sd0;
                        dw_param_shift_reg <= 6'd0;
                    end
                    state <= ST_DW_PARAM_CAPTURE;
                end

                ST_DW_PARAM_CAPTURE: begin
                    param_channel = dw_param_channel_reg;
                    dw_weight_lane_tmp[(dw_param_kernel*8) +: 8] <=
                        dw_param_weight_reg;

                    if (dw_param_kernel == 4'd8) begin
                        /* Commit one finished 9-byte lane to a fixed slice.
                         * This keeps dw_param_lane out of the 1152-bit
                         * variable part-select while retaining one scalar
                         * parameter read port and the original 16x9 timing. */
                        case (dw_param_lane)
                            4'd0: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[0 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[0 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[0 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[0 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[0 +: 72] <= 72'sd0;
                                    dw_bias_vec[0 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[0 +: 32] <= 32'sd0;
                                    dw_shift_vec[0 +: 6] <= 6'd0;
                                end
                            end
                            4'd1: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[72 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[32 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[32 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[6 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[72 +: 72] <= 72'sd0;
                                    dw_bias_vec[32 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[32 +: 32] <= 32'sd0;
                                    dw_shift_vec[6 +: 6] <= 6'd0;
                                end
                            end
                            4'd2: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[144 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[64 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[64 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[12 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[144 +: 72] <= 72'sd0;
                                    dw_bias_vec[64 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[64 +: 32] <= 32'sd0;
                                    dw_shift_vec[12 +: 6] <= 6'd0;
                                end
                            end
                            4'd3: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[216 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[96 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[96 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[18 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[216 +: 72] <= 72'sd0;
                                    dw_bias_vec[96 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[96 +: 32] <= 32'sd0;
                                    dw_shift_vec[18 +: 6] <= 6'd0;
                                end
                            end
                            4'd4: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[288 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[128 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[128 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[24 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[288 +: 72] <= 72'sd0;
                                    dw_bias_vec[128 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[128 +: 32] <= 32'sd0;
                                    dw_shift_vec[24 +: 6] <= 6'd0;
                                end
                            end
                            4'd5: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[360 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[160 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[160 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[30 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[360 +: 72] <= 72'sd0;
                                    dw_bias_vec[160 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[160 +: 32] <= 32'sd0;
                                    dw_shift_vec[30 +: 6] <= 6'd0;
                                end
                            end
                            4'd6: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[432 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[192 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[192 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[36 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[432 +: 72] <= 72'sd0;
                                    dw_bias_vec[192 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[192 +: 32] <= 32'sd0;
                                    dw_shift_vec[36 +: 6] <= 6'd0;
                                end
                            end
                            4'd7: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[504 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[224 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[224 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[42 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[504 +: 72] <= 72'sd0;
                                    dw_bias_vec[224 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[224 +: 32] <= 32'sd0;
                                    dw_shift_vec[42 +: 6] <= 6'd0;
                                end
                            end
                            4'd8: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[576 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[256 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[256 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[48 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[576 +: 72] <= 72'sd0;
                                    dw_bias_vec[256 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[256 +: 32] <= 32'sd0;
                                    dw_shift_vec[48 +: 6] <= 6'd0;
                                end
                            end
                            4'd9: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[648 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[288 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[288 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[54 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[648 +: 72] <= 72'sd0;
                                    dw_bias_vec[288 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[288 +: 32] <= 32'sd0;
                                    dw_shift_vec[54 +: 6] <= 6'd0;
                                end
                            end
                            4'd10: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[720 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[320 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[320 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[60 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[720 +: 72] <= 72'sd0;
                                    dw_bias_vec[320 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[320 +: 32] <= 32'sd0;
                                    dw_shift_vec[60 +: 6] <= 6'd0;
                                end
                            end
                            4'd11: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[792 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[352 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[352 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[66 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[792 +: 72] <= 72'sd0;
                                    dw_bias_vec[352 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[352 +: 32] <= 32'sd0;
                                    dw_shift_vec[66 +: 6] <= 6'd0;
                                end
                            end
                            4'd12: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[864 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[384 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[384 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[72 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[864 +: 72] <= 72'sd0;
                                    dw_bias_vec[384 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[384 +: 32] <= 32'sd0;
                                    dw_shift_vec[72 +: 6] <= 6'd0;
                                end
                            end
                            4'd13: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[936 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[416 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[416 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[78 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[936 +: 72] <= 72'sd0;
                                    dw_bias_vec[416 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[416 +: 32] <= 32'sd0;
                                    dw_shift_vec[78 +: 6] <= 6'd0;
                                end
                            end
                            4'd14: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[1008 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[448 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[448 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[84 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[1008 +: 72] <= 72'sd0;
                                    dw_bias_vec[448 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[448 +: 32] <= 32'sd0;
                                    dw_shift_vec[84 +: 6] <= 6'd0;
                                end
                            end
                            default: begin
                                if (param_channel < channels_reg) begin
                                    dw_weight_vec[1080 +: 72] <=
                                        {dw_param_weight_reg, dw_weight_lane_tmp[63:0]};
                                    dw_bias_vec[480 +: 32] <= dw_param_bias_reg;
                                    dw_multiplier_vec[480 +: 32] <= dw_param_multiplier_reg;
                                    dw_shift_vec[90 +: 6] <= dw_param_shift_reg;
                                end else begin
                                    dw_weight_vec[1080 +: 72] <= 72'sd0;
                                    dw_bias_vec[480 +: 32] <= 32'sd0;
                                    dw_multiplier_vec[480 +: 32] <= 32'sd0;
                                    dw_shift_vec[90 +: 6] <= 6'd0;
                                end
                            end
                        endcase
                        dw_param_kernel <= 4'd0;
                        if (dw_param_lane == 4'd15) begin
                            dw_param_lane <= 4'd0;
                            stream_x <= 5'd0;
                            stream_y <= 5'd0;
                            state <= ST_DW_INPUT_REQ;
                        end else begin
                            dw_param_lane <= dw_param_lane + 4'd1;
                            state <= ST_DW_PARAM_LOAD;
                        end
                    end else begin
                        dw_param_kernel <= dw_param_kernel + 4'd1;
                        state <= ST_DW_PARAM_LOAD;
                    end
                end

                ST_DW_INPUT_REQ: begin
                    state <= ST_DW_INPUT_FEED;
                end

                ST_DW_INPUT_FEED: begin
                    if (dw_ready_in) begin
                        if ((stream_x + 5'd1) >= stream_in_w) begin
                            stream_x <= 5'd0;
                            if ((stream_y + 5'd1) >= stream_in_h) begin
                                state <= ST_DW_WAIT;
                            end else begin
                                stream_y <= stream_y + 5'd1;
                                state <= ST_DW_INPUT_REQ;
                            end
                        end else begin
                            stream_x <= stream_x + 5'd1;
                            state <= ST_DW_INPUT_REQ;
                        end
                    end
                end

                ST_DW_WAIT: begin
                    if (dw_done) begin
                        if (({1'b0, dw_channel_base} + DW_LANES) < channels_reg) begin
                            dw_channel_base <= dw_channel_base + DW_LANES;
                            dw_channel_engine_reg <= dw_channel_base + DW_LANES;
                            dw_param_lane <= 4'd0;
                            dw_param_kernel <= 4'd0;
                            state <= ST_DW_PARAM_LOAD;
                        end else begin
                            state <= ST_PW_INIT;
                        end
                    end
                end

                ST_PW_INIT: begin
                    pw_pixel_base <= 6'd0;
                    pw_cout_base <= 9'd0;
                    pw_read_idx <= 8'd0;
                    pw_k_idx <= 8'd0;
                    state <= USE_PERSISTENT_FEED ? ST_PW_WAIT : ST_PW_READ;
                end

                ST_PW_READ: begin
                    pw_read_idx <= 8'd1;
                    state <= ST_PW_FEED;
                end

                ST_PW_FEED: begin
                    if (pw_fire) begin
                        if ({1'b0, pw_read_idx} < channels_reg) begin
                            pw_read_idx <= pw_read_idx + 8'd1;
                        end
                        if ((pw_k_idx + 8'd1) >= channels_reg) begin
                            if (USE_UNIFIED64 &&
                                (((pw_pixel_base + PW_LANES) < output_pixels) ||
                                 ((pw_cout_base + PW_LANES) < out_channels_reg))) begin
                                pw_read_idx <= 8'd0;
                                pw_k_idx <= 8'd0;
                                if ((pw_cout_base + PW_LANES) < out_channels_reg) begin
                                    pw_cout_base <= pw_cout_base + PW_LANES;
                                end else begin
                                    pw_cout_base <= 9'd0;
                                    pw_pixel_base <= pw_pixel_base + PW_LANES;
                                end
                                state <= ST_PW_READ;
                            end else begin
                                state <= ST_PW_WAIT;
                            end
                        end else begin
                            pw_k_idx <= pw_k_idx + 8'd1;
                        end
                    end
                end

                ST_PW_WAIT: begin
                    if (USE_PERSISTENT_FEED) begin
                        if (persistent_error) begin
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end else if (persistent_done) begin
                            state <= ST_DONE;
                        end
                    end else begin
                    /* The legacy array presents one completed psum then
                     * drains it through rq4.  unified64 instead presents all
                     * sixteen row/half beats directly; only its final beat is
                     * the block completion fence. */
                    if ((USE_UNIFIED64 && unified_pw_final_fire) ||
                        (!USE_UNIFIED64 && pw_valid_out && rq4_ready_in)) begin
                        if (((pw_pixel_base + PW_LANES) >= output_pixels) &&
                            ((pw_cout_base + PW_LANES) >= out_channels_reg)) begin
                            state <= USE_UNIFIED64 ? ST_DONE : ST_RQ_DRAIN;
                        end else begin
                            state <= ST_ADVANCE;
                        end
                    end
                    end
                end

                ST_RQ_ISSUE: begin
                    state <= ST_PW_WAIT;
                end

                ST_RQ_DRAIN: begin
                    if (USE_UNIFIED64 || (!rq4_busy && !(|rq4_valid_out))) begin
                        state <= ST_DONE;
                    end
                end

                ST_ADVANCE: begin
                    pw_read_idx <= 8'd0;
                    pw_k_idx <= 8'd0;
                    if ((pw_cout_base + PW_LANES) < out_channels_reg) begin
                        pw_cout_base <= pw_cout_base + PW_LANES;
                        state <= ST_PW_READ;
                    end else if ((pw_pixel_base + PW_LANES) < output_pixels) begin
                        pw_cout_base <= 9'd0;
                        pw_pixel_base <= pw_pixel_base + PW_LANES;
                        state <= ST_PW_READ;
                    end else begin
                        state <= USE_UNIFIED64 ? ST_DONE : ST_RQ_DRAIN;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_ERROR: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    busy <= 1'b0;
                    error <= 1'b1;
                    state <= ST_ERROR;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
