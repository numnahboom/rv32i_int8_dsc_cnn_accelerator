`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production integration of the paired-half DW scratch bank with the
 * packed pointwise-weight row store.  This variant deliberately leaves the
 * production runner untouched.  The DW side owns the scratch-bank protocol;
 * the PW side owns a committed packed weight image and presents one
 * output-stationary group at a time to the row-bank core.
 *
 * The important physical contract is that the compute weight address is
 * generated only inside pw_packed_rowstore_feeder from registered tile/group/K
 * cursors.  job_cout_base is forwarded to the row-bank solely as its output
 * tag; it is never part of a dynamic weight-memory address or mux select.
 */
module dw_pw_pair_scratch_rowbank2_packed_consumer #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer MAX_GROUPS = 16,
    parameter integer SESSION_WIDTH = 2,
    parameter integer EPOCH_WIDTH = 2,
    parameter integer GROUP_WIDTH = 5,
    parameter integer ROWBANK_ACT_REPLICATE = 1
) (
    input wire clk,
    input wire rst_n,

    /* DW-side paired-half scratch-bank interface. */
    input wire dw_acquire_valid,
    output wire dw_acquire_ready,
    input wire dw_acquire_bank,
    input wire [SESSION_WIDTH-1:0] dw_acquire_session,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [GROUP_WIDTH-1:0] dw_acquire_group_count,
    input wire dw_write_valid,
    output wire dw_write_ready,
    input wire dw_write_bank,
    input wire [GROUP_WIDTH-1:0] dw_write_group,
    input wire dw_write_half,
    input wire [255:0] dw_write_data,
    input wire [31:0] dw_write_lane_mask,
    input wire dw_commit_valid,
    output wire dw_commit_ready,
    input wire dw_commit_bank,
    input wire [SESSION_WIDTH-1:0] dw_commit_session,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,

    /* Packed PW image loader: tile-major, K-minor, two 32-bit words/row. */
    input wire pw_load_begin_valid,
    output wire pw_load_begin_ready,
    input wire [1:0] pw_load_epoch,
    input wire [7:0] pw_load_cin,
    input wire [8:0] pw_load_cout,
    input wire pw_load_word_valid,
    output wire pw_load_word_ready,
    input wire [31:0] pw_load_word_data,
    input wire pw_load_commit_valid,
    output wire pw_load_commit_ready,
    output wire pw_load_commit_reject,
    output wire pw_load_extra_error,
    output wire pw_load_active,
    output wire pw_committed_valid,
    output wire [1:0] pw_committed_epoch,
    output wire [13:0] pw_expected_word_count,
    output wire [13:0] pw_load_word_count,
    output wire [15:0] pw_packed_load_count,

    /* One PW job consumes one committed scratch bank. */
    input wire job_valid,
    output wire job_ready,
    input wire [4:0] job_cout_tile,
    input wire job_bank,
    input wire [SESSION_WIDTH-1:0] job_session,
    input wire [EPOCH_WIDTH-1:0] job_epoch,
    input wire [GROUP_WIDTH-1:0] job_group_count,
    input wire job_reverse_groups,
    input wire [5:0] job_pixel_base,
    input wire [8:0] job_cout_base,
    input wire [7:0] job_output_pixels,
    input wire [8:0] job_output_channels,
    input wire signed [255:0] job_bias_vec,
    input wire signed [255:0] job_multiplier_vec,
    input wire [47:0] job_shift_vec,
    input wire signed [31:0] job_output_zero_point_int32,
    input wire signed [31:0] job_activation_min_int32,
    input wire signed [31:0] job_activation_max_int32,

    /* Narrow registered result sink. */
    output wire out_valid,
    input wire out_ready,
    output wire [2:0] out_row_idx,
    output wire [1:0] out_beat_idx,
    output wire [5:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [1:0] out_lane_mask,
    output wire signed [15:0] out_data,

    output reg job_done,
    output wire busy,
    output wire [1:0] scratch_bank0_state,
    output wire [1:0] scratch_bank1_state,
    output wire [15:0] packed_read_count,
    output wire [15:0] activation_accept_count,
    output wire [15:0] activation_stall_count
);
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_ACQUIRE    = 4'd1;
    localparam [3:0] ST_READ_REQ   = 4'd2;
    localparam [3:0] ST_READ_WAIT  = 4'd3;
    localparam [3:0] ST_GROUP_CMD  = 4'd4;
    localparam [3:0] ST_TOKENS     = 4'd5;
    localparam [3:0] ST_DRAIN      = 4'd6;
    localparam [3:0] ST_RELEASE    = 4'd7;

    /* ---------------- paired-half scratch bank ---------------- */
    wire pw_acquire_valid_i, pw_acquire_ready_i;
    wire pw_read_valid_i, pw_read_ready_i;
    wire pw_scratch_out_valid, pw_scratch_out_ready;
    wire [511:0] pw_scratch_out_data;
    wire [63:0] pw_scratch_out_lane_mask;
    wire pw_release_valid_i, pw_release_ready_i;
    reg [GROUP_WIDTH-1:0] pw_read_group_i;
    reg [GROUP_WIDTH-1:0] pw_expected_groups;
    reg pw_bank_reg;
    reg [SESSION_WIDTH-1:0] pw_session_reg;
    reg [EPOCH_WIDTH-1:0] pw_epoch_reg;

    dw_pw_pair_scratch_bank #(
        .SESSION_WIDTH(SESSION_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .GROUP_WIDTH(GROUP_WIDTH), .MAX_GROUPS(MAX_GROUPS)
    ) u_scratch (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_session(dw_acquire_session),
        .dw_acquire_epoch(dw_acquire_epoch), .dw_acquire_group_count(dw_acquire_group_count),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_write_bank), .dw_write_group(dw_write_group),
        .dw_write_half(dw_write_half), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_session(dw_commit_session),
        .dw_commit_epoch(dw_commit_epoch),
        .pw_acquire_valid(pw_acquire_valid_i), .pw_acquire_ready(pw_acquire_ready_i),
        .pw_acquire_bank(pw_bank_reg), .pw_acquire_session(pw_session_reg),
        .pw_acquire_epoch(pw_epoch_reg),
        .pw_read_valid(pw_read_valid_i), .pw_read_ready(pw_read_ready_i),
        .pw_read_bank(pw_bank_reg), .pw_read_group(pw_read_group_i),
        .pw_out_valid(pw_scratch_out_valid), .pw_out_ready(pw_scratch_out_ready),
        .pw_out_data(pw_scratch_out_data), .pw_out_lane_mask(pw_scratch_out_lane_mask),
        .pw_release_valid(pw_release_valid_i), .pw_release_ready(pw_release_ready_i),
        .pw_release_bank(pw_bank_reg),
        .bank0_state(scratch_bank0_state), .bank1_state(scratch_bank1_state),
        .bank0_group_cursor(), .bank1_group_cursor(),
        .bank0_retired_halves(), .bank1_retired_halves(),
        .bank0_retired_groups(), .bank1_retired_groups()
    );

    /* ---------------- packed row-store feeder ---------------- */
    wire feeder_job_ready, feeder_job_done, feeder_busy;
    wire feeder_group_cmd_ready, feeder_act_ready;
    wire feeder_group_cmd_valid, feeder_act_valid;
    wire [4:0] feeder_group_cmd_index = read_count;
    wire [7:0] feeder_act_pixel_mask;
    wire [7:0] feeder_act_cout_mask;
    wire signed [63:0] feeder_act_vec;
    wire feeder_out_valid;
    wire [2:0] feeder_out_row;
    wire [1:0] feeder_out_beat, feeder_out_mask;
    wire [5:0] feeder_out_pixel;
    wire [8:0] feeder_out_cout;
    wire signed [15:0] feeder_out_data;
    wire [1:0] feeder_job_epoch = job_epoch;

    pw_packed_rowstore_feeder #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT),
        .ROWBANK_ACT_REPLICATE(ROWBANK_ACT_REPLICATE)
    ) u_packed_feeder (
        .clk(clk), .rst_n(rst_n),
        .load_begin_valid(pw_load_begin_valid), .load_begin_ready(pw_load_begin_ready),
        .load_epoch(pw_load_epoch), .load_cin(pw_load_cin), .load_cout(pw_load_cout),
        .load_word_valid(pw_load_word_valid), .load_word_ready(pw_load_word_ready),
        .load_word_data(pw_load_word_data), .load_commit_valid(pw_load_commit_valid),
        .load_commit_ready(pw_load_commit_ready), .load_commit_reject(pw_load_commit_reject),
        .load_extra_error(pw_load_extra_error), .load_active(pw_load_active),
        .committed_valid(pw_committed_valid), .committed_epoch(pw_committed_epoch),
        .expected_word_count(pw_expected_word_count), .load_word_count(pw_load_word_count),
        .packed_load_count(pw_packed_load_count),
        .job_valid(job_valid), .job_ready(feeder_job_ready),
        .job_cout_tile(job_cout_tile), .job_epoch(feeder_job_epoch),
        .job_group_count(job_group_count), .job_reverse_groups(job_reverse_groups),
        .job_pixel_base(job_pixel_base), .job_cout_base(job_cout_base),
        .job_output_pixels(job_output_pixels), .job_output_channels(job_output_channels),
        .job_bias_vec(job_bias_vec), .job_multiplier_vec(job_multiplier_vec),
        .job_shift_vec(job_shift_vec),
        .job_output_zero_point_int32(job_output_zero_point_int32),
        .job_activation_min_int32(job_activation_min_int32),
        .job_activation_max_int32(job_activation_max_int32),
        .job_reject_stale(),
        .group_cmd_valid(feeder_group_cmd_valid), .group_cmd_ready(feeder_group_cmd_ready),
        .group_cmd_index(feeder_group_cmd_index),
        .act_valid(feeder_act_valid), .act_ready(feeder_act_ready),
        .act_pixel_mask(feeder_act_pixel_mask), .act_cout_mask(feeder_act_cout_mask),
        .act_vec(feeder_act_vec), .out_ready(out_ready), .out_valid(feeder_out_valid),
        .out_row_idx(feeder_out_row), .out_beat_idx(feeder_out_beat),
        .out_pixel_idx(feeder_out_pixel), .out_channel_base(feeder_out_cout),
        .out_lane_mask(feeder_out_mask), .out_data(feeder_out_data),
        .job_done(feeder_job_done), .busy(feeder_busy),
        .packed_read_count(packed_read_count),
        .activation_accept_count(activation_accept_count),
        .activation_stall_count(activation_stall_count)
    );

    assign out_valid = feeder_out_valid;
    assign out_row_idx = feeder_out_row;
    assign out_beat_idx = feeder_out_beat;
    assign out_pixel_idx = feeder_out_pixel;
    assign out_channel_base = feeder_out_cout;
    assign out_lane_mask = feeder_out_mask;
    assign out_data = feeder_out_data;

    /* ---------------- job/read/token scheduler ---------------- */
    reg [3:0] state;
    reg [GROUP_WIDTH-1:0] read_count;
    reg [3:0] token_idx;
    reg [511:0] response_data;
    reg [63:0] response_lane_mask;
    reg response_valid;
    reg job_reverse_reg;
    reg [5:0] pixel_base_reg;
    reg [8:0] cout_base_reg;
    reg [7:0] output_pixels_reg;
    reg [8:0] output_channels_reg;
    reg signed [255:0] bias_reg, multiplier_reg;
    reg [47:0] shift_reg;
    reg signed [31:0] zp_reg, min_reg, max_reg;

    wire job_count_valid = (job_group_count != {GROUP_WIDTH{1'b0}}) &&
                            (job_group_count <= MAX_GROUPS);
    /* Both engines must accept the same edge: this prevents a scratch bank
     * acquire from becoming orphaned if the packed row store rejects a job. */
    assign job_ready = rst_n && (state == ST_IDLE) && job_count_valid &&
                       feeder_job_ready;
    wire job_fire = job_valid && job_ready;

    wire [GROUP_WIDTH-1:0] current_group = job_reverse_reg ?
        (pw_expected_groups - 1'b1 - read_count) : read_count;
    assign pw_read_group_i = current_group;
    assign pw_acquire_valid_i = (state == ST_ACQUIRE);
    assign pw_read_valid_i = (state == ST_READ_REQ);
    assign pw_scratch_out_ready = (state == ST_READ_WAIT) && !response_valid;
    assign pw_release_valid_i = (state == ST_RELEASE);

    assign feeder_group_cmd_valid = (state == ST_GROUP_CMD);
    assign feeder_act_valid = (state == ST_TOKENS) && response_valid;
    function automatic [7:0] block_mask8;
        input [31:0] total;
        input [31:0] base;
        integer remaining;
        begin
            if (base >= total)
                block_mask8 = 8'd0;
            else begin
                remaining = total - base;
                if (remaining >= 8)
                    block_mask8 = 8'hff;
                else if (remaining <= 0)
                    block_mask8 = 8'd0;
                else
                    block_mask8 = (8'h01 << remaining) - 1'b1;
            end
        end
    endfunction
    assign feeder_act_pixel_mask = block_mask8(output_pixels_reg, pixel_base_reg);
    assign feeder_act_cout_mask = block_mask8(output_channels_reg, cout_base_reg);
    assign feeder_act_vec = feeder_act_vec_comb;
    reg signed [63:0] feeder_act_vec_comb;
    integer ai;
    always @* begin
        feeder_act_vec_comb = 64'sd0;
        for (ai = 0; ai < 8; ai = ai + 1)
            if (response_lane_mask[(ai*8) + token_idx])
                feeder_act_vec_comb[(ai*8) +: 8] =
                    response_data[((ai*8 + token_idx)*8) +: 8];
    end

    assign busy = (state != ST_IDLE) || feeder_busy || response_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            read_count <= 0;
            token_idx <= 0;
            response_data <= 0;
            response_lane_mask <= 0;
            response_valid <= 1'b0;
            pw_bank_reg <= 1'b0;
            pw_session_reg <= 0;
            pw_epoch_reg <= 0;
            pw_expected_groups <= 0;
            job_reverse_reg <= 1'b0;
            pixel_base_reg <= 0;
            cout_base_reg <= 0;
            output_pixels_reg <= 0;
            output_channels_reg <= 0;
            bias_reg <= 0;
            multiplier_reg <= 0;
            shift_reg <= 0;
            zp_reg <= 0; min_reg <= 0; max_reg <= 0;
            job_done <= 1'b0;
        end else begin
            job_done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (job_fire) begin
                        pw_bank_reg <= job_bank;
                        pw_session_reg <= job_session;
                        pw_epoch_reg <= job_epoch;
                        pw_expected_groups <= job_group_count;
                        job_reverse_reg <= job_reverse_groups;
                        pixel_base_reg <= job_pixel_base;
                        cout_base_reg <= job_cout_base;
                        output_pixels_reg <= job_output_pixels;
                        output_channels_reg <= job_output_channels;
                        bias_reg <= job_bias_vec;
                        multiplier_reg <= job_multiplier_vec;
                        shift_reg <= job_shift_vec;
                        zp_reg <= job_output_zero_point_int32;
                        min_reg <= job_activation_min_int32;
                        max_reg <= job_activation_max_int32;
                        read_count <= 0;
                        token_idx <= 0;
                        response_valid <= 1'b0;
                        state <= ST_ACQUIRE;
                    end
                end
                ST_ACQUIRE: begin
                    if (pw_acquire_valid_i && pw_acquire_ready_i)
                        state <= ST_READ_REQ;
                end
                ST_READ_REQ: begin
                    if (pw_read_valid_i && pw_read_ready_i)
                        state <= ST_READ_WAIT;
                end
                ST_READ_WAIT: begin
                    if (pw_scratch_out_valid && pw_scratch_out_ready) begin
                        response_data <= pw_scratch_out_data;
                        response_lane_mask <= pw_scratch_out_lane_mask;
                        response_valid <= 1'b1;
                        token_idx <= 0;
                        state <= ST_GROUP_CMD;
                    end
                end
                ST_GROUP_CMD: begin
                    if (feeder_group_cmd_valid && feeder_group_cmd_ready)
                        state <= ST_TOKENS;
                end
                ST_TOKENS: begin
                    if (feeder_act_valid && feeder_act_ready) begin
                        if (token_idx == 4'd7) begin
                            response_valid <= 1'b0;
                            token_idx <= 0;
                            if (read_count == (pw_expected_groups - 1'b1)) begin
                                state <= ST_DRAIN;
                            end else begin
                                read_count <= read_count + 1'b1;
                                state <= ST_READ_REQ;
                            end
                        end else begin
                            token_idx <= token_idx + 1'b1;
                        end
                    end
                end
                ST_DRAIN: begin
                    /* feeder_job_done is generated only after its registered
                     * output sink accepts the final row beat. */
                    if (feeder_job_done)
                        state <= ST_RELEASE;
                end
                ST_RELEASE: begin
                    if (pw_release_valid_i && pw_release_ready_i) begin
                        job_done <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
