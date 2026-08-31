`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production consumer island for the paired-half DW scratch bank.
 *
 * The scratch bank is deliberately kept at its narrow ownership boundary:
 * DW writes and commit carry the session/epoch, while the PW side acquires a
 * committed bank, reads one complete 8x8 group at a time, and only then
 * presents eight K tokens to the output-stationary row-bank PW core.  A
 * registered response copy separates BRAM read latency from the 64-DSP
 * input cone.  The row-bank output is passed through a one-entry registered
 * narrow sink; scratch release is withheld until that sink has drained.
 *
 * This module is an isolated proof vehicle.  It intentionally has no
 * connection to the layer runner or the production DS path.
 */
module dw_pw_pair_scratch_rowbank2_consumer #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 16,
    parameter integer MAX_GROUPS = 16,
    parameter integer SESSION_WIDTH = 2,
    parameter integer EPOCH_WIDTH = 2,
    parameter integer GROUP_WIDTH = 5
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

    /* PW weights are loaded in output-channel-major, K-minor order. */
    input wire pw_weight_wr_en,
    input wire [15:0] pw_weight_wr_idx,
    input wire signed [7:0] pw_weight_wr_data,

    /* One PW job consumes one committed scratch bank. */
    input wire job_valid,
    output wire job_ready,
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
    output wire [1:0] scratch_bank1_state
);
    localparam integer WEIGHT_COUNT = MAX_CIN * MAX_COUT;
    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_ACQUIRE    = 3'd1;
    localparam [2:0] ST_READ_REQ   = 3'd2;
    localparam [2:0] ST_READ_WAIT  = 3'd3;
    localparam [2:0] ST_TOKENS     = 3'd4;
    localparam [2:0] ST_DRAIN      = 3'd5;
    localparam [2:0] ST_RELEASE    = 3'd6;

    /* ---------------- paired-half scratch bank ---------------- */
    wire pw_acquire_valid_i;
    wire pw_acquire_ready_i;
    wire pw_read_valid_i;
    wire pw_read_ready_i;
    wire pw_scratch_out_valid;
    wire pw_scratch_out_ready;
    wire [511:0] pw_scratch_out_data;
    wire [63:0] pw_scratch_out_lane_mask;
    wire pw_release_valid_i;
    wire pw_release_ready_i;
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

    /* Weight RAM is intentionally local to this consumer island. */
    reg signed [7:0] pw_weight_mem [0:WEIGHT_COUNT-1];

    /* ---------------- job and response registers ---------------- */
    reg [2:0] state;
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
    reg signed [255:0] bias_reg;
    reg signed [255:0] multiplier_reg;
    reg [47:0] shift_reg;
    reg signed [31:0] zp_reg, min_reg, max_reg;

    wire job_count_valid = (job_group_count != {GROUP_WIDTH{1'b0}}) &&
                            (job_group_count <= MAX_GROUPS);
    assign job_ready = rst_n && (state == ST_IDLE) && job_count_valid;
    wire job_fire = job_valid && job_ready;

    wire [GROUP_WIDTH-1:0] current_group = job_reverse_reg ?
        (pw_expected_groups - 1'b1 - read_count) : read_count;
    assign pw_read_group_i = current_group;
    assign pw_acquire_valid_i = (state == ST_ACQUIRE);
    assign pw_read_valid_i = (state == ST_READ_REQ);
    assign pw_scratch_out_ready = (state == ST_READ_WAIT) && !response_valid;
    assign pw_release_valid_i = (state == ST_RELEASE);

    /* ---------------- row-bank PW token adapter ---------------- */
    wire core_ready_in;
    wire core_valid_out;
    wire core_busy;
    wire [2:0] core_row;
    wire [1:0] core_beat;
    wire [5:0] core_pixel;
    wire [8:0] core_cout;
    wire [1:0] core_mask;
    wire signed [15:0] core_data;
    reg signed [63:0] core_act_vec;
    reg signed [63:0] core_wgt_vec;
    reg [7:0] core_pixel_mask;
    reg [7:0] core_cout_mask;
    reg core_first_k, core_last_k;
    reg [7:0] core_k_idx;
    wire sink_in_ready;

    function automatic [7:0] block_mask8;
        input integer total;
        input integer base;
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

    wire [7:0] job_pixel_mask = block_mask8(output_pixels_reg,
                                             pixel_base_reg);
    wire [7:0] job_cout_mask = block_mask8(output_channels_reg,
                                            cout_base_reg);
    wire core_valid_in = (state == ST_TOKENS) && response_valid;
    wire core_fire = core_valid_in && core_ready_in;

    integer ai;
    integer wi;
    integer weight_addr;
    always @* begin
        core_act_vec = 64'sd0;
        for (ai = 0; ai < 8; ai = ai + 1) begin
            /* The scratch lane mask suppresses DW tail/padding channels. */
            if (response_lane_mask[(ai*8) + token_idx])
                core_act_vec[(ai*8) +: 8] =
                    response_data[((ai*8 + token_idx)*8) +: 8];
        end
        core_wgt_vec = 64'sd0;
        for (wi = 0; wi < 8; wi = wi + 1) begin
            weight_addr = ((cout_base_reg + wi) * MAX_CIN) +
                          (current_group * 8) + token_idx;
            if ((cout_base_reg + wi) < MAX_COUT &&
                weight_addr >= 0 && weight_addr < WEIGHT_COUNT)
                core_wgt_vec[(wi*8) +: 8] = pw_weight_mem[weight_addr];
        end
        core_pixel_mask = job_pixel_mask;
        core_cout_mask = job_cout_mask;
        core_first_k = (read_count == 0) && (token_idx == 0);
        core_last_k = (read_count == (pw_expected_groups - 1'b1)) &&
                      (token_idx == 4'd7);
        core_k_idx = (current_group * 8) + token_idx;
    end

    pw_direct_8x8_dsp_rowbank u_pw_core (
        .clk(clk), .rst_n(rst_n), .valid_in(core_valid_in),
        .ready_in(core_ready_in), .first_k(core_first_k), .last_k(core_last_k),
        .k_idx(core_k_idx), .pixel_mask(core_pixel_mask),
        .cout_mask(core_cout_mask), .act_vec(core_act_vec),
        .wgt_vec(core_wgt_vec), .pixel_base(pixel_base_reg),
        .cout_base(cout_base_reg), .output_pixels(output_pixels_reg),
        .output_channels(output_channels_reg), .bias_vec(bias_reg),
        .multiplier_vec(multiplier_reg), .shift_vec(shift_reg),
        .output_zero_point_int32(zp_reg), .activation_min_int32(min_reg),
        .activation_max_int32(max_reg), .ready_out(sink_in_ready),
        .valid_out(core_valid_out), .out_row_idx(core_row),
        .out_beat_idx(core_beat), .out_pixel_idx(core_pixel),
        .out_channel_base(core_cout), .out_lane_mask(core_mask),
        .out_data(core_data), .busy(core_busy)
    );

    /* Registered narrow sink.  Its input ready is independent of the wide
     * scratch response, and its output record remains stable while stalled. */
    reg sink_valid;
    reg [2:0] sink_row;
    reg [1:0] sink_beat;
    reg [5:0] sink_pixel;
    reg [8:0] sink_cout;
    reg [1:0] sink_mask;
    reg signed [15:0] sink_data;
    assign sink_in_ready = !sink_valid || out_ready;
    wire sink_in_fire = core_valid_out && sink_in_ready;
    assign out_valid = sink_valid;
    assign out_row_idx = sink_row;
    assign out_beat_idx = sink_beat;
    assign out_pixel_idx = sink_pixel;
    assign out_channel_base = sink_cout;
    assign out_lane_mask = sink_mask;
    assign out_data = sink_data;
    wire sink_out_fire = sink_valid && out_ready;

    assign busy = (state != ST_IDLE) || response_valid || core_busy || sink_valid;

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
            sink_valid <= 1'b0;
            sink_row <= 0; sink_beat <= 0; sink_pixel <= 0;
            sink_cout <= 0; sink_mask <= 0; sink_data <= 0;
        end else begin
            job_done <= 1'b0;

            if (pw_weight_wr_en && (pw_weight_wr_idx < WEIGHT_COUNT))
                pw_weight_mem[pw_weight_wr_idx] <= pw_weight_wr_data;

            if (sink_in_fire) begin
                sink_valid <= 1'b1;
                sink_row <= core_row;
                sink_beat <= core_beat;
                sink_pixel <= core_pixel;
                sink_cout <= core_cout;
                sink_mask <= core_mask;
                sink_data <= core_data;
            end else if (sink_out_fire) begin
                sink_valid <= 1'b0;
            end

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
                        state <= ST_TOKENS;
                    end
                end
                ST_TOKENS: begin
                    if (core_fire) begin
                        if (token_idx == 4'd7) begin
                            response_valid <= 1'b0;
                            if (read_count == (pw_expected_groups - 1'b1)) begin
                                state <= ST_DRAIN;
                            end else begin
                                read_count <= read_count + 1'b1;
                                state <= ST_READ_REQ;
                            end
                            token_idx <= 0;
                        end else begin
                            token_idx <= token_idx + 1'b1;
                        end
                    end
                end
                ST_DRAIN: begin
                    /* The row-bank frees its internal result bank only when
                     * its final narrow transfer is accepted by this sink. */
                    if (!core_busy && !sink_valid)
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
