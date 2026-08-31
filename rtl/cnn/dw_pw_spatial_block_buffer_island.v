`timescale 1ns/1ps
`default_nettype none

/*
 * Elastic two-bank composition.  Selection logic is confined to this
 * transaction boundary; each bank manager owns its protocol state and BRAM
 * enables.  The scheduler never drives a physical memory enable directly.
 */
module dw_pw_spatial_block_buffer_island #(
    parameter EPOCH_WIDTH = 2,
    parameter BLOCK_ID_WIDTH = 8
) (
    input wire clk, input wire rst_n,
    input wire dw_acquire_valid, output wire dw_acquire_ready,
    input wire dw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] dw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_acquire_block_id,
    input wire [7:0] dw_acquire_pixel_mask,
    input wire [7:0] dw_acquire_group_mask,
    input wire dw_write_valid, output wire dw_write_ready,
    input wire dw_write_bank,
    input wire [EPOCH_WIDTH-1:0] dw_write_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_write_block_id,
    input wire [2:0] dw_write_pixel_idx,
    input wire dw_write_pixel_valid,
    input wire [2:0] dw_write_channel_group,
    input wire [127:0] dw_write_data,
    input wire [15:0] dw_write_lane_mask,
    input wire dw_commit_valid, output wire dw_commit_ready,
    input wire dw_commit_bank,
    input wire [EPOCH_WIDTH-1:0] dw_commit_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] dw_commit_block_id,
    input wire pw_acquire_valid, output wire pw_acquire_ready,
    input wire pw_acquire_bank,
    input wire [EPOCH_WIDTH-1:0] pw_acquire_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_acquire_block_id,
    input wire pw_read_valid, output wire pw_read_ready,
    input wire pw_read_bank,
    input wire [EPOCH_WIDTH-1:0] pw_read_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_read_block_id,
    input wire [6:0] pw_read_channel_idx,
    output wire pw_out_valid, input wire pw_out_ready,
    output wire [EPOCH_WIDTH-1:0] pw_out_epoch,
    output wire [BLOCK_ID_WIDTH-1:0] pw_out_block_id,
    output wire pw_out_bank, output wire [63:0] pw_out_data,
    output wire [7:0] pw_out_lane_mask,
    input wire pw_release_valid, output wire pw_release_ready,
    input wire pw_release_bank,
    input wire [EPOCH_WIDTH-1:0] pw_release_epoch,
    input wire [BLOCK_ID_WIDTH-1:0] pw_release_block_id,
    output wire dw_commit_pulse, output wire pw_acquire_pulse,
    output wire pw_release_pulse,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire [EPOCH_WIDTH-1:0] bank0_epoch,
    output wire [EPOCH_WIDTH-1:0] bank1_epoch,
    output wire [BLOCK_ID_WIDTH-1:0] bank0_block_id,
    output wire [BLOCK_ID_WIDTH-1:0] bank1_block_id
);
    wire [1:0] b0_state, b1_state;
    wire [EPOCH_WIDTH-1:0] b0_epoch, b1_epoch;
    wire [BLOCK_ID_WIDTH-1:0] b0_block_id, b1_block_id;
    wire b0_dw_acq_ready, b1_dw_acq_ready, b0_dw_wr_ready, b1_dw_wr_ready;
    wire b0_commit_ready, b1_commit_ready, b0_pw_acq_ready, b1_pw_acq_ready;
    wire b0_pw_read_ready, b1_pw_read_ready, b0_pw_release_ready, b1_pw_release_ready;
    wire b0_out_valid, b1_out_valid;
    wire [EPOCH_WIDTH-1:0] b0_out_epoch, b1_out_epoch;
    wire [BLOCK_ID_WIDTH-1:0] b0_out_block_id, b1_out_block_id;
    wire [63:0] b0_out_data, b1_out_data;
    wire [7:0] b0_out_mask, b1_out_mask;
    wire b0_commit_pulse, b1_commit_pulse, b0_acq_pulse, b1_acq_pulse;
    wire b0_release_pulse, b1_release_pulse;

    assign dw_acquire_ready = dw_acquire_bank ? b1_dw_acq_ready : b0_dw_acq_ready;
    assign dw_write_ready = dw_write_bank ? b1_dw_wr_ready : b0_dw_wr_ready;
    assign dw_commit_ready = dw_commit_bank ? b1_commit_ready : b0_commit_ready;
    assign pw_acquire_ready = pw_acquire_bank ? b1_pw_acq_ready : b0_pw_acq_ready;
    assign pw_read_ready = pw_read_bank ? b1_pw_read_ready : b0_pw_read_ready;
    assign pw_release_ready = pw_release_bank ? b1_pw_release_ready : b0_pw_release_ready;
    assign pw_out_valid = b0_out_valid | b1_out_valid;
    assign pw_out_bank = b1_out_valid;
    assign pw_out_epoch = b1_out_valid ? b1_out_epoch : b0_out_epoch;
    assign pw_out_block_id = b1_out_valid ? b1_out_block_id : b0_out_block_id;
    assign pw_out_data = b1_out_valid ? b1_out_data : b0_out_data;
    assign pw_out_lane_mask = b1_out_valid ? b1_out_mask : b0_out_mask;
    assign dw_commit_pulse = b0_commit_pulse | b1_commit_pulse;
    assign pw_acquire_pulse = b0_acq_pulse | b1_acq_pulse;
    assign pw_release_pulse = b0_release_pulse | b1_release_pulse;
    assign bank0_state = b0_state; assign bank1_state = b1_state;
    assign bank0_epoch = b0_epoch; assign bank1_epoch = b1_epoch;
    assign bank0_block_id = b0_block_id; assign bank1_block_id = b1_block_id;

    dw_pw_spatial_bank_bram #(.EPOCH_WIDTH(EPOCH_WIDTH), .BLOCK_ID_WIDTH(BLOCK_ID_WIDTH)) bank0 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && !dw_acquire_bank), .dw_acquire_ready(b0_dw_acq_ready),
        .dw_acquire_epoch(dw_acquire_epoch), .dw_acquire_block_id(dw_acquire_block_id),
        .dw_acquire_pixel_mask(dw_acquire_pixel_mask), .dw_acquire_group_mask(dw_acquire_group_mask),
        .dw_write_valid(dw_write_valid && !dw_write_bank), .dw_write_ready(b0_dw_wr_ready),
        .dw_write_epoch(dw_write_epoch), .dw_write_block_id(dw_write_block_id),
        .dw_write_pixel_idx(dw_write_pixel_idx), .dw_write_pixel_valid(dw_write_pixel_valid),
        .dw_write_channel_group(dw_write_channel_group), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask), .dw_commit_valid(dw_commit_valid && !dw_commit_bank),
        .dw_commit_ready(b0_commit_ready), .dw_commit_epoch(dw_commit_epoch),
        .dw_commit_block_id(dw_commit_block_id), .pw_acquire_valid(pw_acquire_valid && !pw_acquire_bank),
        .pw_acquire_ready(b0_pw_acq_ready), .pw_acquire_epoch(pw_acquire_epoch),
        .pw_acquire_block_id(pw_acquire_block_id), .pw_read_valid(pw_read_valid && !pw_read_bank),
        .pw_read_ready(b0_pw_read_ready), .pw_read_epoch(pw_read_epoch),
        .pw_read_block_id(pw_read_block_id), .pw_read_channel_idx(pw_read_channel_idx),
        .pw_out_valid(b0_out_valid), .pw_out_ready(pw_out_ready && !b1_out_valid),
        .pw_out_epoch(b0_out_epoch), .pw_out_block_id(b0_out_block_id), .pw_out_data(b0_out_data),
        .pw_out_lane_mask(b0_out_mask), .pw_release_valid(pw_release_valid && !pw_release_bank),
        .pw_release_ready(b0_pw_release_ready), .pw_release_epoch(pw_release_epoch),
        .pw_release_block_id(pw_release_block_id), .commit_pulse(b0_commit_pulse),
        .acquire_pulse(b0_acq_pulse), .release_pulse(b0_release_pulse), .state(b0_state),
        .state_epoch(b0_epoch), .state_block_id(b0_block_id)
    );
    dw_pw_spatial_bank_bram #(.EPOCH_WIDTH(EPOCH_WIDTH), .BLOCK_ID_WIDTH(BLOCK_ID_WIDTH)) bank1 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && dw_acquire_bank), .dw_acquire_ready(b1_dw_acq_ready),
        .dw_acquire_epoch(dw_acquire_epoch), .dw_acquire_block_id(dw_acquire_block_id),
        .dw_acquire_pixel_mask(dw_acquire_pixel_mask), .dw_acquire_group_mask(dw_acquire_group_mask),
        .dw_write_valid(dw_write_valid && dw_write_bank), .dw_write_ready(b1_dw_wr_ready),
        .dw_write_epoch(dw_write_epoch), .dw_write_block_id(dw_write_block_id),
        .dw_write_pixel_idx(dw_write_pixel_idx), .dw_write_pixel_valid(dw_write_pixel_valid),
        .dw_write_channel_group(dw_write_channel_group), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask), .dw_commit_valid(dw_commit_valid && dw_commit_bank),
        .dw_commit_ready(b1_commit_ready), .dw_commit_epoch(dw_commit_epoch),
        .dw_commit_block_id(dw_commit_block_id), .pw_acquire_valid(pw_acquire_valid && pw_acquire_bank),
        .pw_acquire_ready(b1_pw_acq_ready), .pw_acquire_epoch(pw_acquire_epoch),
        .pw_acquire_block_id(pw_acquire_block_id), .pw_read_valid(pw_read_valid && pw_read_bank),
        .pw_read_ready(b1_pw_read_ready), .pw_read_epoch(pw_read_epoch),
        .pw_read_block_id(pw_read_block_id), .pw_read_channel_idx(pw_read_channel_idx),
        .pw_out_valid(b1_out_valid), .pw_out_ready(pw_out_ready && !b0_out_valid),
        .pw_out_epoch(b1_out_epoch), .pw_out_block_id(b1_out_block_id), .pw_out_data(b1_out_data),
        .pw_out_lane_mask(b1_out_mask), .pw_release_valid(pw_release_valid && pw_release_bank),
        .pw_release_ready(b1_pw_release_ready), .pw_release_epoch(pw_release_epoch),
        .pw_release_block_id(pw_release_block_id), .commit_pulse(b1_commit_pulse),
        .acquire_pulse(b1_acq_pulse), .release_pulse(b1_release_pulse), .state(b1_state),
        .state_epoch(b1_epoch), .state_block_id(b1_block_id)
    );
endmodule
`default_nettype wire
