`timescale 1ns/1ps
`default_nettype none

/* Fixed-shape OOC wrapper for the 2-bank ownership controller. */
module feature_tile_pingpong_ctrl_ooc_wrapper (
  input wire clk, input wire rst_n,
  input wire fill_start_valid, output wire fill_start_ready, input wire fill_start_bank,
  input wire [3:0] fill_start_epoch, input wire [7:0] fill_start_tag, input wire [11:0] fill_start_extent,
  output wire fill_start_resp_valid, input wire fill_start_resp_ready, output wire fill_start_resp_ok, output wire [2:0] fill_start_resp_error,
  input wire fill_done_valid, output wire fill_done_ready, input wire fill_done_bank,
  input wire [3:0] fill_done_epoch, input wire [7:0] fill_done_tag, input wire [11:0] fill_done_extent,
  output wire fill_done_desc_valid, input wire fill_done_desc_ready, output wire fill_done_desc_bank,
  output wire [3:0] fill_done_desc_epoch, output wire [7:0] fill_done_desc_tag, output wire [11:0] fill_done_desc_extent,
  output wire fill_done_ok, output wire [2:0] fill_done_error,
  input wire acquire_valid, output wire acquire_ready, input wire acquire_bank,
  input wire [3:0] acquire_epoch, input wire [7:0] acquire_tag, input wire [11:0] acquire_extent,
  output wire active_desc_valid, input wire active_desc_ready, output wire active_desc_bank,
  output wire [3:0] active_desc_epoch, output wire [7:0] active_desc_tag, output wire [11:0] active_desc_extent,
  output wire acquire_ok, output wire [2:0] acquire_error,
  input wire consume_done_valid, output wire consume_done_ready, input wire consume_done_bank,
  input wire [3:0] consume_done_epoch, input wire [7:0] consume_done_tag, input wire [11:0] consume_done_extent,
  output wire consume_done_resp_valid, input wire consume_done_resp_ready, output wire consume_done_ok, output wire [2:0] consume_done_error,
  input wire release_valid, output wire release_ready, input wire release_bank,
  input wire [3:0] release_epoch, input wire [7:0] release_tag, input wire [11:0] release_extent,
  output wire release_resp_valid, input wire release_resp_ready, output wire release_ok, output wire [2:0] release_error,
  output wire [2:0] bank0_state, output wire [2:0] bank1_state
);
  feature_tile_pingpong_ctrl #(.EPOCH_WIDTH(4), .TAG_WIDTH(8), .EXTENT_WIDTH(12)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready), .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch), .fill_start_tag(fill_start_tag), .fill_start_extent(fill_start_extent),
    .fill_start_resp_valid(fill_start_resp_valid), .fill_start_resp_ready(fill_start_resp_ready), .fill_start_resp_ok(fill_start_resp_ok), .fill_start_resp_error(fill_start_resp_error),
    .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready), .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch), .fill_done_tag(fill_done_tag), .fill_done_extent(fill_done_extent),
    .fill_done_desc_valid(fill_done_desc_valid), .fill_done_desc_ready(fill_done_desc_ready), .fill_done_desc_bank(fill_done_desc_bank), .fill_done_desc_epoch(fill_done_desc_epoch), .fill_done_desc_tag(fill_done_desc_tag), .fill_done_desc_extent(fill_done_desc_extent), .fill_done_ok(fill_done_ok), .fill_done_error(fill_done_error),
    .acquire_valid(acquire_valid), .acquire_ready(acquire_ready), .acquire_bank(acquire_bank), .acquire_epoch(acquire_epoch), .acquire_tag(acquire_tag), .acquire_extent(acquire_extent),
    .active_desc_valid(active_desc_valid), .active_desc_ready(active_desc_ready), .active_desc_bank(active_desc_bank), .active_desc_epoch(active_desc_epoch), .active_desc_tag(active_desc_tag), .active_desc_extent(active_desc_extent), .acquire_ok(acquire_ok), .acquire_error(acquire_error),
    .consume_done_valid(consume_done_valid), .consume_done_ready(consume_done_ready), .consume_done_bank(consume_done_bank), .consume_done_epoch(consume_done_epoch), .consume_done_tag(consume_done_tag), .consume_done_extent(consume_done_extent), .consume_done_resp_valid(consume_done_resp_valid), .consume_done_resp_ready(consume_done_resp_ready), .consume_done_ok(consume_done_ok), .consume_done_error(consume_done_error),
    .release_valid(release_valid), .release_ready(release_ready), .release_bank(release_bank), .release_epoch(release_epoch), .release_tag(release_tag), .release_extent(release_extent), .release_resp_valid(release_resp_valid), .release_resp_ready(release_resp_ready), .release_ok(release_ok), .release_error(release_error), .bank0_state(bank0_state), .bank1_state(bank1_state));
endmodule
`default_nettype wire
