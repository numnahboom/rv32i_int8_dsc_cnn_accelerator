`timescale 1ns/1ps
`default_nettype none

/* Fixed-shape 8 ns screen for the reusable response/completion ABI. */
module native_word_response_pipe_ooc_wrapper (
  input wire clk, input wire rst_n,
  input wire fill_start_valid, output wire fill_start_ready,
  input wire [3:0] fill_epoch, input wire fill_bank,
  input wire [23:0] fill_base_byte_addr, input wire [31:0] fill_word_count,
  input wire issue_valid, output wire issue_ready,
  output wire mem_req_valid, input wire mem_req_ready, output wire [23:0] mem_req_addr,
  input wire mem_rvalid, input wire [31:0] mem_rdata,
  output wire wr_valid, input wire wr_ready, output wire [3:0] wr_epoch,
  output wire wr_bank, output wire [23:0] wr_byte_addr, output wire [31:0] wr_data,
  output wire [3:0] wr_byte_mask, output wire wr_last,
  output wire fill_done_valid, output wire [3:0] fill_done_epoch,
  output wire fill_done_bank
);
  wire [31:0] stale_resp_count, issue_count, response_count;
  native_word_response_pipe #(.ADDR_WIDTH(24), .EPOCH_WIDTH(4), .FIFO_DEPTH(64), .MEM_RD_LATENCY(3)) u_pipe (
    .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
    .fill_epoch(fill_epoch), .fill_bank(fill_bank), .fill_base_byte_addr(fill_base_byte_addr), .fill_word_count(fill_word_count),
    .issue_valid(issue_valid), .issue_ready(issue_ready), .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata), .wr_valid(wr_valid), .wr_ready(wr_ready),
    .wr_epoch(wr_epoch), .wr_bank(wr_bank), .wr_byte_addr(wr_byte_addr), .wr_data(wr_data), .wr_byte_mask(wr_byte_mask), .wr_last(wr_last),
    .fill_done_valid(fill_done_valid), .fill_done_epoch(fill_done_epoch), .fill_done_bank(fill_done_bank),
    .stale_resp_count(stale_resp_count), .issue_count(issue_count), .response_count(response_count));
endmodule
`default_nettype wire
