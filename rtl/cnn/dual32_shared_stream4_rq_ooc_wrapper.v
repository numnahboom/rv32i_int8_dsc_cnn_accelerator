`timescale 1ns/1ps
`default_nettype none
module dual32_shared_stream4_rq_ooc_wrapper (
    input wire clk, input wire rst_n, input wire [1:0] mode_i,
    input wire cfg_valid_i, output wire cfg_ready_o, input wire cfg_island_i,
    input wire [5:0] cfg_lane_i, input wire signed [31:0] cfg_bias_i,
    input wire signed [31:0] cfg_multiplier_i, input wire [5:0] cfg_shift_i,
    input wire valid_in, output wire ready_in, input wire first_k, input wire last_k,
    input wire [7:0] k_idx, input wire [7:0] block_tag_i, input wire [7:0] pixel_base_i,
    input wire [8:0] cout_base_i, input wire [7:0] pixel_mask_i,
    input wire [15:0] cout_mask_i, input wire signed [31:0] output_zero_point_i,
    input wire signed [31:0] activation_min_i, input wire signed [31:0] activation_max_i,
    input wire [31:0] src_word0_i, input wire [31:0] src_word1_i,
    input wire [31:0] param_word0_i, input wire [31:0] param_word1_i,
    input wire [31:0] param_word2_i, input wire [31:0] param_word3_i,
    output wire valid_out, input wire ready_out, output wire [31:0] out_word,
    output wire [3:0] out_word_mask, output wire [7:0] out_pixel_idx,
    output wire [8:0] out_channel_base, output wire [2:0] out_group_idx,
    output wire [7:0] out_block_tag, output wire [1:0] out_mode, output wire busy_o
);
    dual32_shared_stream4_rq u_dut (
      .clk(clk),.rst_n(rst_n),.mode_i(mode_i),.cfg_valid_i(cfg_valid_i),
      .cfg_ready_o(cfg_ready_o),.cfg_island_i(cfg_island_i),.cfg_lane_i(cfg_lane_i),
      .cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),
      .valid_in(valid_in),.ready_in(ready_in),.first_k(first_k),.last_k(last_k),.k_idx(k_idx),
      .block_tag_i(block_tag_i),.pixel_base_i(pixel_base_i),.cout_base_i(cout_base_i),
      .pixel_mask_i(pixel_mask_i),.cout_mask_i(cout_mask_i),
      .output_zero_point_i(output_zero_point_i),.activation_min_i(activation_min_i),
      .activation_max_i(activation_max_i),.src_word0_i(src_word0_i),.src_word1_i(src_word1_i),
      .param_word0_i(param_word0_i),.param_word1_i(param_word1_i),.param_word2_i(param_word2_i),
      .param_word3_i(param_word3_i),.valid_out(valid_out),.ready_out(ready_out),
      .out_word(out_word),.out_word_mask(out_word_mask),.out_pixel_idx(out_pixel_idx),
      .out_channel_base(out_channel_base),.out_group_idx(out_group_idx),
      .out_block_tag(out_block_tag),.out_mode(out_mode),.busy_o(busy_o));
endmodule
`default_nettype wire
