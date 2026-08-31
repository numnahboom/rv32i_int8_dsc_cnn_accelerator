`timescale 1ns/1ps
`default_nettype none

/* Fixed-shape OOC screen for the reusable feeder.  The wrapper exposes the
 * compact control/data ABI without connecting any production runner. */
module feature_tile_word_feeder_ooc_wrapper (
  input wire clk, input wire rst_n,
  input wire fill_start_valid, output wire fill_start_ready, input wire fill_bank,
  input wire [7:0] fill_tile_id, input wire [3:0] fill_epoch, input wire [23:0] fill_base_byte_addr,
  input wire [15:0] fill_row_stride_bytes, input wire [4:0] fill_tile_h, input wire [4:0] fill_tile_w,
  input wire [7:0] fill_channels, input wire [31:0] fill_row_valid_mask, input wire [31:0] fill_col_valid_mask,
  input wire [7:0] fill_pad_value, output wire fill_done_valid, output wire fill_done_bank,
  output wire [7:0] fill_done_tile_id, output wire [3:0] fill_done_epoch,
  output wire mem_req_valid, input wire mem_req_ready, output wire [23:0] mem_req_addr,
  input wire mem_resp_valid, input wire [31:0] mem_resp_data,
  input wire activate_valid, output wire activate_ready, input wire activate_bank,
  input wire [7:0] activate_tile_id, input wire [3:0] activate_epoch, output wire active_bank,
  output wire [7:0] active_tile_id, output wire [3:0] active_epoch,
  input wire release_valid, output wire release_ready, input wire release_bank,
  input wire [7:0] release_tile_id, input wire [3:0] release_epoch,
  input wire consume_req_valid, output wire consume_req_ready, input wire [31:0] consume_byte_offset,
  output wire consume_resp_valid, input wire consume_resp_ready, output wire [7:0] consume_resp_data,
  output wire [7:0] consume_resp_tile_id, output wire [3:0] consume_resp_epoch, output wire consume_resp_bank
);
  wire [1:0] bank0_state, bank1_state;
  wire [31:0] perf0, perf1, perf2, perf3;
  // 8 KiB per bank covers the production first-Stem tile (10x10x3) and the
  // traffic-heavy 10x10x48 DS tile used by the feasibility bench.
  feature_tile_word_feeder #(.ADDR_WIDTH(24), .BANK_BYTES(8192), .MEM_RD_LATENCY(1)) u_feeder (
    .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
    .fill_bank(fill_bank), .fill_tile_id(fill_tile_id), .fill_epoch(fill_epoch), .fill_base_byte_addr(fill_base_byte_addr),
    .fill_row_stride_bytes(fill_row_stride_bytes), .fill_tile_h(fill_tile_h), .fill_tile_w(fill_tile_w), .fill_channels(fill_channels),
    .fill_row_valid_mask(fill_row_valid_mask), .fill_col_valid_mask(fill_col_valid_mask), .fill_pad_value(fill_pad_value),
    .fill_done_valid(fill_done_valid), .fill_done_bank(fill_done_bank), .fill_done_tile_id(fill_done_tile_id), .fill_done_epoch(fill_done_epoch),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
    .activate_valid(activate_valid), .activate_ready(activate_ready), .activate_bank(activate_bank), .activate_tile_id(activate_tile_id), .activate_epoch(activate_epoch),
    .active_bank(active_bank), .active_tile_id(active_tile_id), .active_epoch(active_epoch), .release_valid(release_valid), .release_ready(release_ready),
    .release_bank(release_bank), .release_tile_id(release_tile_id), .release_epoch(release_epoch), .consume_req_valid(consume_req_valid), .consume_req_ready(consume_req_ready),
    .consume_byte_offset(consume_byte_offset), .consume_resp_valid(consume_resp_valid), .consume_resp_ready(consume_resp_ready), .consume_resp_data(consume_resp_data),
    .consume_resp_tile_id(consume_resp_tile_id), .consume_resp_epoch(consume_resp_epoch), .consume_resp_bank(consume_resp_bank), .bank0_state(bank0_state), .bank1_state(bank1_state),
    .perf_mem_issue_count(perf0), .perf_mem_resp_count(perf1), .perf_consume_count(perf2), .perf_consume_stall_count(perf3));
endmodule
`default_nettype wire
