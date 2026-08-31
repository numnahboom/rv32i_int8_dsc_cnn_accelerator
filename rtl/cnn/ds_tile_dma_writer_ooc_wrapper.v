`timescale 1ns/1ps
`default_nettype none

/* Fixed 10x10x48 physical screen for the one-buffer DMA writer. */
module ds_tile_dma_writer_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_bank, input wire [3:0] fill_epoch,
    input wire [23:0] fill_base_byte_addr, input wire [15:0] fill_extent,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [23:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank, output wire [3:0] fill_done_epoch,
    input wire rd_en, input wire [8:0] rd_pixel_idx,
    input wire [2:0] rd_channel_tile, output wire rd_valid,
    output wire signed [127:0] rd_data_vector,
    output wire busy, output wire [31:0] stale_resp_count,
    output wire [31:0] issue_count, output wire [31:0] response_count,
    output wire [31:0] write_count
);
  ds_tile_dma_writer #(
    .MAX_CIN(128), .LAYOUT_CIN(48), .MAX_IN_H(10), .MAX_IN_W(10),
    .LANES(16), .ADDR_WIDTH(24), .EXTENT_WIDTH(16),
    .TOKEN_DEPTH(8), .RESPONSE_DEPTH(8), .COMMAND_DEPTH(8)
  ) u_writer (
    .clk(clk), .rst_n(rst_n),
    .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
    .fill_bank(fill_bank), .fill_epoch(fill_epoch),
    .fill_base_byte_addr(fill_base_byte_addr), .fill_extent(fill_extent),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
    .mem_resp_data(mem_resp_data), .fill_done_valid(fill_done_valid),
    .fill_done_ready(fill_done_ready), .fill_done_bank(fill_done_bank),
    .fill_done_epoch(fill_done_epoch), .rd_en(rd_en),
    .rd_pixel_idx(rd_pixel_idx), .rd_channel_tile(rd_channel_tile),
    .rd_valid(rd_valid), .rd_data_vector(rd_data_vector), .busy(busy),
    .stale_resp_count(stale_resp_count), .issue_count(issue_count),
    .response_count(response_count), .write_count(write_count)
  );
endmodule
`default_nettype wire
