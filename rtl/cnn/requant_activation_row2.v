`timescale 1ns/1ps
`default_nettype none

/*
 * Narrow, row-aware two-lane requantizer.
 *
 * The input is one adjacent pair from an 8-value row.  Four accepted beats
 * therefore cover one complete row, and the row/beat tag travels with the
 * ten-stage exact requant pipeline.  This intentionally has no wide result
 * bundle or result FIFO: a consumer accepts two scalar values per transfer
 * and backpressure freezes the whole arithmetic/tag pipeline.
 */
module requant_activation_row2 (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire signed [63:0]   acc_vec,
    input  wire signed [63:0]   bias_vec,
    input  wire signed [63:0]   multiplier_vec,
    input  wire [11:0]          shift_vec,
    input  wire [2:0]           row_idx,
    input  wire [1:0]           beat_idx,
    input  wire [5:0]           pixel_base,
    input  wire [8:0]           cout_base,
    input  wire [1:0]           lane_mask,
    input  wire signed [31:0]   output_zero_point_int32,
    input  wire signed [31:0]   activation_min_int32,
    input  wire signed [31:0]   activation_max_int32,
    input  wire                 ready_out,
    output wire                 valid_out,
    output wire [2:0]           out_row_idx,
    output wire [1:0]           out_beat_idx,
    output wire [5:0]           out_pixel_idx,
    output wire [8:0]           out_channel_base,
    output wire [1:0]           out_lane_mask,
    output wire signed [15:0]   out_data,
    output wire                 busy
);
    wire [6:0] item_idx = {row_idx, beat_idx, 1'b0};
    wire [6:0] rq_item;
    wire [5:0] rq_pixel_base;
    wire [8:0] rq_cout_base;
    wire [1:0] rq_mask;
    wire signed [15:0] rq_data;

    /* The existing exact two-lane arithmetic is reused at its narrow ABI.
     * No 2048-bit value crosses this module boundary. */
    requant_activation_stream2 u_stream2 (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .acc_vec(acc_vec), .bias_vec(bias_vec),
        .multiplier_vec(multiplier_vec), .shift_vec(shift_vec),
        .item_idx(item_idx), .pixel_base(pixel_base), .cout_base(cout_base),
        .lane_mask(lane_mask),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .ready_out(ready_out), .valid_out(valid_out),
        .out_item_idx(rq_item), .out_pixel_base(rq_pixel_base),
        .out_cout_base(rq_cout_base), .out_lane_mask(rq_mask),
        .out_data_int8(rq_data), .busy(busy)
    );

    assign out_row_idx = rq_item[6:3];
    assign out_beat_idx = rq_item[2:1];
    assign out_pixel_idx = rq_pixel_base + rq_item[6:3];
    assign out_channel_base = rq_cout_base + (rq_item[2:1] << 1);
    assign out_lane_mask = rq_mask;
    assign out_data = rq_data;
endmodule

`default_nettype wire
