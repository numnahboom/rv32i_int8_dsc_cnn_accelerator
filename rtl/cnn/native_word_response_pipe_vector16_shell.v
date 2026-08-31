`timescale 1ns/1ps
`default_nettype none

/* Thin composition boundary: native memory response pipe -> vector16 shell. */
module native_word_response_pipe_vector16_shell #(
  parameter integer MAX_CHANNELS=48, MAX_IN_H=10, MAX_IN_W=10,
  parameter integer ADDR_WIDTH=24, EPOCH_WIDTH=4, TAG_WIDTH=8, EXTENT_WIDTH=16,
  parameter integer FIFO_DEPTH=64
) (
  input wire clk, input wire rst_n,
  input wire fill_start_valid, output wire fill_start_ready,
  input wire fill_bank, input wire [EPOCH_WIDTH-1:0] fill_epoch,
  input wire [TAG_WIDTH-1:0] fill_tag, input wire [EXTENT_WIDTH-1:0] fill_extent,
  input wire [ADDR_WIDTH-1:0] fill_base_byte_addr, input wire [31:0] fill_word_count,
  output wire fill_start_resp_valid, input wire fill_start_resp_ready,
  output wire fill_start_resp_ok, output wire [2:0] fill_start_resp_error,
  output wire mem_req_valid, input wire mem_req_ready, output wire [ADDR_WIDTH-1:0] mem_req_addr,
  input wire mem_rvalid, input wire [31:0] mem_rdata,
  output wire fill_done_desc_valid, input wire fill_done_desc_ready,
  output wire fill_done_desc_bank, output wire [EPOCH_WIDTH-1:0] fill_done_desc_epoch,
  output wire [TAG_WIDTH-1:0] fill_done_desc_tag, output wire [EXTENT_WIDTH-1:0] fill_done_desc_extent,
  output wire fill_done_ok, output wire [2:0] fill_done_error,
  input wire acquire_valid, output wire acquire_ready, input wire acquire_bank,
  input wire [EPOCH_WIDTH-1:0] acquire_epoch, input wire [TAG_WIDTH-1:0] acquire_tag,
  input wire [EXTENT_WIDTH-1:0] acquire_extent, output wire active_desc_valid,
  input wire active_desc_ready, output wire active_desc_bank,
  output wire [EPOCH_WIDTH-1:0] active_desc_epoch, output wire [TAG_WIDTH-1:0] active_desc_tag,
  output wire [EXTENT_WIDTH-1:0] active_desc_extent, output wire acquire_ok, output wire [2:0] acquire_error,
  input wire consume_done_valid, output wire consume_done_ready, input wire consume_done_bank,
  input wire [EPOCH_WIDTH-1:0] consume_done_epoch, input wire [TAG_WIDTH-1:0] consume_done_tag,
  input wire [EXTENT_WIDTH-1:0] consume_done_extent, output wire consume_done_resp_valid,
  input wire consume_done_resp_ready, output wire consume_done_ok, output wire [2:0] consume_done_error,
  input wire release_valid, output wire release_ready, input wire release_bank,
  input wire [EPOCH_WIDTH-1:0] release_epoch, input wire [TAG_WIDTH-1:0] release_tag,
  input wire [EXTENT_WIDTH-1:0] release_extent, output wire release_resp_valid,
  input wire release_resp_ready, output wire release_ok, output wire [2:0] release_error,
  input wire rd_req_valid, output wire rd_req_ready, input wire [6:0] rd_pixel_idx,
  input wire [1:0] rd_channel_group, input wire [15:0] rd_lane_mask,
  input wire [TAG_WIDTH-1:0] rd_tag, output wire rd_resp_valid, input wire rd_resp_ready,
  output wire [127:0] rd_data_vector, output wire [15:0] rd_resp_lane_mask,
  output wire [TAG_WIDTH-1:0] rd_resp_tag,
  output wire [2:0] bank0_state, output wire [2:0] bank1_state,
  output wire active_bank
);
  localparam integer SHELL_AW = $clog2(MAX_IN_H*MAX_IN_W*MAX_CHANNELS+3);
  localparam integer SHELL_PA = $clog2(MAX_IN_H*MAX_IN_W);
  localparam integer SHELL_GA = $clog2((MAX_CHANNELS+15)/16);
  localparam integer SHELL_BA = $clog2(MAX_IN_H*MAX_IN_W*((MAX_CHANNELS+15)/16));
  wire pipe_fill_ready, pipe_fill_done_valid, pipe_fill_done_bank;
  wire [EPOCH_WIDTH-1:0] pipe_fill_done_epoch;
  wire pipe_wr_valid, pipe_wr_ready, pipe_wr_bank, pipe_wr_last;
  wire [EPOCH_WIDTH-1:0] pipe_wr_epoch;
  wire [ADDR_WIDTH-1:0] pipe_wr_byte_addr;
  wire [31:0] pipe_wr_data;
  wire [3:0] pipe_wr_mask;
  wire done_pending;
  reg done_pending_reg;
  reg [EPOCH_WIDTH-1:0] done_epoch_reg;
  reg done_bank_reg;
  reg [TAG_WIDTH-1:0] done_tag_reg;
  reg [EXTENT_WIDTH-1:0] done_extent_reg;
  reg [TAG_WIDTH-1:0] fill_tag_reg;
  reg [EXTENT_WIDTH-1:0] fill_extent_reg;
  wire shell_fill_start_ready, shell_fill_start_fire;
  wire shell_fill_done_ready;
  wire shell_wr_ready;
  wire shell_wr_drain_ready;
  wire shell_fill_state_free = fill_bank ? (bank1_state == 3'd0) : (bank0_state == 3'd0);
  // The shell controller returns an explicit error for a non-FREE bank.  Do
  // not hide that response behind a combinational state predicate; keeping
  // this boundary open also avoids a ready/ownership race during swaps.
  wire start_gate = !done_pending_reg;
  assign fill_start_ready = pipe_fill_ready && shell_fill_start_ready && start_gate;
  assign shell_fill_start_fire = fill_start_valid && pipe_fill_ready && start_gate;
  assign done_pending = done_pending_reg;

  native_word_response_pipe #(.ADDR_WIDTH(ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH), .MEM_RD_LATENCY(3)) u_pipe (
    .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid && shell_fill_start_ready && start_gate),
    .fill_start_ready(pipe_fill_ready), .fill_epoch(fill_epoch), .fill_bank(fill_bank),
    .fill_base_byte_addr(fill_base_byte_addr), .fill_word_count(fill_word_count),
    .issue_valid(1'b1), .issue_ready(), .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
    .wr_valid(pipe_wr_valid), .wr_ready(pipe_wr_ready), .wr_epoch(pipe_wr_epoch), .wr_bank(pipe_wr_bank),
    .wr_byte_addr(pipe_wr_byte_addr), .wr_data(pipe_wr_data), .wr_byte_mask(pipe_wr_mask), .wr_last(pipe_wr_last),
    .fill_done_valid(pipe_fill_done_valid), .fill_done_epoch(pipe_fill_done_epoch), .fill_done_bank(pipe_fill_done_bank),
    .stale_resp_count(), .issue_count(), .response_count());

  feature_tile_vector16_pingpong_shell #(.MAX_CHANNELS(MAX_CHANNELS), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
    .EPOCH_WIDTH(EPOCH_WIDTH), .TAG_WIDTH(TAG_WIDTH), .EXTENT_WIDTH(EXTENT_WIDTH),
    .BYTE_ADDR_WIDTH(SHELL_AW), .PIXEL_ADDR_WIDTH(SHELL_PA), .GROUP_ADDR_WIDTH(SHELL_GA), .BANK_ADDR_WIDTH(SHELL_BA)) u_shell (
    .clk(clk), .rst_n(rst_n), .fill_start_valid(shell_fill_start_fire), .fill_start_ready(shell_fill_start_ready),
    .fill_start_bank(fill_bank), .fill_start_epoch(fill_epoch), .fill_start_tag(fill_tag), .fill_start_extent(fill_extent),
    .fill_start_resp_valid(fill_start_resp_valid), .fill_start_resp_ready(fill_start_resp_ready), .fill_start_resp_ok(fill_start_resp_ok), .fill_start_resp_error(fill_start_resp_error),
    .fill_done_valid(done_pending_reg && shell_wr_drain_ready), .fill_done_ready(shell_fill_done_ready), .fill_done_bank(done_bank_reg), .fill_done_epoch(done_epoch_reg), .fill_done_tag(done_tag_reg), .fill_done_extent(done_extent_reg),
    .fill_done_desc_valid(fill_done_desc_valid), .fill_done_desc_ready(fill_done_desc_ready), .fill_done_desc_bank(fill_done_desc_bank), .fill_done_desc_epoch(fill_done_desc_epoch), .fill_done_desc_tag(fill_done_desc_tag), .fill_done_desc_extent(fill_done_desc_extent), .fill_done_ok(fill_done_ok), .fill_done_error(fill_done_error),
    .acquire_valid(acquire_valid), .acquire_ready(acquire_ready), .acquire_bank(acquire_bank), .acquire_epoch(acquire_epoch), .acquire_tag(acquire_tag), .acquire_extent(acquire_extent), .active_desc_valid(active_desc_valid), .active_desc_ready(active_desc_ready), .active_desc_bank(active_desc_bank), .active_desc_epoch(active_desc_epoch), .active_desc_tag(active_desc_tag), .active_desc_extent(active_desc_extent), .acquire_ok(acquire_ok), .acquire_error(acquire_error),
    .consume_done_valid(consume_done_valid), .consume_done_ready(consume_done_ready), .consume_done_bank(consume_done_bank), .consume_done_epoch(consume_done_epoch), .consume_done_tag(consume_done_tag), .consume_done_extent(consume_done_extent), .consume_done_resp_valid(consume_done_resp_valid), .consume_done_resp_ready(consume_done_resp_ready), .consume_done_ok(consume_done_ok), .consume_done_error(consume_done_error),
    .release_valid(release_valid), .release_ready(release_ready), .release_bank(release_bank), .release_epoch(release_epoch), .release_tag(release_tag), .release_extent(release_extent), .release_resp_valid(release_resp_valid), .release_resp_ready(release_resp_ready), .release_ok(release_ok), .release_error(release_error),
    .wr_valid(pipe_wr_valid), .wr_ready(shell_wr_ready), .wr_drain_ready(shell_wr_drain_ready), .wr_bank(done_pending_reg ? done_bank_reg : pipe_wr_bank), .wr_base_byte_addr(pipe_wr_byte_addr[SHELL_AW-1:0]), .wr_data(pipe_wr_data), .wr_byte_en(pipe_wr_mask),
    .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready), .rd_pixel_idx(rd_pixel_idx), .rd_channel_group(rd_channel_group), .rd_lane_mask(rd_lane_mask), .rd_tag(rd_tag), .rd_use_lane_addr(1'b0), .rd_lane_addr({(16*SHELL_BA){1'b0}}), .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready), .rd_data_vector(rd_data_vector), .rd_resp_lane_mask(rd_resp_lane_mask), .rd_resp_tag(rd_resp_tag), .bank0_state(bank0_state), .bank1_state(bank1_state), .fill_active(), .active_valid(), .fill_bank(), .active_bank(active_bank));
  assign pipe_wr_ready = shell_wr_ready;

  always @(posedge clk) begin
    if (!rst_n) begin
      done_pending_reg <= 1'b0; done_epoch_reg <= '0; done_bank_reg <= 1'b0; done_tag_reg <= '0; done_extent_reg <= '0;
      fill_tag_reg <= '0; fill_extent_reg <= '0;
    end else begin
      if (shell_fill_start_fire && shell_fill_start_ready) begin
        fill_tag_reg <= fill_tag;
        fill_extent_reg <= fill_extent;
      end
      if (pipe_fill_done_valid) begin
        done_pending_reg <= 1'b1; done_epoch_reg <= pipe_fill_done_epoch; done_bank_reg <= pipe_fill_done_bank; done_tag_reg <= fill_tag_reg; done_extent_reg <= fill_extent_reg;
      end
      if (done_pending_reg && shell_wr_drain_ready && shell_fill_done_ready)
        done_pending_reg <= 1'b0;
    end
  end
endmodule
`default_nettype wire
