`timescale 1ns/1ps
`default_nettype none

/* Directed admission test for the local result FIFOs.  Output is held
 * permanently, so two completed blocks may be retained but the third new
 * block must be rejected; this proves output ready is not in the accumulator
 * path and that FIFO full is the only intentional admission fence. */
module tb_dual32_mac_local_island_fifo;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] mode_i = 0;
    reg cfg_valid_i = 0, cfg_island_i = 0;
    reg [5:0] cfg_lane_i = 0;
    reg signed [31:0] cfg_bias_i = 3, cfg_multiplier_i = 32'sh40000000;
    reg [5:0] cfg_shift_i = 0;
    wire cfg_ready_o;
    reg valid_in = 0, first_k = 0, last_k = 0;
    reg [7:0] k_idx = 0, block_tag_i = 0, pixel_base_i = 0, pixel_mask_i = 8'hff;
    reg [8:0] cout_base_i = 0;
    reg [15:0] cout_mask_i = 16'h00ff;
    reg signed [31:0] output_zero_point_i = 3, activation_min_i = -128, activation_max_i = 127;
    reg [31:0] src_word0_i = 32'h01010101, src_word1_i = 32'h01010101;
    reg [31:0] param_word0_i = 32'h02020202, param_word1_i = 32'h03030303;
    reg [31:0] param_word2_i = 0, param_word3_i = 0;
    wire ready_in, valid_out, busy_o;
    wire [31:0] out_word; wire [3:0] out_word_mask;
    wire [7:0] out_pixel_idx, out_block_tag; wire [8:0] out_channel_base;
    wire [2:0] out_group_idx; wire [1:0] out_mode;
    integer cyc = 0, accepted = 0, errors = 0;
    integer first_cycle [0:3];
    reg ready_sample;

    dual32_mac_local_island dut (
      .clk(clk), .rst_n(rst_n), .mode_i(mode_i), .cfg_valid_i(cfg_valid_i),
      .cfg_ready_o(cfg_ready_o), .cfg_island_i(cfg_island_i), .cfg_lane_i(cfg_lane_i),
      .cfg_bias_i(cfg_bias_i), .cfg_multiplier_i(cfg_multiplier_i), .cfg_shift_i(cfg_shift_i),
      .valid_in(valid_in), .ready_in(ready_in), .first_k(first_k), .last_k(last_k),
      .k_idx(k_idx), .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
      .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i), .cout_mask_i(cout_mask_i),
      .output_zero_point_i(output_zero_point_i), .activation_min_i(activation_min_i),
      .activation_max_i(activation_max_i), .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
      .param_word0_i(param_word0_i), .param_word1_i(param_word1_i), .param_word2_i(param_word2_i),
      .param_word3_i(param_word3_i), .valid_out(valid_out), .ready_out(1'b0),
      .out_word(out_word), .out_word_mask(out_word_mask), .out_pixel_idx(out_pixel_idx),
      .out_channel_base(out_channel_base), .out_group_idx(out_group_idx),
      .out_block_tag(out_block_tag), .out_mode(out_mode), .busy_o(busy_o));

    always @(posedge clk) if (rst_n) cyc = cyc + 1;

    integer isl, lane;
    initial begin
      repeat (3) @(posedge clk); rst_n = 1;
      for (isl = 0; isl < 2; isl = isl + 1)
        for (lane = 0; lane < 32; lane = lane + 1) begin
          @(negedge clk); cfg_island_i = isl; cfg_lane_i = lane; cfg_valid_i = 1;
          @(posedge clk); #1;
          while (!cfg_ready_o) begin @(negedge clk); @(posedge clk); #1; end
        end
      @(negedge clk); cfg_valid_i = 0;
      /* Four one-token blocks.  The first three should enter; the fourth
       * remains presented while both local result slots are occupied. */
      for (lane = 0; lane < 4; lane = lane + 1) begin
        @(negedge clk); ready_sample = ready_in; block_tag_i = lane; k_idx = 0; first_k = 1; last_k = 1; valid_in = 1;
        @(posedge clk); #1;
        $display("FIFO_BLOCK tag=%0d cyc=%0d ready=%b i0=%b i1=%b valid=%b count=%0d/%0d st=%b/%b last=%b/%b", lane, cyc, ready_in, dut.i0_ready, dut.i1_ready, valid_in, dut.u_island0.result_fifo_count, dut.u_island1.result_fifo_count, dut.u_island0.stage_valid, dut.u_island1.stage_valid, dut.u_island0.stage_last, dut.u_island1.stage_last);
        if (valid_in && ready_sample) begin
          first_cycle[accepted] = cyc; accepted = accepted + 1;
        end
        @(negedge clk); valid_in = 0; first_k = 0; last_k = 0;
      end
      repeat (10) @(posedge clk);
      if (accepted != 3) begin $display("FAIL fifo admission accepted=%0d expected=3", accepted); errors = errors + 1; end
      if (first_cycle[1] - first_cycle[0] > 2 || first_cycle[2] - first_cycle[1] > 2) begin
        $display("FAIL modulo admission cycles %0d %0d %0d", first_cycle[0], first_cycle[1], first_cycle[2]); errors = errors + 1;
      end
      if (errors == 0) $display("PASS dual32_local_island_fifo accepted=%0d first_cycles=%0d,%0d,%0d busy=%b", accepted, first_cycle[0], first_cycle[1], first_cycle[2], busy_o);
      $finish;
    end
endmodule
`default_nettype wire
