`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production end-to-end spatial tile pipeline.
 *
 * The word-window DW producer and the PW consumer communicate only through
 * two independently owned 8x8 scratch banks.  A DW group is acquired with a
 * {bank,epoch,tile} descriptor, writes its 64 pixels, and the bank's local
 * completion fence is the only event that makes it readable.  PW then reads
 * one channel and eight pixels at a time, retaining the full K reduction in
 * the registered direct 8x8 core.  The two state machines are independent,
 * so a producer command for the opposite bank may run while PW drains the
 * active bank.
 *
 * This is an integration/profiling helper.  It intentionally does not alter
 * cnn_layer_runner or any production top-level ABI.
 */
module ds_word_window_dw_pw_tile_pipeline #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 8
) (
    input wire clk, input wire rst_n,

    /* Source-word fill ABI of ds_word_window_dw_producer_island. */
    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank,
    output wire [EPOCH_WIDTH-1:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,

    /* DW parameter bus and one channel-group compute descriptor. */
    input wire cfg_valid, output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    input wire dw_job_valid, output wire dw_job_ready,
    input wire dw_source_bank,
    input wire [EPOCH_WIDTH-1:0] dw_source_epoch,
    input wire [ADDR_WIDTH-1:0] dw_source_base_addr,
    input wire [15:0] dw_source_lane_mask,
    input wire [1:0] dw_source_stride,
    input wire [7:0] dw_footprint_height,
    input wire [7:0] dw_footprint_width,
    input wire [7:0] dw_footprint_pitch,
    input wire dw_target_bank,
    input wire [EPOCH_WIDTH-1:0] dw_target_epoch,
    input wire [TILE_WIDTH-1:0] dw_target_tile,
    input wire [2:0] dw_channel_group,
    input wire [3:0] dw_group_count,
    input wire [7:0] dw_pixel_count,
    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,
    output reg dw_done_valid, input wire dw_done_ready,
    output reg dw_done_bank,
    output reg [EPOCH_WIDTH-1:0] dw_done_epoch,
    output reg [TILE_WIDTH-1:0] dw_done_tile,
    output reg [2:0] dw_done_group,

    /* PW parameter memories and one complete output-tile descriptor. */
    input wire pw_weight_wr_en, input wire [15:0] pw_weight_wr_idx,
    input wire signed [7:0] pw_weight_wr_data,
    input wire pw_bias_wr_en, input wire [8:0] pw_bias_wr_idx,
    input wire signed [31:0] pw_bias_wr_data,
    input wire pw_multiplier_wr_en, input wire [8:0] pw_multiplier_wr_idx,
    input wire signed [31:0] pw_multiplier_wr_data,
    input wire pw_shift_wr_en, input wire [8:0] pw_shift_wr_idx,
    input wire [5:0] pw_shift_wr_data,
    input wire pw_job_valid, output wire pw_job_ready,
    input wire pw_bank, input wire [EPOCH_WIDTH-1:0] pw_epoch,
    input wire [TILE_WIDTH-1:0] pw_tile,
    input wire [7:0] pw_input_channels,
    input wire [8:0] pw_output_channels,
    input wire [7:0] pw_pixel_count,
    input wire [31:0] pw_output_zero_point,
    input wire [31:0] pw_activation_min,
    input wire [31:0] pw_activation_max,
    output reg pw_done_valid, input wire pw_done_ready,
    output reg pw_done_bank,
    output reg [EPOCH_WIDTH-1:0] pw_done_epoch,
    output reg [TILE_WIDTH-1:0] pw_done_tile,
    output wire pw_out_valid, input wire pw_out_ready,
    output wire [7:0] pw_out_pixel_idx,
    output wire [8:0] pw_out_channel_idx,
    output wire signed [7:0] pw_out_data,

    output wire [1:0] scratch0_state,
    output wire [1:0] scratch1_state,
    output reg [31:0] dw_write_count,
    output reg [31:0] dw_overlap_cycles,
    output reg [31:0] pw_read_count,
    output reg [31:0] pw_issue_count
);
    /* The established word-window source shell has three physical group
     * slots.  A caller may issue the same tile descriptor repeatedly for
     * larger Cin values; the scratch bank still retains up to eight groups. */
    localparam integer VAW = (MAX_IN_H*MAX_IN_W*3 > 1) ?
                             $clog2(MAX_IN_H*MAX_IN_W*3) : 1;

    /* ------------------------ DW producer ------------------------- */
    wire dw_compute_start_valid, dw_compute_start_ready;
    wire dw_compute_done_valid, dw_compute_done_ready;
    reg dw_compute_done_ready_reg;
    wire dw_compute_busy;
    wire dw_out_valid;
    wire [7:0] dw_out_pixel;
    wire [15:0] dw_out_mask;
    wire signed [511:0] dw_out_raw;
    wire signed [511:0] dw_out_bias;
    wire signed [511:0] dw_out_multiplier;
    wire [95:0] dw_out_shift;
    reg [15:0] dw_lane_mask_reg;
    reg [1:0] dw_stride_reg;
    reg [7:0] dw_fh_reg, dw_fw_reg, dw_pitch_reg;
    reg dw_source_bank_reg;
    reg [EPOCH_WIDTH-1:0] dw_source_epoch_reg;
    reg [ADDR_WIDTH-1:0] dw_source_base_reg;
    reg [31:0] dw_zp_reg, dw_min_reg, dw_max_reg;
    reg [7:0] dw_pixel_count_reg;
    reg dw_target_bank_reg;
    reg [EPOCH_WIDTH-1:0] dw_target_epoch_reg;
    reg [TILE_WIDTH-1:0] dw_target_tile_reg;
    reg [2:0] dw_group_reg;
    reg [3:0] dw_group_count_reg;
    reg [2:0] dw_state;
    localparam DW_IDLE=3'd0, DW_ACQ=3'd1, DW_START=3'd2,
               DW_WAIT=3'd3, DW_DRAIN=3'd4, DW_COMMIT=3'd5;

    assign dw_job_ready = rst_n && (dw_state == DW_IDLE) &&
                          !dw_done_valid;
    assign dw_compute_start_valid = (dw_state == DW_START);
    assign dw_compute_done_ready = dw_compute_done_ready_reg;

    ds_word_window_dw_producer_island #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .MAX_CHANNEL_GROUPS(3), .LAYOUT_GROUPS(1),
        .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .VECTOR_ADDR_WIDTH(VAW), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TAG_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dw (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count), .fill_done_valid(fill_done_valid),
        .fill_done_ready(fill_done_ready), .fill_done_bank(fill_done_bank),
        .fill_done_epoch(fill_done_epoch), .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .compute_start_valid(dw_compute_start_valid),
        .compute_start_ready(dw_compute_start_ready),
        .compute_bank(dw_source_bank_reg), .compute_epoch(dw_source_epoch_reg),
        .compute_lane_mask(dw_lane_mask_reg), .compute_stride(dw_stride_reg),
        .compute_footprint_height(dw_fh_reg), .compute_footprint_width(dw_fw_reg),
        .compute_pitch(dw_pitch_reg), .compute_done_valid(dw_compute_done_valid),
        .compute_done_ready(dw_compute_done_ready), .compute_done_bank(),
        .compute_done_epoch(), .compute_busy(dw_compute_busy),
        .valid_out(dw_out_valid), .ready_out(dw_sink_ready),
        .out_pixel_idx(dw_out_pixel), .out_lane_mask(dw_out_mask),
        .out_raw_vec(dw_out_raw), .out_bias_vec(dw_out_bias),
        .out_multiplier_vec(dw_out_multiplier), .out_shift_vec(dw_out_shift),
        .bank0_state(), .bank1_state(), .fill_busy(), .read_busy(),
        .fill_word_count_seen(), .read_vector_count(), .token_count(),
        .overlap_cycles(), .stale_command_count()
    );

    wire dw_sink_valid, dw_sink_ready;
    wire [5:0] dw_sink_pixel;
    wire [15:0] dw_sink_mask;
    wire [127:0] dw_sink_data;
    ds_dw_requant_write_sink u_dw_sink (
        .clk(clk), .rst_n(rst_n), .valid_in(dw_out_valid),
        .ready_in(dw_sink_ready), .pixel_idx_in(dw_out_pixel[5:0]),
        .lane_mask_in(dw_out_mask), .raw_vec_in(dw_out_raw),
        .multiplier_vec_in(dw_out_multiplier), .shift_vec_in(dw_out_shift),
        .output_zero_point(dw_zp_reg), .activation_min(dw_min_reg),
        .activation_max(dw_max_reg), .valid_out(dw_sink_valid),
        .ready_out(dw_write_ready), .pixel_idx_out(dw_sink_pixel),
        .lane_mask_out(dw_sink_mask), .data_out(dw_sink_data)
    );
    wire dw_acquire_valid = (dw_state == DW_ACQ);
    wire dw_acquire_ready;
    wire dw_write_valid = dw_sink_valid;
    wire dw_write_ready;
    wire dw_commit_valid = (dw_state == DW_COMMIT);
    wire dw_commit_ready;
    wire pw_acquire_valid, pw_acquire_ready;
    wire pw_read_valid, pw_read_ready;
    wire pw_buf_valid, pw_buf_ready;
    wire [63:0] pw_buf_data;
    wire [7:0] pw_buf_mask;
    wire [1:0] buf0_state, buf1_state;
    wire [EPOCH_WIDTH-1:0] unused_epoch0, unused_epoch1;
    wire [TILE_WIDTH-1:0] unused_tile0, unused_tile1;
    wire pw_release_valid, pw_release_ready;
    wire [1:0] scratch0_state_i, scratch1_state_i;

    ds_pw_spatial_tile_bank u_scratch0 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && !dw_target_bank_reg),
        .dw_acquire_ready(acq0_ready), .dw_acquire_bank(1'b0),
        .dw_acquire_epoch(dw_target_epoch_reg), .dw_acquire_tile(dw_target_tile_reg),
        .dw_acquire_pixel_mask(dw_pixel_mask), .dw_acquire_group_mask(dw_group_mask),
        .dw_write_valid(dw_write_valid && !dw_target_bank_reg),
        .dw_write_ready(wr0_ready), .dw_write_bank(1'b0),
        .dw_write_epoch(dw_target_epoch_reg), .dw_write_tile(dw_target_tile_reg),
        .dw_write_pixel_idx(dw_sink_pixel), .dw_write_group(dw_group_reg),
        .dw_write_data(dw_sink_data), .dw_write_lane_mask(dw_sink_mask),
        .dw_commit_valid(dw_commit_valid && !dw_target_bank_reg),
        .dw_commit_ready(cm0_ready), .dw_commit_bank(1'b0),
        .dw_commit_epoch(dw_target_epoch_reg), .dw_commit_tile(dw_target_tile_reg),
        .pw_acquire_valid(pw_acquire_valid && !pw_bank_reg),
        .pw_acquire_ready(pa0_ready), .pw_acquire_bank(1'b0),
        .pw_acquire_epoch(pw_epoch_reg), .pw_acquire_tile(pw_tile_reg),
        .pw_read_valid(pw_read_valid && !pw_bank_reg), .pw_read_ready(pr0_ready),
        .pw_read_bank(1'b0), .pw_read_epoch(pw_epoch_reg), .pw_read_tile(pw_tile_reg),
        .pw_read_channel_idx(pw_read_idx), .pw_read_pixel_base(pw_read_pixel_base),
        .pw_out_valid(pv0_valid), .pw_out_ready(pw_buf_ready && !pv1_valid),
        .pw_out_bank(), .pw_out_epoch(), .pw_out_tile(), .pw_out_data(pv0_data),
        .pw_out_lane_mask(pv0_mask), .pw_release_valid(pw_release_valid && !pw_bank_reg),
        .pw_release_ready(prl0_ready), .pw_release_bank(1'b0),
        .pw_release_epoch(pw_epoch_reg), .pw_release_tile(pw_tile_reg),
        .state(scratch0_state_i), .state_epoch(unused_epoch0), .state_tile(unused_tile0),
        .commit_pulse(), .acquire_pulse(), .release_pulse(), .read_count(), .write_count()
    );
    ds_pw_spatial_tile_bank u_scratch1 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && dw_target_bank_reg),
        .dw_acquire_ready(acq1_ready), .dw_acquire_bank(1'b1),
        .dw_acquire_epoch(dw_target_epoch_reg), .dw_acquire_tile(dw_target_tile_reg),
        .dw_acquire_pixel_mask(dw_pixel_mask), .dw_acquire_group_mask(dw_group_mask),
        .dw_write_valid(dw_write_valid && dw_target_bank_reg),
        .dw_write_ready(wr1_ready), .dw_write_bank(1'b1),
        .dw_write_epoch(dw_target_epoch_reg), .dw_write_tile(dw_target_tile_reg),
        .dw_write_pixel_idx(dw_sink_pixel), .dw_write_group(dw_group_reg),
        .dw_write_data(dw_sink_data), .dw_write_lane_mask(dw_sink_mask),
        .dw_commit_valid(dw_commit_valid && dw_target_bank_reg),
        .dw_commit_ready(cm1_ready), .dw_commit_bank(1'b1),
        .dw_commit_epoch(dw_target_epoch_reg), .dw_commit_tile(dw_target_tile_reg),
        .pw_acquire_valid(pw_acquire_valid && pw_bank_reg),
        .pw_acquire_ready(pa1_ready), .pw_acquire_bank(1'b1),
        .pw_acquire_epoch(pw_epoch_reg), .pw_acquire_tile(pw_tile_reg),
        .pw_read_valid(pw_read_valid && pw_bank_reg), .pw_read_ready(pr1_ready),
        .pw_read_bank(1'b1), .pw_read_epoch(pw_epoch_reg), .pw_read_tile(pw_tile_reg),
        .pw_read_channel_idx(pw_read_idx), .pw_read_pixel_base(pw_read_pixel_base),
        .pw_out_valid(pv1_valid), .pw_out_ready(pw_buf_ready && !pv0_valid),
        .pw_out_bank(), .pw_out_epoch(), .pw_out_tile(), .pw_out_data(pv1_data),
        .pw_out_lane_mask(pv1_mask), .pw_release_valid(pw_release_valid && pw_bank_reg),
        .pw_release_ready(prl1_ready), .pw_release_bank(1'b1),
        .pw_release_epoch(pw_epoch_reg), .pw_release_tile(pw_tile_reg),
        .state(scratch1_state_i), .state_epoch(unused_epoch1), .state_tile(unused_tile1),
        .commit_pulse(), .acquire_pulse(), .release_pulse(), .read_count(), .write_count()
    );
    assign scratch0_state = scratch0_state_i; assign scratch1_state = scratch1_state_i;
    wire acq0_ready, acq1_ready, wr0_ready, wr1_ready, cm0_ready, cm1_ready;
    wire pa0_ready, pa1_ready, pr0_ready, pr1_ready, prl0_ready, prl1_ready;
    wire pv0_valid, pv1_valid; wire [63:0] pv0_data, pv1_data;
    wire [7:0] pv0_mask, pv1_mask;
    wire [63:0] dw_pixel_mask = (dw_pixel_count_reg >= 64) ? 64'hffff_ffff_ffff_ffff :
        ((dw_pixel_count_reg == 0) ? 64'd0 : ((64'h1 << dw_pixel_count_reg) - 1));
    wire [7:0] dw_group_mask = (dw_group_count_reg >= 8) ? 8'hff :
        ((dw_group_count_reg == 0) ? 8'd0 : ((8'h1 << dw_group_count_reg) - 1));
    assign dw_acquire_ready = dw_target_bank_reg ? acq1_ready : acq0_ready;
    assign dw_write_ready = dw_target_bank_reg ? wr1_ready : wr0_ready;
    assign dw_commit_ready = dw_target_bank_reg ? cm1_ready : cm0_ready;
    assign pw_acquire_ready = pw_bank_reg ? pa1_ready : pa0_ready;
    assign pw_buf_valid = pv0_valid | pv1_valid;
    assign pw_buf_data = pv1_valid ? pv1_data : pv0_data;
    assign pw_buf_mask = pv1_valid ? pv1_mask : pv0_mask;
    /* The bank's per-instance read ready is the one that matters; only one
     * bank is selected by the registered PW descriptor. */
    assign pw_read_ready = pw_bank_reg ? pr1_ready : pr0_ready;
    assign pw_release_ready = pw_bank_reg ? prl1_ready : prl0_ready;

    /* ------------------------- PW consumer ------------------------- */
    reg pw_bank_reg; reg [EPOCH_WIDTH-1:0] pw_epoch_reg;
    reg [TILE_WIDTH-1:0] pw_tile_reg;
    reg [7:0] pw_cin_reg; reg [8:0] pw_cout_reg; reg [7:0] pw_pixels_reg;
    reg [31:0] pw_zp_reg, pw_min_reg, pw_max_reg;
    reg [2:0] pw_row_reg; reg [6:0] pw_read_idx; reg [5:0] pw_pixel_base;
    wire [5:0] pw_read_pixel_base = pw_pixel_base;
    reg pw_read_inflight, pw_reads_done;
    reg [5:0] pw_cout_group; reg [3:0] pw_state;
    localparam PW_IDLE=4'd0, PW_ACQ=4'd1, PW_READ=4'd2,
               PW_WAIT_CORE=4'd3, PW_RQ=4'd4, PW_RELEASE=4'd5;
    reg signed [7:0] pw_weight_mem [0:MAX_CIN*MAX_COUT-1];
    reg signed [31:0] pw_bias_mem [0:MAX_COUT-1];
    reg signed [31:0] pw_multiplier_mem [0:MAX_COUT-1];
    reg [5:0] pw_shift_mem [0:MAX_COUT-1];
    integer cfg_i;
    always @(posedge clk) begin
        if (pw_weight_wr_en && (pw_weight_wr_idx < MAX_CIN*MAX_COUT))
            pw_weight_mem[pw_weight_wr_idx] <= pw_weight_wr_data;
        if (pw_bias_wr_en && (pw_bias_wr_idx < MAX_COUT))
            pw_bias_mem[pw_bias_wr_idx] <= pw_bias_wr_data;
        if (pw_multiplier_wr_en && (pw_multiplier_wr_idx < MAX_COUT))
            pw_multiplier_mem[pw_multiplier_wr_idx] <= pw_multiplier_wr_data;
        if (pw_shift_wr_en && (pw_shift_wr_idx < MAX_COUT))
            pw_shift_mem[pw_shift_wr_idx] <= pw_shift_wr_data;
    end
    assign pw_job_ready = rst_n && (pw_state == PW_IDLE) && !pw_done_valid;
    assign pw_acquire_valid = (pw_state == PW_ACQ);
    assign pw_read_valid = (pw_state == PW_READ) && !pw_read_inflight && !pw_reads_done;
    assign pw_release_valid = (pw_state == PW_RELEASE);
    assign pw_buf_ready = (pw_state == PW_READ) && pw_core_ready;
    wire pw_core_valid = pw_buf_valid && pw_buf_ready;
    wire pw_core_ready;
    wire pw_core_out_valid; wire signed [2047:0] pw_core_psum;
    wire [63:0] pw_core_lane_mask;
    reg signed [63:0] pw_weight_vec;
    integer wi, wo;
    always @* begin
        pw_weight_vec = 64'sd0;
        for (wi = 0; wi < 8; wi = wi + 1) begin
            wo = pw_cout_group*8 + wi;
            if ((wo < MAX_COUT) && (pw_read_idx < MAX_CIN))
                pw_weight_vec[(wi*8) +: 8] = pw_weight_mem[wo*MAX_CIN + pw_read_idx];
        end
    end
    wire [7:0] pw_pixel_mask8 = (pw_pixels_reg - (pw_row_reg*8) >= 8) ? 8'hff :
        ((pw_pixels_reg <= pw_row_reg*8) ? 8'd0 :
         ((8'h1 << (pw_pixels_reg - pw_row_reg*8)) - 1));
    wire [7:0] pw_cout_mask8 = (pw_cout_reg - pw_cout_group*8 >= 8) ? 8'hff :
        ((pw_cout_reg <= pw_cout_group*8) ? 8'd0 :
         ((8'h1 << (pw_cout_reg - pw_cout_group*8)) - 1));
    pw_direct_8x8_dsp u_pw (
        .clk(clk), .rst_n(rst_n), .valid_in(pw_core_valid), .ready_in(pw_core_ready),
        .first_k(pw_read_idx == 0), .last_k(pw_read_idx + 1 >= pw_cin_reg),
        .k_idx(pw_read_idx), .pixel_mask(pw_pixel_mask8),
        .cout_mask(pw_cout_mask8), .act_vec(pw_buf_data), .wgt_vec(pw_weight_vec),
        .ready_out(1'b1), .valid_out(pw_core_out_valid), .psum_out(pw_core_psum),
        .lane_mask_out(pw_core_lane_mask)
    );

    reg signed [255:0] rq_bias_vec, rq_multiplier_vec;
    reg [47:0] rq_shift_vec;
    integer rqi;
    always @* begin
        rq_bias_vec = 256'sd0; rq_multiplier_vec = 256'sd0; rq_shift_vec = 48'd0;
        for (rqi = 0; rqi < 8; rqi = rqi + 1) begin
            if (pw_cout_group*8+rqi < MAX_COUT) begin
                rq_bias_vec[rqi*32 +: 32] = pw_bias_mem[pw_cout_group*8+rqi];
                rq_multiplier_vec[rqi*32 +: 32] = pw_multiplier_mem[pw_cout_group*8+rqi];
                rq_shift_vec[rqi*6 +: 6] = pw_shift_mem[pw_cout_group*8+rqi];
            end
        end
    end
    wire rq_in_ready; wire [3:0] rq_valid; reg [3:0] rq_ready;
    wire [23:0] rq_pixels; wire [31:0] rq_channels; wire signed [31:0] rq_data;
    wire rq_busy;
    requant_activation_vector4_spatial u_pw_rq (
        .clk(clk), .rst_n(rst_n), .valid_in((pw_state == PW_WAIT_CORE) && pw_core_out_valid),
        .ready_in(rq_in_ready), .psum_in(pw_core_psum),
        .pixel_base(pw_row_reg*8), .cout_base(pw_cout_group*8),
        /* pixel_base is the absolute tile-row offset, so the valid range
         * must be the full tile extent rather than the local eight-pixel
         * row width.  pw_pixel_mask8 still masks the local row lanes. */
        .output_pixels(pw_pixels_reg), .output_channels(pw_cout_reg), .bias_vec(rq_bias_vec),
        .multiplier_vec(rq_multiplier_vec), .shift_vec(rq_shift_vec),
        .output_zero_point_int32(pw_zp_reg), .activation_min_int32(pw_min_reg),
        .activation_max_int32(pw_max_reg), .valid_out(rq_valid), .ready_out(rq_ready),
        .out_pixel_idx_vec(rq_pixels), .out_channel_idx_vec(rq_channels),
        .out_data_int8_vec(rq_data), .busy(rq_busy)
    );
    reg [1:0] rq_sel;
    integer rs;
    always @* begin
        rq_sel = 0;
        if (rq_valid[0]) rq_sel=0; else if (rq_valid[1]) rq_sel=1;
        else if (rq_valid[2]) rq_sel=2; else rq_sel=3;
        rq_ready = 0;
        if (pw_out_ready && (|rq_valid)) rq_ready[rq_sel] = 1'b1;
    end
    assign pw_out_valid = |rq_valid;
    assign pw_out_pixel_idx = rq_pixels[rq_sel*6 +: 6];
    assign pw_out_channel_idx = rq_channels[rq_sel*8 +: 8];
    assign pw_out_data = rq_data[rq_sel*8 +: 8];

    /* ---------------------------- control -------------------------- */
    wire dw_write_fire = dw_write_valid && dw_write_ready;
    wire dw_sink_fire = dw_sink_valid && dw_write_ready;
    wire pw_read_fire = pw_read_valid && pw_read_ready;
    wire pw_buf_fire = pw_buf_valid && pw_buf_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            dw_state<=DW_IDLE; dw_done_valid<=0; dw_done_bank<=0;
            dw_done_epoch<=0; dw_done_tile<=0; dw_done_group<=0;
            dw_compute_done_ready_reg<=1; dw_write_count<=0; dw_overlap_cycles<=0;
            dw_source_bank_reg<=0; dw_source_epoch_reg<=0; dw_source_base_reg<=0;
            dw_lane_mask_reg<=0; dw_stride_reg<=1; dw_fh_reg<=0; dw_fw_reg<=0;
            dw_pitch_reg<=0; dw_zp_reg<=0; dw_min_reg<=0; dw_max_reg<=0;
            dw_pixel_count_reg<=0; dw_target_bank_reg<=0; dw_target_epoch_reg<=0;
            dw_target_tile_reg<=0; dw_group_reg<=0; dw_group_count_reg<=0;
            pw_state<=PW_IDLE; pw_done_valid<=0; pw_done_bank<=0; pw_done_epoch<=0;
            pw_done_tile<=0; pw_bank_reg<=0; pw_epoch_reg<=0; pw_tile_reg<=0;
            pw_cin_reg<=0; pw_cout_reg<=0; pw_pixels_reg<=0; pw_zp_reg<=0;
            pw_min_reg<=0; pw_max_reg<=0; pw_row_reg<=0; pw_read_idx<=0;
            pw_pixel_base<=0; pw_read_inflight<=0; pw_reads_done<=0; pw_cout_group<=0;
            pw_read_count<=0; pw_issue_count<=0;
        end else begin
            if (dw_done_valid && dw_done_ready) dw_done_valid<=0;
            if (pw_done_valid && pw_done_ready) pw_done_valid<=0;
            if (dw_job_valid && dw_job_ready) begin
                dw_source_bank_reg<=dw_source_bank; dw_source_epoch_reg<=dw_source_epoch;
                dw_source_base_reg<=dw_source_base_addr; dw_lane_mask_reg<=dw_source_lane_mask;
                dw_stride_reg<=(dw_source_stride==0)?1:dw_source_stride;
                dw_fh_reg<=dw_footprint_height; dw_fw_reg<=dw_footprint_width;
                dw_pitch_reg<=dw_footprint_pitch; dw_zp_reg<=dw_output_zero_point;
                dw_min_reg<=dw_activation_min; dw_max_reg<=dw_activation_max;
                dw_pixel_count_reg<=dw_pixel_count; dw_target_bank_reg<=dw_target_bank;
                dw_target_epoch_reg<=dw_target_epoch; dw_target_tile_reg<=dw_target_tile;
                dw_group_reg<=dw_channel_group; dw_group_count_reg<=dw_group_count;
                dw_write_count<=0;
                dw_state <= (dw_channel_group==0) ? DW_ACQ : DW_START;
            end
            if (dw_state==DW_ACQ && dw_acquire_ready) dw_state<=DW_START;
            if (dw_state==DW_START && dw_compute_start_ready) dw_state<=DW_WAIT;
            if (dw_state==DW_WAIT && dw_compute_done_valid) dw_state<=DW_DRAIN;
            if (dw_sink_fire) dw_write_count<=dw_write_count+1;
            if (dw_state==DW_DRAIN && (dw_write_count >= dw_pixel_count_reg)) begin
                if (dw_group_reg + 1 >= dw_group_count_reg) dw_state<=DW_COMMIT;
                else begin
                    dw_done_valid<=1; dw_done_bank<=dw_target_bank_reg;
                    dw_done_epoch<=dw_target_epoch_reg; dw_done_tile<=dw_target_tile_reg;
                    dw_done_group<=dw_group_reg; dw_state<=DW_IDLE;
                end
            end
            if (dw_state==DW_COMMIT && dw_commit_ready) begin
                dw_done_valid<=1; dw_done_bank<=dw_target_bank_reg;
                dw_done_epoch<=dw_target_epoch_reg; dw_done_tile<=dw_target_tile_reg;
                dw_done_group<=dw_group_reg; dw_state<=DW_IDLE;
            end
            if (dw_compute_busy && (pw_state != PW_IDLE))
                dw_overlap_cycles<=dw_overlap_cycles+1;

            if (pw_job_valid && pw_job_ready) begin
                pw_bank_reg<=pw_bank; pw_epoch_reg<=pw_epoch; pw_tile_reg<=pw_tile;
                pw_cin_reg<=pw_input_channels; pw_cout_reg<=pw_output_channels;
                pw_pixels_reg<=pw_pixel_count; pw_zp_reg<=pw_output_zero_point;
                pw_min_reg<=pw_activation_min; pw_max_reg<=pw_activation_max;
                pw_row_reg<=0; pw_cout_group<=0; pw_read_idx<=0; pw_read_inflight<=0;
                pw_reads_done<=0; pw_state<=PW_ACQ;
            end
            if (pw_state==PW_ACQ && pw_acquire_ready) pw_state<=PW_READ;
            if (pw_read_fire) begin
                pw_read_inflight<=1; pw_read_count<=pw_read_count+1;
            end
            if (pw_buf_fire) begin
                pw_read_inflight<=0; pw_issue_count<=pw_issue_count+1;
                if (pw_read_idx + 1 >= pw_cin_reg) begin
                    pw_reads_done<=1; pw_state<=PW_WAIT_CORE;
                end else pw_read_idx<=pw_read_idx+1;
            end
            if (pw_state==PW_RQ && !rq_busy && !(|rq_valid)) begin
                if (pw_row_reg + 1 < ((pw_pixels_reg+7)/8)) begin
                    pw_row_reg<=pw_row_reg+1; pw_read_idx<=0; pw_reads_done<=0;
                    pw_read_inflight<=0; pw_state<=PW_READ;
                end else if (pw_cout_group + 1 < ((pw_cout_reg+7)/8)) begin
                    pw_cout_group<=pw_cout_group+1; pw_row_reg<=0; pw_read_idx<=0;
                    pw_reads_done<=0; pw_read_inflight<=0; pw_state<=PW_READ;
                end else pw_state<=PW_RELEASE;
            end
            if (pw_state==PW_WAIT_CORE && pw_core_out_valid) pw_state<=PW_RQ;
            if (pw_state==PW_RELEASE && pw_release_ready) begin
                pw_done_valid<=1; pw_done_bank<=pw_bank_reg; pw_done_epoch<=pw_epoch_reg;
                pw_done_tile<=pw_tile_reg; pw_state<=PW_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
