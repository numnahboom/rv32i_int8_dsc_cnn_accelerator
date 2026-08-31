`timescale 1ns/1ps
`default_nettype none

/* Registered PW consumer boundary for a committed spatial-bank stream. */
module ds_spatial_pw_consumer_island (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire first_k, input wire last_k, input wire [7:0] k_idx,
    input wire [7:0] pixel_mask, input wire [7:0] cout_mask,
    input wire signed [63:0] act_vec, input wire signed [63:0] wgt_vec,
    input wire ready_out, output wire valid_out,
    output wire signed [2047:0] psum_out, output wire [63:0] lane_mask_out
);
    /* The direct core registers both operands and metadata before the DSP
     * cells.  No bank address or ownership signal reaches the arithmetic
     * path. */
    pw_direct_8x8_dsp u_core (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask), .act_vec(act_vec),
        .wgt_vec(wgt_vec), .ready_out(ready_out), .valid_out(valid_out),
        .psum_out(psum_out), .lane_mask_out(lane_mask_out)
    );
endmodule
`default_nettype wire
