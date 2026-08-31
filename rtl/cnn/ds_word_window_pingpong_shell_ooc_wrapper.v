`timescale 1ns/1ps
`default_nettype none

/* Fixed worst-case OOC shell boundary: 17x17 storage, three channel groups. */
module ds_word_window_pingpong_shell_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire fill_start_valid, input wire fill_start_bank,
    input wire [3:0] fill_start_epoch,
    input wire [23:0] fill_start_base_addr,
    input wire [15:0] fill_start_word_count,
    output wire fill_start_ready, output wire fill_done_valid,
    input wire fill_done_ready, output wire fill_done_bank,
    output wire [3:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [23:0] mem_req_addr, input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,
    input wire read_start_valid, input wire read_start_bank,
    input wire [3:0] read_start_epoch, input wire [7:0] read_height,
    input wire [7:0] read_width, input wire [7:0] read_stride,
    input wire [7:0] read_pitch, input wire [9:0] read_base_vector,
    input wire [1:0] read_group, input wire [15:0] read_lane_mask,
    output wire read_start_ready, output wire read_done_valid,
    input wire read_done_ready, output wire read_done_bank,
    output wire [3:0] read_done_epoch,
    output wire rd_valid, input wire rd_ready, output wire [9:0] rd_vector_addr,
    output wire [15:0] rd_lane_mask, output wire [15:0] rd_tag,
    output wire [3:0] rd_epoch, output wire [127:0] rd_data_vector,
    input wire release_valid, input wire release_bank,
    input wire [3:0] release_epoch, output wire release_ready,
    output wire release_resp_valid, input wire release_resp_ready,
    output wire release_resp_ok,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire fill_busy, output wire read_busy,
    output wire [31:0] fill_word_count_seen,
    output wire [31:0] read_vector_count, output wire [31:0] overlap_cycles,
    output wire [31:0] stale_command_count
);
    ds_word_window_pingpong_shell #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(3), .ADDR_WIDTH(24), .WORD_COUNT_WIDTH(16),
        .VECTOR_ADDR_WIDTH(10), .EPOCH_WIDTH(4), .TAG_WIDTH(16), .FIFO_DEPTH(8)
    ) u_shell (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr), .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .read_start_valid(read_start_valid), .read_start_ready(read_start_ready),
        .read_start_bank(read_start_bank), .read_start_epoch(read_start_epoch),
        .read_height(read_height), .read_width(read_width), .read_stride(read_stride),
        .read_pitch(read_pitch), .read_base_vector(read_base_vector), .read_group(read_group),
        .read_lane_mask(read_lane_mask), .read_done_valid(read_done_valid),
        .read_done_ready(read_done_ready), .read_done_bank(read_done_bank),
        .read_done_epoch(read_done_epoch), .rd_valid(rd_valid), .rd_ready(rd_ready),
        .rd_vector_addr(rd_vector_addr), .rd_lane_mask(rd_lane_mask), .rd_tag(rd_tag),
        .rd_epoch(rd_epoch), .rd_data_vector(rd_data_vector),
        .release_valid(release_valid), .release_ready(release_ready),
        .release_bank(release_bank), .release_epoch(release_epoch),
        .release_resp_valid(release_resp_valid), .release_resp_ready(release_resp_ready),
        .release_resp_ok(release_resp_ok), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .fill_busy(fill_busy), .read_busy(read_busy),
        .fill_word_count_seen(fill_word_count_seen), .read_vector_count(read_vector_count),
        .overlap_cycles(overlap_cycles), .stale_command_count(stale_command_count)
    );
endmodule
`default_nettype wire
