`timescale 1ns/1ps
`default_nettype none

module requant_activation_vector4_ooc_wrapper (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire signed [2047:0] psum_in,
    input  wire [5:0]           pixel_base,
    input  wire [8:0]           cout_base,
    input  wire [7:0]           output_pixels,
    input  wire [8:0]           output_channels,
    input  wire signed [255:0]  bias_vec,
    input  wire signed [255:0]  multiplier_vec,
    input  wire [47:0]          shift_vec,
    input  wire signed [31:0]   output_zero_point_int32,
    input  wire signed [31:0]   activation_min_int32,
    input  wire signed [31:0]   activation_max_int32,
    output wire [3:0]           valid_out,
    input  wire [3:0]           ready_out,
    output wire [23:0]          out_pixel_idx_vec,
    output wire [31:0]          out_channel_idx_vec,
    output wire signed [31:0]   out_data_int8_vec,
    output wire                 busy
);
    requant_activation_vector4 u_dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .psum_in(psum_in), .pixel_base(pixel_base), .cout_base(cout_base),
        .output_pixels(output_pixels), .output_channels(output_channels),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32), .valid_out(valid_out),
        .ready_out(ready_out), .out_pixel_idx_vec(out_pixel_idx_vec),
        .out_channel_idx_vec(out_channel_idx_vec),
        .out_data_int8_vec(out_data_int8_vec), .busy(busy)
    );
endmodule

`default_nettype wire
