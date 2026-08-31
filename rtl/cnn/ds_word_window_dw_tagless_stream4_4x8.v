`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production 4x8-output word-window DW producer.
 *
 * This wrapper fixes the output geometry of the established tagless,
 * quad-local, local-stream4 pipeline to four rows by eight columns.  It
 * deliberately retains the existing ABI: one sixteen-lane raw DW result is
 * requantized into four ordered four-lane beats and the two tagless scratch
 * banks use epoch/tile only at their ownership fences.  The 4x8 geometry is
 * useful for a later pair of adjacent tiles feeding one 8-pixel PW block;
 * this file does not instantiate or alter the PW path.
 *
 * For stride one the source footprint is 6x10 (60 vectors/240 native
 * 32-bit words per sixteen-channel group) and the producer emits 32*9=288
 * accepted DW tokens.  For stride two the caller supplies the corresponding
 * 9x17 footprint.  The underlying producer's default remains 8x8, so this
 * wrapper cannot affect the production network.
 */
module ds_word_window_dw_tagless_stream4_4x8 #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 8,
    parameter integer USE_QUADLOCAL_CORE = 1,
    parameter integer USE_LOCAL_REQUANT = 1,
    parameter integer STREAM4_ONLY = 0,
    parameter integer OUTPUT_HEIGHT = 4
) (
    input wire clk, input wire rst_n,

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
    output wire dw_done_valid, input wire dw_done_ready,
    output wire dw_done_bank,
    output wire [EPOCH_WIDTH-1:0] dw_done_epoch,
    output wire [TILE_WIDTH-1:0] dw_done_tile,
    output wire [2:0] dw_done_group,

    input wire read_acquire_valid, output wire read_acquire_ready,
    input wire read_bank,
    input wire [EPOCH_WIDTH-1:0] read_epoch,
    input wire [TILE_WIDTH-1:0] read_tile,
    input wire read_valid, output wire read_ready,
    input wire [6:0] read_channel_idx,
    input wire [5:0] read_pixel_base,
    output wire read_out_valid, input wire read_out_ready,
    output wire [63:0] read_out_data,
    output wire [7:0] read_out_lane_mask,
    input wire read_release_valid, output wire read_release_ready,
    output wire [1:0] scratch0_state, output wire [1:0] scratch1_state,
    output wire [31:0] dw_write_count,
    output wire [31:0] overlap_cycles,
    output wire [31:0] read_count,
    output wire stream4_valid,
    input wire stream4_ready,
    output wire [5:0] stream4_pixel,
    output wire [1:0] stream4_lane_base,
    output wire [31:0] stream4_data,
    output wire [3:0] stream4_lane_mask
);
    ds_word_window_dw_tagless_stream4_pipeline #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TILE_WIDTH(TILE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .USE_QUADLOCAL_CORE(USE_QUADLOCAL_CORE),
        .USE_LOCAL_REQUANT(USE_LOCAL_REQUANT),
        .STREAM4_ONLY(STREAM4_ONLY), .OUTPUT_HEIGHT(OUTPUT_HEIGHT), .OUTPUT_WIDTH(8)
    ) u_4x8 (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .dw_job_valid(dw_job_valid),
        .dw_job_ready(dw_job_ready), .dw_source_bank(dw_source_bank),
        .dw_source_epoch(dw_source_epoch), .dw_source_base_addr(dw_source_base_addr),
        .dw_source_lane_mask(dw_source_lane_mask),
        .dw_source_stride(dw_source_stride),
        .dw_footprint_height(dw_footprint_height),
        .dw_footprint_width(dw_footprint_width),
        .dw_footprint_pitch(dw_footprint_pitch),
        .dw_target_bank(dw_target_bank), .dw_target_epoch(dw_target_epoch),
        .dw_target_tile(dw_target_tile), .dw_channel_group(dw_channel_group),
        .dw_group_count(dw_group_count), .dw_pixel_count(dw_pixel_count),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min), .dw_activation_max(dw_activation_max),
        .dw_done_valid(dw_done_valid), .dw_done_ready(dw_done_ready),
        .dw_done_bank(dw_done_bank), .dw_done_epoch(dw_done_epoch),
        .dw_done_tile(dw_done_tile), .dw_done_group(dw_done_group),
        .read_acquire_valid(read_acquire_valid),
        .read_acquire_ready(read_acquire_ready), .read_bank(read_bank),
        .read_epoch(read_epoch), .read_tile(read_tile), .read_valid(read_valid),
        .read_ready(read_ready), .read_channel_idx(read_channel_idx),
        .read_pixel_base(read_pixel_base), .read_out_valid(read_out_valid),
        .read_out_ready(read_out_ready), .read_out_data(read_out_data),
        .read_out_lane_mask(read_out_lane_mask),
        .read_release_valid(read_release_valid),
        .read_release_ready(read_release_ready), .scratch0_state(scratch0_state),
        .scratch1_state(scratch1_state), .dw_write_count(dw_write_count),
        .overlap_cycles(overlap_cycles), .read_count(read_count),
        .stream4_valid(stream4_valid), .stream4_ready(stream4_ready),
        .stream4_pixel(stream4_pixel), .stream4_lane_base(stream4_lane_base),
        .stream4_data(stream4_data), .stream4_lane_mask(stream4_lane_mask)
    );
endmodule

`default_nettype wire
