`timescale 1ns/1ps
`default_nettype none

/* Isolated implementation top: exactly one shared core and two registered
 * operand adapters.  This wrapper is not connected to cnn_top. */
module mac16_stream_adapters_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire stem_valid_in, output wire stem_ready_in,
    input wire stem_first_token, input wire stem_last_token,
    input wire [7:0] stem_token_idx, input wire [15:0] stem_lane_mask,
    input wire signed [7:0] stem_act_scalar,
    input wire signed [127:0] stem_weight_vec, input wire stem_ready_out,
    output wire stem_valid_out, output wire [7:0] stem_token_idx_out,
    output wire [15:0] stem_lane_mask_out, output wire signed [511:0] stem_sum_out,
    input wire dw_valid_in, output wire dw_ready_in,
    input wire dw_first_token, input wire dw_last_token,
    input wire [7:0] dw_token_idx, input wire [15:0] dw_lane_mask,
    input wire signed [127:0] dw_act_vec, input wire signed [127:0] dw_weight_vec,
    input wire dw_ready_out, output wire dw_valid_out,
    output wire [7:0] dw_token_idx_out, output wire [15:0] dw_lane_mask_out,
    output wire signed [511:0] dw_sum_out
);
    mac16_stream_shared_wrapper u_shared (.*);
endmodule

`default_nettype wire
