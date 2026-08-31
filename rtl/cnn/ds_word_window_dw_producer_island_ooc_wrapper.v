`timescale 1ns/1ps
`default_nettype none

/* Fixed 17x17/three-group OOC boundary for the word-window DW island. */
module ds_word_window_dw_producer_island_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_start_bank, input wire [3:0] fill_start_epoch,
    input wire [23:0] fill_start_base_addr, input wire [15:0] fill_start_word_count,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank, output wire [3:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [23:0] mem_req_addr, input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,
    input wire cfg_valid, output wire cfg_ready, input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    input wire compute_start_valid, output wire compute_start_ready,
    input wire compute_bank, input wire [3:0] compute_epoch,
    input wire [15:0] compute_lane_mask, input wire [1:0] compute_stride,
    input wire [7:0] compute_footprint_height, input wire [7:0] compute_footprint_width,
    input wire [7:0] compute_pitch, output wire compute_done_valid,
    input wire compute_done_ready, output wire compute_done_bank,
    output wire [3:0] compute_done_epoch, output wire compute_busy,
    output wire valid_out, input wire ready_out, output wire [7:0] out_pixel_idx,
    output wire [15:0] out_lane_mask, output wire signed [511:0] out_raw_vec,
    output wire signed [511:0] out_bias_vec,
    output wire signed [511:0] out_multiplier_vec, output wire [95:0] out_shift_vec,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire fill_busy, output wire read_busy,
    output wire [31:0] fill_word_count_seen, output wire [31:0] read_vector_count,
    output wire [31:0] token_count, output wire [31:0] overlap_cycles,
    output wire [31:0] stale_command_count
);
    ds_word_window_dw_producer_island #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(1), .ADDR_WIDTH(24), .WORD_COUNT_WIDTH(16),
        .VECTOR_ADDR_WIDTH(10), .EPOCH_WIDTH(4), .TAG_WIDTH(16), .FIFO_DEPTH(8)
    ) u_island (
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
        .cfg_shift_vec(cfg_shift_vec), .compute_start_valid(compute_start_valid),
        .compute_start_ready(compute_start_ready), .compute_bank(compute_bank),
        .compute_epoch(compute_epoch), .compute_lane_mask(compute_lane_mask),
        .compute_stride(compute_stride),
        .compute_footprint_height(compute_footprint_height),
        .compute_footprint_width(compute_footprint_width), .compute_pitch(compute_pitch),
        .compute_done_valid(compute_done_valid), .compute_done_ready(compute_done_ready),
        .compute_done_bank(compute_done_bank), .compute_done_epoch(compute_done_epoch),
        .compute_busy(compute_busy), .valid_out(valid_out), .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask),
        .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
        .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec),
        .bank0_state(bank0_state), .bank1_state(bank1_state), .fill_busy(fill_busy),
        .read_busy(read_busy), .fill_word_count_seen(fill_word_count_seen),
        .read_vector_count(read_vector_count), .token_count(token_count),
        .overlap_cycles(overlap_cycles), .stale_command_count(stale_command_count)
    );
endmodule
`default_nettype wire
