`timescale 1ns/1ps
`default_nettype none

/*
 * Experimental spatial DS block scheduler.
 *
 * This is intentionally a separate engine from ds_block_tile_engine_new.  It
 * uses one direct 16-lane DW core to fill one transposed eight-pixel buffer
 * bank while a direct 8x8 PW core drains the previously committed bank.  The
 * buffer ownership protocol is the serialization boundary: DW may only write
 * its acquired bank and PW may only read its acquired, committed bank.
 *
 * The two workers have independent state machines.  A block is committed as
 * soon as its final DW group is written, allowing the PW worker to acquire it
 * while the DW worker proceeds with the opposite bank.  The output contract
 * is kept identical to ds_block_tile_engine_new; the internal
 * perf_overlap_cycles register is exposed to directed benches hierarchically.
 */
module ds_block_tile_engine_spatial #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               cfg_wr_en,
    output wire               cfg_ready,
    input  wire [3:0]         cfg_target,
    input  wire [15:0]        cfg_index,
    input  wire [31:0]        cfg_data,
    input  wire               cfg_vec4_wr_en,
    input  wire [15:0]        cfg_vec4_index,
    input  wire [31:0]        cfg_vec4_data,
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
    output wire               out_wr_vec4_en,
    output wire [5:0]         out_wr_vec4_pixel_idx,
    output wire [7:0]         out_wr_vec4_channel_idx,
    output wire [31:0]        out_wr_vec4_data_int8,

    output reg [31:0]         perf_total_cycles,
    output reg [31:0]         perf_dw_cycles,
    output reg [31:0]         perf_pw_cycles,
    output reg [31:0]         perf_pw_issue_cycles
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

    localparam DW_LANES = 16;
    localparam PW_LANES = 8;
    localparam CHANNEL_GROUPS = (MAX_CIN + DW_LANES - 1) / DW_LANES;
    localparam CHANNEL_GROUP_BITS = (CHANNEL_GROUPS <= 1) ? 1 : $clog2(CHANNEL_GROUPS);
    localparam BLOCK_ID_WIDTH = 8;
    localparam EPOCH_WIDTH = 2;

    /* Configuration storage follows the production linear addressing. */
    reg signed [7:0] dw_weight_mem [0:(MAX_CIN*9)-1];
    reg signed [31:0] dw_bias_mem [0:MAX_CIN-1];
    reg signed [31:0] dw_multiplier_mem [0:MAX_CIN-1];
    reg [5:0] dw_shift_mem [0:MAX_CIN-1];
    reg signed [7:0] pw_weight_mem [0:(MAX_CIN*MAX_COUT)-1];
    reg signed [31:0] pw_bias_mem [0:MAX_COUT-1];
    reg signed [31:0] pw_multiplier_mem [0:MAX_COUT-1];
    reg [5:0] pw_shift_mem [0:MAX_COUT-1];

    reg [3:0] out_h_reg, out_w_reg;
    reg [7:0] channels_reg;
    reg [8:0] out_channels_reg;
    reg [1:0] stride_reg;
    reg signed [7:0] input_zero_point_reg;
    reg signed [31:0] dw_zp_reg, dw_min_reg, dw_max_reg;
    reg signed [31:0] pw_zp_reg, pw_min_reg, pw_max_reg;
    reg [7:0] output_pixels_reg;
    reg [EPOCH_WIDTH-1:0] run_epoch;
    reg dw_finished, pw_finished;

    /* The proven transposed ping-pong buffer is the only shared resource. */
    wire dw_acquire_valid, dw_acquire_ready;
    wire dw_write_valid, dw_write_ready;
    wire dw_commit_valid, dw_commit_ready;
    wire pw_acquire_valid, pw_acquire_ready;
    wire pw_read_valid, pw_read_ready;
    wire pw_release_valid, pw_release_ready;
    wire pw_buf_out_valid;
    wire [EPOCH_WIDTH-1:0] pw_buf_out_epoch;
    wire [BLOCK_ID_WIDTH-1:0] pw_buf_out_block_id;
    wire pw_buf_out_bank;
    wire [63:0] pw_buf_out_data;
    wire [7:0] pw_buf_out_lane_mask;
    wire [1:0] bank0_state, bank1_state;
    wire [EPOCH_WIDTH-1:0] bank0_epoch, bank1_epoch;
    wire [BLOCK_ID_WIDTH-1:0] bank0_block_id, bank1_block_id;
    wire dw_commit_pulse, pw_acquire_pulse, pw_release_pulse;

    reg dw_acquire_bank;
    reg [BLOCK_ID_WIDTH-1:0] dw_acquire_block_id;
    reg [7:0] dw_acquire_pixel_mask, dw_acquire_group_mask;
    reg [2:0] dw_write_pixel_idx, dw_write_channel_group;
    reg dw_write_pixel_valid;
    reg [127:0] dw_write_data;
    reg [15:0] dw_write_lane_mask;
    reg dw_commit_bank;
    reg [BLOCK_ID_WIDTH-1:0] dw_commit_block_id;
    reg pw_acquire_bank;
    reg [BLOCK_ID_WIDTH-1:0] pw_acquire_block_id;
    reg pw_read_bank;
    reg [BLOCK_ID_WIDTH-1:0] pw_read_block_id;
    reg [6:0] pw_read_channel_idx;
    reg pw_buf_out_ready;
    reg pw_release_bank;
    reg [BLOCK_ID_WIDTH-1:0] pw_release_block_id;

    dw_pw_spatial_block_buffer_island #(
        .EPOCH_WIDTH(EPOCH_WIDTH), .BLOCK_ID_WIDTH(BLOCK_ID_WIDTH)
    ) u_spatial_buffer (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_epoch(run_epoch),
        .dw_acquire_block_id(dw_acquire_block_id),
        .dw_acquire_pixel_mask(dw_acquire_pixel_mask),
        .dw_acquire_group_mask(dw_acquire_group_mask),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_acquire_bank), .dw_write_epoch(run_epoch),
        .dw_write_block_id(dw_acquire_block_id),
        .dw_write_pixel_idx(dw_write_pixel_idx),
        .dw_write_pixel_valid(dw_write_pixel_valid),
        .dw_write_channel_group(dw_write_channel_group),
        .dw_write_data(dw_write_data), .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_epoch(run_epoch),
        .dw_commit_block_id(dw_commit_block_id),
        .pw_acquire_valid(pw_acquire_valid), .pw_acquire_ready(pw_acquire_ready),
        .pw_acquire_bank(pw_acquire_bank), .pw_acquire_epoch(run_epoch),
        .pw_acquire_block_id(pw_acquire_block_id),
        .pw_read_valid(pw_read_valid), .pw_read_ready(pw_read_ready),
        .pw_read_bank(pw_read_bank), .pw_read_epoch(run_epoch),
        .pw_read_block_id(pw_read_block_id),
        .pw_read_channel_idx(pw_read_channel_idx),
        .pw_out_valid(pw_buf_out_valid), .pw_out_ready(pw_buf_out_ready),
        .pw_out_epoch(pw_buf_out_epoch), .pw_out_block_id(pw_buf_out_block_id),
        .pw_out_bank(pw_buf_out_bank), .pw_out_data(pw_buf_out_data),
        .pw_out_lane_mask(pw_buf_out_lane_mask),
        .pw_release_valid(pw_release_valid), .pw_release_ready(pw_release_ready),
        .pw_release_bank(pw_release_bank), .pw_release_epoch(run_epoch),
        .pw_release_block_id(pw_release_block_id),
        .dw_commit_pulse(dw_commit_pulse), .pw_acquire_pulse(pw_acquire_pulse),
        .pw_release_pulse(pw_release_pulse), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .bank0_epoch(bank0_epoch),
        .bank1_epoch(bank1_epoch), .bank0_block_id(bank0_block_id),
        .bank1_block_id(bank1_block_id)
    );

    /* Input tile storage retains the production scalar/vector configuration
     * address map and supplies one 16-channel vector per synchronous read. */
    wire input_buf_rd_en, input_buf_rd_valid;
    wire [8:0] input_buf_rd_pixel;
    wire [CHANNEL_GROUP_BITS-1:0] input_buf_rd_group;
    wire signed [127:0] input_buf_rd_data;
    wire input_buf_wr_en = cfg_wr_en && cfg_ready && (cfg_target == CFG_INPUT);
    wire input_buf_vec4_wr_en = cfg_vec4_wr_en && cfg_ready && (cfg_target == CFG_INPUT);

    ds_input_tile_buffer_bram #(
        .MAX_CIN(MAX_CIN), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .LANES(DW_LANES)
    ) u_input_buffer (
        .clk(clk), .rst_n(rst_n), .wr_en(input_buf_wr_en),
        .wr_linear_idx(cfg_index), .wr_data_int8(cfg_data[7:0]),
        .wr_vec4_en(input_buf_vec4_wr_en), .wr_vec4_linear_idx(cfg_vec4_index),
        .wr_vec4_data_int8(cfg_vec4_data), .rd_en(input_buf_rd_en),
        .rd_pixel_idx(input_buf_rd_pixel), .rd_channel_tile(input_buf_rd_group),
        .rd_valid(input_buf_rd_valid), .rd_data_vector(input_buf_rd_data)
    );

    /* ---------------------------- DW worker ---------------------------- */
    localparam DW_IDLE = 4'd0;
    localparam DW_ACQUIRE = 4'd1;
    localparam DW_CONFIG = 4'd2;
    localparam DW_REQ = 4'd3;
    localparam DW_FEED = 4'd4;
    localparam DW_WAIT_WRITES = 4'd5;
    localparam DW_COMMIT = 4'd6;
    localparam DW_DONE = 4'd7;
    reg [3:0] dw_state;
    reg [7:0] dw_block_id;
    reg [CHANNEL_GROUP_BITS-1:0] dw_group;
    reg [3:0] dw_cfg_tap;
    reg [3:0] dw_tap;
    reg [3:0] dw_pixel;
    reg [3:0] dw_block_pixels;
    reg [7:0] dw_write_count;
    reg [4:0] dw_pixel_x, dw_pixel_y;
    /* Local cursor context.  Keep the active coordinate recurrence away from
     * the shared run-dimension registers: those registers fan out into the
     * PW worker, bank masks, and configuration logic.  The base cursor is
     * advanced once per completed block and is loaded into the active pixel
     * cursor only at DW_ACQUIRE. */
    reg [3:0] dw_cursor_width_reg;
    reg [1:0] dw_cursor_stride_reg;
    reg [4:0] dw_block_base_x_reg, dw_block_base_y_reg;
    reg signed [127:0] dw_core_cfg_weight_vec;
    reg signed [511:0] dw_core_cfg_bias_vec;
    reg signed [511:0] dw_core_cfg_multiplier_vec;
    reg [95:0] dw_core_cfg_shift_vec;
    wire dw_core_cfg_valid = (dw_state == DW_CONFIG);
    wire dw_core_cfg_ready;
    wire [3:0] dw_core_cfg_tap_idx = dw_cfg_tap;
    wire dw_core_valid_in = (dw_state == DW_FEED) && input_buf_rd_valid;
    wire dw_core_ready_in;
    wire dw_core_first = (dw_tap == 4'd0);
    wire dw_core_last = (dw_tap == 4'd8);
    wire [15:0] dw_core_lane_mask =
        (channels_reg - (dw_group * DW_LANES) >= DW_LANES)
        ? 16'hffff : ((16'h0001 << (channels_reg - (dw_group * DW_LANES))) - 1);
    wire [7:0] dw_core_pixel_idx = {4'd0, dw_pixel};
    wire signed [127:0] dw_core_act_vec = input_buf_rd_data;

    wire [4:0] dw_tap_y = (dw_tap < 3) ? 0 : ((dw_tap < 6) ? 1 : 2);
    wire [4:0] dw_tap_x = (dw_tap == 0 || dw_tap == 3 || dw_tap == 6) ? 0 :
                          ((dw_tap == 1 || dw_tap == 4 || dw_tap == 7) ? 1 : 2);
    assign input_buf_rd_en = (dw_state == DW_REQ);
    assign input_buf_rd_pixel =
        (((dw_pixel_y * dw_cursor_stride_reg) + dw_tap_y) * MAX_IN_W) +
        ((dw_pixel_x * dw_cursor_stride_reg) + dw_tap_x);
    assign input_buf_rd_group = dw_group;

    /* Narrow registered DW-command stream.  The producer owns the DW DSP
     * and requant stages; the scheduler only issues geometry/config tokens. */
    wire dw_cmd_valid;
    wire [2:0] dw_cmd_pixel_idx, dw_cmd_channel_group;
    wire dw_cmd_pixel_valid;
    wire [127:0] dw_cmd_data;
    wire [15:0] dw_cmd_lane_mask;
    ds_spatial_dw_producer_island u_dw_producer (
        .clk(clk), .rst_n(rst_n), .cfg_valid(dw_core_cfg_valid),
        .cfg_ready(dw_core_cfg_ready), .cfg_tap_idx(dw_core_cfg_tap_idx),
        .cfg_weight_vec(dw_core_cfg_weight_vec), .cfg_bias_vec(dw_core_cfg_bias_vec),
        .cfg_multiplier_vec(dw_core_cfg_multiplier_vec), .cfg_shift_vec(dw_core_cfg_shift_vec),
        .valid_in(dw_core_valid_in), .ready_in(dw_core_ready_in),
        .first_tap(dw_core_first), .last_tap(dw_core_last), .tap_idx(dw_tap),
        .pixel_idx(dw_core_pixel_idx), .lane_mask(dw_core_lane_mask),
        .act_vec(dw_core_act_vec), .output_zero_point(dw_zp_reg),
        .activation_min(dw_min_reg), .activation_max(dw_max_reg),
        .command_group(dw_group[2:0]), .command_valid(dw_cmd_valid),
        .command_ready(dw_write_ready), .command_pixel_idx(dw_cmd_pixel_idx),
        .command_pixel_valid(dw_cmd_pixel_valid),
        .command_channel_group(dw_cmd_channel_group), .command_data(dw_cmd_data),
        .command_lane_mask(dw_cmd_lane_mask)
    );

    assign dw_acquire_valid = (dw_state == DW_ACQUIRE);
    assign dw_acquire_bank = dw_block_id[0];
    assign dw_acquire_block_id = dw_block_id;
    always @* begin
        dw_acquire_pixel_mask = (output_pixels_reg - (dw_block_id * 8) >= 8)
                              ? 8'hff : ((8'h01 << (output_pixels_reg - (dw_block_id * 8))) - 1);
        dw_acquire_group_mask = (((channels_reg + 15) / 16) >= 8)
                              ? 8'hff : ((8'h01 << ((channels_reg + 15) / 16)) - 1);
    end
    assign dw_write_valid = dw_cmd_valid;
    assign dw_write_pixel_idx = dw_cmd_pixel_idx;
    assign dw_write_pixel_valid = dw_cmd_pixel_valid;
    assign dw_write_channel_group = dw_cmd_channel_group;
    assign dw_write_lane_mask = dw_cmd_lane_mask;
    assign dw_write_data = dw_cmd_data;
    assign dw_commit_valid = (dw_state == DW_COMMIT);
    assign dw_commit_bank = dw_block_id[0];
    assign dw_commit_block_id = dw_block_id;

    integer dw_cfg_i;
    integer dw_cfg_ch;
    always @* begin
        dw_core_cfg_weight_vec = 128'sd0;
        dw_core_cfg_bias_vec = 512'sd0;
        dw_core_cfg_multiplier_vec = 512'sd0;
        dw_core_cfg_shift_vec = 96'd0;
        for (dw_cfg_i = 0; dw_cfg_i < DW_LANES; dw_cfg_i = dw_cfg_i + 1) begin
            dw_cfg_ch = (dw_group * DW_LANES) + dw_cfg_i;
            if (dw_cfg_ch < MAX_CIN) begin
                dw_core_cfg_weight_vec[(dw_cfg_i*8) +: 8] =
                    dw_weight_mem[(dw_cfg_ch*9) + dw_cfg_tap];
                dw_core_cfg_bias_vec[(dw_cfg_i*32) +: 32] =
                    dw_bias_mem[dw_cfg_ch];
                dw_core_cfg_multiplier_vec[(dw_cfg_i*32) +: 32] =
                    dw_multiplier_mem[dw_cfg_ch];
                dw_core_cfg_shift_vec[(dw_cfg_i*6) +: 6] =
                    dw_shift_mem[dw_cfg_ch];
            end
        end
    end

    /* ---------------------------- PW worker ---------------------------- */
    localparam PW_ACQUIRE = 4'd0;
    localparam PW_READ = 4'd1;
    localparam PW_WAIT_CORE = 4'd2;
    localparam PW_RQ_DRAIN = 4'd3;
    localparam PW_RELEASE = 4'd4;
    localparam PW_DONE = 4'd5;
    reg [3:0] pw_state;
    reg [7:0] pw_block_id;
    reg [5:0] pw_group;
    reg [6:0] pw_read_idx;
    reg [6:0] pw_pending_k;
    reg pw_reads_done;
    wire pw_core_valid_in = pw_buf_out_valid && pw_core_ready_in && (pw_state == PW_READ);
    wire pw_core_ready_in;
    wire pw_core_valid_out;
    wire pw_core_first = (pw_pending_k == 0);
    wire pw_core_last = ((pw_pending_k + 1) >= channels_reg);
    wire [7:0] pw_core_pixel_mask =
        (pw_block_pixels >= 8) ? 8'hff : ((8'h01 << pw_block_pixels) - 1);
    wire [7:0] pw_core_cout_mask =
        (out_channels_reg - (pw_group * PW_LANES) >= PW_LANES)
        ? 8'hff : ((8'h01 << (out_channels_reg - (pw_group * PW_LANES))) - 1);
    wire [3:0] pw_block_pixels =
        (output_pixels_reg - (pw_block_id * 8) >= 8)
        ? 8 : (output_pixels_reg - (pw_block_id * 8));
    wire signed [63:0] pw_core_act_vec = pw_buf_out_data;
    wire [7:0] pw_pending_k8 = {1'b0, pw_pending_k};
    reg signed [63:0] pw_core_weight_vec;
    /* The PW consumer is entered only after the requant island has drained
     * its prior group, so its one result is always accepted.  Keeping this
     * boundary unconditionally ready prevents the requant FIFO count from
     * driving bank read enables and the PW geometry state across islands. */
    wire pw_core_valid_out_ready = 1'b1;
    wire signed [2047:0] pw_core_psum_out;
    wire [63:0] pw_core_lane_mask_out;

    assign pw_acquire_valid = (pw_state == PW_ACQUIRE);
    assign pw_acquire_bank = pw_block_id[0];
    assign pw_acquire_block_id = pw_block_id;
    assign pw_read_valid = (pw_state == PW_READ) && !pw_reads_done;
    assign pw_read_bank = pw_block_id[0];
    assign pw_read_block_id = pw_block_id;
    assign pw_read_channel_idx = pw_read_idx;
    assign pw_buf_out_ready = (pw_state == PW_READ) && pw_core_ready_in;
    assign pw_release_valid = (pw_state == PW_RELEASE);
    assign pw_release_bank = pw_block_id[0];
    assign pw_release_block_id = pw_block_id;

    integer pw_wi;
    integer pw_wo;
    always @* begin
        pw_core_weight_vec = 64'sd0;
        for (pw_wi = 0; pw_wi < PW_LANES; pw_wi = pw_wi + 1) begin
            pw_wo = (pw_group * PW_LANES) + pw_wi;
            if (pw_wo < MAX_COUT)
                pw_core_weight_vec[(pw_wi*8) +: 8] =
                    pw_weight_mem[(pw_wo*MAX_CIN) + pw_pending_k];
        end
    end

    ds_spatial_pw_consumer_island u_pw_consumer (
        .clk(clk), .rst_n(rst_n), .valid_in(pw_core_valid_in),
        .ready_in(pw_core_ready_in), .first_k(pw_core_first),
        .last_k(pw_core_last), .k_idx(pw_pending_k8),
        .pixel_mask(pw_core_pixel_mask), .cout_mask(pw_core_cout_mask),
        .act_vec(pw_core_act_vec), .wgt_vec(pw_core_weight_vec),
        .ready_out(pw_core_valid_out_ready), .valid_out(pw_core_valid_out),
        .psum_out(pw_core_psum_out), .lane_mask_out(pw_core_lane_mask_out)
    );

    /* One vector4 requantizer drains the direct PW result.  Its FIFO is
     * drained unconditionally because the DS output contract has no ready
     * signal; the resulting scalar/vector4 writes are stable for each cycle.
     */
    reg [5:0] rq_pixel_base;
    reg [8:0] rq_cout_base;
    wire rq_valid_in = (pw_state == PW_WAIT_CORE) && pw_core_valid_out;
    wire rq_ready_in;
    wire [3:0] rq_valid_out;
    reg [3:0] rq_ready_out;
    wire rq_busy;
    wire [23:0] rq_pixel_vec;
    wire [31:0] rq_cout_vec;
    wire signed [31:0] rq_data_vec;
    reg signed [255:0] rq_bias_vec;
    reg signed [255:0] rq_multiplier_vec;
    reg [47:0] rq_shift_vec;
    integer rq_pi;
    always @* begin
        rq_bias_vec = 256'sd0;
        rq_multiplier_vec = 256'sd0;
        rq_shift_vec = 48'd0;
        for (rq_pi = 0; rq_pi < PW_LANES; rq_pi = rq_pi + 1) begin
            if ((rq_cout_base + rq_pi) < MAX_COUT) begin
                rq_bias_vec[(rq_pi*32) +: 32] = pw_bias_mem[rq_cout_base + rq_pi];
                rq_multiplier_vec[(rq_pi*32) +: 32] = pw_multiplier_mem[rq_cout_base + rq_pi];
                rq_shift_vec[(rq_pi*6) +: 6] = pw_shift_mem[rq_cout_base + rq_pi];
            end
        end
    end

    always @* begin
        rq_ready_out = 4'b0;
        if (rq_valid_out[0]) rq_ready_out[0] = 1'b1;
        else if (rq_valid_out[1]) rq_ready_out[1] = 1'b1;
        else if (rq_valid_out[2]) rq_ready_out[2] = 1'b1;
        else if (rq_valid_out[3]) rq_ready_out[3] = 1'b1;
        if (rq_vec4_eligible)
            rq_ready_out = 4'b1111;
    end
    wire rq_vec4_eligible = (rq_valid_out == 4'b1111) &&
                            (rq_pixel_vec[5:0] == rq_pixel_vec[11:6]) &&
                            (rq_pixel_vec[5:0] == rq_pixel_vec[17:12]) &&
                            (rq_pixel_vec[5:0] == rq_pixel_vec[23:18]) &&
                            (rq_cout_vec[1:0] == 0) &&
                            (rq_cout_vec[15:8] == rq_cout_vec[7:0] + 1) &&
                            (rq_cout_vec[23:16] == rq_cout_vec[15:8] + 1) &&
                            (rq_cout_vec[31:24] == rq_cout_vec[23:16] + 1);
    assign out_wr_vec4_en = rq_vec4_eligible;
    assign out_wr_vec4_pixel_idx = rq_pixel_vec[5:0];
    assign out_wr_vec4_channel_idx = rq_cout_vec[7:0];
    assign out_wr_vec4_data_int8 = rq_data_vec;
    assign out_wr_en = (|rq_valid_out) && !rq_vec4_eligible;
    assign out_wr_pixel_idx = rq_pixel_vec[5:0];
    assign out_wr_channel_idx = rq_cout_vec[7:0];
    assign out_wr_data_int8 = rq_data_vec[7:0];

    requant_activation_vector4_spatial u_pw_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(rq_valid_in), .ready_in(rq_ready_in),
        .psum_in(pw_core_psum_out), .pixel_base(rq_pixel_base),
        .cout_base(rq_cout_base), .output_pixels(output_pixels_reg),
        .output_channels(out_channels_reg), .bias_vec(rq_bias_vec),
        .multiplier_vec(rq_multiplier_vec), .shift_vec(rq_shift_vec),
        .output_zero_point_int32(pw_zp_reg),
        .activation_min_int32(pw_min_reg), .activation_max_int32(pw_max_reg),
        .valid_out(rq_valid_out), .ready_out(rq_ready_out),
        .out_pixel_idx_vec(rq_pixel_vec), .out_channel_idx_vec(rq_cout_vec),
        .out_data_int8_vec(rq_data_vec), .busy(rq_busy)
    );

    /* Internal perf marker intentionally remains a register, not a new port,
     * so existing named-port benches can instantiate the same contract. */
    reg [31:0] perf_overlap_cycles;
    wire dw_active_cycle = (dw_state == DW_CONFIG) || (dw_state == DW_REQ) ||
                           (dw_state == DW_FEED) || (dw_state == DW_WAIT_WRITES);
    wire pw_active_cycle = (pw_state == PW_READ) || (pw_state == PW_WAIT_CORE) ||
                           (pw_state == PW_RQ_DRAIN);

    assign cfg_ready = !busy;

    integer cfg_addr;
    integer init_i;
    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready) begin
            cfg_addr = cfg_index;
            case (cfg_target)
                CFG_DW_WEIGHT: if (cfg_addr < MAX_CIN*9) dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                CFG_DW_BIAS: if (cfg_addr < MAX_CIN) dw_bias_mem[cfg_addr] <= cfg_data;
                CFG_DW_MUL: if (cfg_addr < MAX_CIN) dw_multiplier_mem[cfg_addr] <= cfg_data;
                CFG_DW_SHIFT: if (cfg_addr < MAX_CIN) dw_shift_mem[cfg_addr] <= cfg_data[5:0];
                CFG_PW_WEIGHT: if (cfg_addr < MAX_CIN*MAX_COUT) pw_weight_mem[cfg_addr] <= cfg_data[7:0];
                CFG_PW_BIAS: if (cfg_addr < MAX_COUT) pw_bias_mem[cfg_addr] <= cfg_data;
                CFG_PW_MUL: if (cfg_addr < MAX_COUT) pw_multiplier_mem[cfg_addr] <= cfg_data;
                CFG_PW_SHIFT: if (cfg_addr < MAX_COUT) pw_shift_mem[cfg_addr] <= cfg_data[5:0];
                default: begin end
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; error <= 1'b0;
            out_h_reg <= 0; out_w_reg <= 0; channels_reg <= 0;
            out_channels_reg <= 0; stride_reg <= 1; input_zero_point_reg <= 0;
            dw_zp_reg <= 0; dw_min_reg <= 0; dw_max_reg <= 0;
            pw_zp_reg <= 0; pw_min_reg <= 0; pw_max_reg <= 0;
            output_pixels_reg <= 0; run_epoch <= 0;
            dw_finished <= 0; pw_finished <= 0;
            dw_state <= DW_IDLE; pw_state <= PW_ACQUIRE;
            dw_block_id <= 0; dw_group <= 0; dw_cfg_tap <= 0; dw_tap <= 0;
            dw_pixel <= 0; dw_block_pixels <= 0; dw_write_count <= 0;
            dw_pixel_x <= 0; dw_pixel_y <= 0;
            dw_cursor_width_reg <= 0; dw_cursor_stride_reg <= 1;
            dw_block_base_x_reg <= 0; dw_block_base_y_reg <= 0;
            pw_block_id <= 0; pw_group <= 0; pw_read_idx <= 0;
            pw_pending_k <= 0; pw_reads_done <= 0;
            rq_pixel_base <= 0; rq_cout_base <= 0;
            perf_total_cycles <= 0; perf_dw_cycles <= 0; perf_pw_cycles <= 0;
            perf_pw_issue_cycles <= 0; perf_overlap_cycles <= 0;
        end else begin
            done <= 1'b0;
            if (busy) begin
                perf_total_cycles <= perf_total_cycles + 1;
                if (dw_active_cycle) perf_dw_cycles <= perf_dw_cycles + 1;
                if (pw_active_cycle) perf_pw_cycles <= perf_pw_cycles + 1;
                if (pw_core_valid_in && pw_core_ready_in)
                    perf_pw_issue_cycles <= perf_pw_issue_cycles + 1;
                if (dw_active_cycle && pw_active_cycle)
                    perf_overlap_cycles <= perf_overlap_cycles + 1;
                /* DW requantization has a fixed pipeline, so writes for the
                 * first pixels of a block arrive while later pixels are
                 * still being fed.  Count every accepted write globally,
                 * rather than only those observed after entering WAIT. */
                if (dw_write_valid && dw_write_ready)
                    dw_write_count <= dw_write_count + 1;
            end

            if (!busy && start) begin
                out_h_reg <= out_h; out_w_reg <= out_w; channels_reg <= channels;
                out_channels_reg <= out_channels[8:0]; stride_reg <= stride;
                dw_cursor_width_reg <= out_w;
                dw_cursor_stride_reg <= stride;
                dw_block_base_x_reg <= 0;
                dw_block_base_y_reg <= 0;
                input_zero_point_reg <= input_zero_point;
                dw_zp_reg <= dw_output_zero_point; dw_min_reg <= dw_activation_min;
                dw_max_reg <= dw_activation_max; pw_zp_reg <= pw_output_zero_point;
                pw_min_reg <= pw_activation_min; pw_max_reg <= pw_activation_max;
                output_pixels_reg <= out_h * out_w;
                perf_total_cycles <= 0; perf_dw_cycles <= 0; perf_pw_cycles <= 0;
                perf_pw_issue_cycles <= 0; perf_overlap_cycles <= 0;
                error <= 0; run_epoch <= run_epoch + 1'b1;
                if ((out_h == 0) || (out_w == 0) || (out_h*out_w > 64) ||
                    (channels == 0) || (channels > MAX_CIN) ||
                    (out_channels == 0) || (out_channels > MAX_COUT) ||
                    ((stride != 1) && (stride != 2))) begin
                    busy <= 1'b1; error <= 1'b1; dw_state <= DW_DONE; pw_state <= PW_DONE;
                    dw_finished <= 1'b1; pw_finished <= 1'b1;
                end else begin
                    busy <= 1'b1; dw_finished <= 0; pw_finished <= 0;
                    dw_state <= DW_ACQUIRE; pw_state <= PW_ACQUIRE;
                    dw_block_id <= 0; dw_group <= 0; dw_cfg_tap <= 0;
                    pw_block_id <= 0; pw_group <= 0;
                end
            end

            case (dw_state)
                DW_ACQUIRE: begin
                    if (dw_acquire_ready) begin
                        dw_block_pixels <= (output_pixels_reg - (dw_block_id*8) >= 8)
                                          ? 8 : (output_pixels_reg - (dw_block_id*8));
                        dw_write_count <= 0; dw_group <= 0; dw_cfg_tap <= 0;
                        dw_pixel <= 0;
                        dw_pixel_x <= dw_block_base_x_reg;
                        dw_pixel_y <= dw_block_base_y_reg;
                        dw_state <= DW_CONFIG;
                    end
                end
                DW_CONFIG: begin
                    if (dw_core_cfg_ready) begin
                        if (dw_cfg_tap == 8) begin
                            dw_tap <= 0; dw_pixel <= 0; dw_state <= DW_REQ;
                        end else dw_cfg_tap <= dw_cfg_tap + 1;
                    end
                end
                DW_REQ: begin
                    dw_state <= DW_FEED;
                end
                DW_FEED: begin
                    if (dw_core_valid_in && dw_core_ready_in) begin
                        if (dw_tap == 8) begin
                            if (dw_pixel + 1 >= dw_block_pixels) begin
                                /* The next block starts at the output pixel
                                 * immediately following this block.  Advance
                                 * the base cursor from the already-local
                                 * active cursor; no run dimension participates
                                 * in the active cursor D path. */
                                if ((dw_block_id + 1) * 8 < output_pixels_reg) begin
                                    if ((dw_pixel_x + 1) >= dw_cursor_width_reg) begin
                                        dw_block_base_x_reg <= 0;
                                        dw_block_base_y_reg <= dw_pixel_y + 1;
                                    end else begin
                                        dw_block_base_x_reg <= dw_pixel_x + 1;
                                        dw_block_base_y_reg <= dw_pixel_y;
                                    end
                                end
                                dw_state <= DW_WAIT_WRITES;
                            end else begin
                                dw_pixel <= dw_pixel + 1;
                                if ((dw_pixel_x + 1) >= dw_cursor_width_reg) begin
                                    dw_pixel_x <= 0; dw_pixel_y <= dw_pixel_y + 1;
                                end else dw_pixel_x <= dw_pixel_x + 1;
                                dw_tap <= 0; dw_state <= DW_REQ;
                            end
                        end else begin
                            dw_tap <= dw_tap + 1; dw_state <= DW_REQ;
                        end
                    end
                end
                DW_WAIT_WRITES: begin
                    if (dw_write_count >= dw_block_pixels) begin
                        if ((dw_group + 1) >= ((channels_reg + 15) / 16))
                            dw_state <= DW_COMMIT;
                        else begin
                            dw_group <= dw_group + 1;
                            dw_cfg_tap <= 0; dw_write_count <= 0; dw_state <= DW_CONFIG;
                        end
                    end
                end
                DW_COMMIT: begin
                    if (dw_commit_ready) begin
                        if ((dw_block_id + 1) * 8 >= output_pixels_reg) begin
                            dw_finished <= 1'b1; dw_state <= DW_DONE;
                        end else begin
                            dw_block_id <= dw_block_id + 1;
                            dw_state <= DW_ACQUIRE;
                        end
                    end
                end
                default: begin end
            endcase

            case (pw_state)
                PW_ACQUIRE: begin
                    if (pw_acquire_ready) begin
                        pw_group <= 0; pw_read_idx <= 0; pw_pending_k <= 0;
                        pw_reads_done <= 0; rq_pixel_base <= pw_block_id * 8;
                        rq_cout_base <= 0; pw_state <= PW_READ;
                    end
                end
                PW_READ: begin
                    if (pw_read_valid && pw_read_ready) begin
                        pw_pending_k <= pw_read_idx;
                        if (pw_read_idx + 1 >= channels_reg) pw_reads_done <= 1'b1;
                        else pw_read_idx <= pw_read_idx + 1;
                    end
                    if (pw_core_valid_in && pw_core_ready_in && pw_reads_done &&
                        (pw_pending_k + 1 >= channels_reg))
                        pw_state <= PW_WAIT_CORE;
                end
                PW_WAIT_CORE: begin
                    if (pw_core_valid_out)
                        pw_state <= PW_RQ_DRAIN;
                end
                PW_RQ_DRAIN: begin
                    if (!rq_busy && !(|rq_valid_out)) begin
                        if ((pw_group + 1) * 8 >= out_channels_reg)
                            pw_state <= PW_RELEASE;
                        else begin
                            pw_group <= pw_group + 1; rq_cout_base <= (pw_group + 1) * 8;
                            pw_read_idx <= 0; pw_pending_k <= 0; pw_reads_done <= 0;
                            pw_state <= PW_READ;
                        end
                    end
                end
                PW_RELEASE: begin
                    if (pw_release_ready) begin
                        if ((pw_block_id + 1) * 8 >= output_pixels_reg) begin
                            pw_finished <= 1'b1; pw_state <= PW_DONE;
                        end else begin
                            pw_block_id <= pw_block_id + 1; pw_state <= PW_ACQUIRE;
                        end
                    end
                end
                default: begin end
            endcase

            if (busy && dw_finished && pw_finished) begin
                busy <= 1'b0; done <= 1'b1; dw_state <= DW_IDLE; pw_state <= PW_DONE;
            end
        end
    end
endmodule

`default_nettype wire
