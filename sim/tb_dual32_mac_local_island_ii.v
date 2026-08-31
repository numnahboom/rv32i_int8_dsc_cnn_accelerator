`timescale 1ns/1ps
`default_nettype none
module tb_dual32_mac_local_island_ii;
  reg clk=0; always #5 clk=~clk; reg rst_n=0;
  reg [1:0] mode_i=0,cfg_valid_i=0,cfg_island_i=0; reg [5:0] cfg_lane_i=0;
  reg signed [31:0] cfg_bias_i=3,cfg_multiplier_i=32'sh40000000; reg [5:0] cfg_shift_i=0;
  wire cfg_ready_o; reg valid_in=0,first_k=0,last_k=0; reg [7:0] k_idx=0,block_tag_i=0,pixel_base_i=0,pixel_mask_i=8'hff;
  reg [8:0] cout_base_i=0; reg [15:0] cout_mask_i=16'hffff;
  reg signed [31:0] output_zero_point_i=3,activation_min_i=-128,activation_max_i=127;
  reg [31:0] src_word0_i=32'h01010101,src_word1_i=32'h01010101;
  reg [31:0] param_word0_i=32'h02020202,param_word1_i=32'h03030303,param_word2_i=32'h04040404,param_word3_i=32'h05050505;
  wire ready_in,valid_out,busy_o; wire [31:0] out_word; wire [3:0] out_word_mask; wire [7:0] out_pixel_idx,out_block_tag; wire [8:0] out_channel_base; wire [2:0] out_group_idx; wire [1:0] out_mode;
  integer cyc=0,errors=0,isl,lane,j,accepted,fa,fb; reg rs;
  dual32_mac_local_island dut(.clk(clk),.rst_n(rst_n),.mode_i(mode_i),.cfg_valid_i(cfg_valid_i),.cfg_ready_o(cfg_ready_o),.cfg_island_i(cfg_island_i),.cfg_lane_i(cfg_lane_i),.cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),.valid_in(valid_in),.ready_in(ready_in),.first_k(first_k),.last_k(last_k),.k_idx(k_idx),.block_tag_i(block_tag_i),.pixel_base_i(pixel_base_i),.cout_base_i(cout_base_i),.pixel_mask_i(pixel_mask_i),.cout_mask_i(cout_mask_i),.output_zero_point_i(output_zero_point_i),.activation_min_i(activation_min_i),.activation_max_i(activation_max_i),.src_word0_i(src_word0_i),.src_word1_i(src_word1_i),.param_word0_i(param_word0_i),.param_word1_i(param_word1_i),.param_word2_i(param_word2_i),.param_word3_i(param_word3_i),.valid_out(valid_out),.ready_out(1'b1),.out_word(out_word),.out_word_mask(out_word_mask),.out_pixel_idx(out_pixel_idx),.out_channel_base(out_channel_base),.out_group_idx(out_group_idx),.out_block_tag(out_block_tag),.out_mode(out_mode),.busy_o(busy_o));
  always @(posedge clk) if(rst_n) cyc=cyc+1;
  task measure;
    input [1:0] tm; input integer tk;
    begin
      mode_i=tm; accepted=0; fa=-1; fb=-1; j=0;
      while(j < 2*tk) begin
        @(negedge clk); rs=ready_in; valid_in=1; first_k=(j==0)||(j==tk); last_k=(j==tk-1)||(j==2*tk-1); k_idx=j[7:0]; block_tag_i=(j<tk)?8'h31:8'h32;
        @(posedge clk); #1;
        if(valid_in && rs) begin
          if(j==0) fa=cyc; if(j==tk) fb=cyc; j=j+1; accepted=accepted+1;
        end
      end
      @(negedge clk); valid_in=0; first_k=0; last_k=0;
      while(busy_o) begin @(posedge clk); #1; end
      $display("II_CASE mode=%0d K=%0d accepted=%0d first=%0d second=%0d II=%0d",tm,tk,accepted,fa,fb,fb-fa);
      if(accepted != 2*tk || (fb-fa) > (tk+1)) errors=errors+1;
    end
  endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    for(isl=0;isl<2;isl=isl+1) for(lane=0;lane<32;lane=lane+1) begin @(negedge clk); cfg_island_i=isl;cfg_lane_i=lane;cfg_valid_i=1;@(posedge clk);#1; end
    @(negedge clk); cfg_valid_i=0;
    measure(2'd0,16); measure(2'd0,128); measure(2'd1,27); measure(2'd2,9);
    if(errors==0) $display("PASS dual32_local_island_ii"); else $display("FAIL dual32_local_island_ii errors=%0d",errors); $finish;
  end
endmodule
`default_nettype wire
