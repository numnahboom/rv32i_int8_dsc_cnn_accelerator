`timescale 1ns/1ps
`default_nettype none

/* Four-lane stream requantizer with one sideband mask pipeline.  The four
 * arithmetic lanes are the only DW requant hardware; all metadata is local
 * to this stream and advances only when the elastic lane group advances. */
module requant_activation_stream4_masked (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec,
    input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec,
    input wire [23:0] shift_vec,
    input wire [5:0] pixel_idx, input wire [6:0] channel_idx,
    input wire [3:0] lane_mask,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out, output wire valid_out,
    output wire [5:0] out_pixel_idx,
    output wire [6:0] out_channel_idx,
    output wire [3:0] out_lane_mask,
    output wire signed [31:0] out_data_int8,
    output wire busy
);
    wire inner_ready;
    wire inner_valid;
    wire [5:0] inner_pixel;
    wire [6:0] inner_channel;
    wire signed [31:0] inner_data;
    wire inner_busy;
    reg [3:0] mask_pipe [0:9];
    integer i;

    requant_activation_stream4 u_stream (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(inner_ready),
        .acc_vec(acc_vec), .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec), .pixel_idx(pixel_idx), .channel_idx(channel_idx),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32), .ready_out(ready_out),
        .valid_out(inner_valid), .out_pixel_idx(inner_pixel),
        .out_channel_idx(inner_channel), .out_data_int8(inner_data),
        .busy(inner_busy)
    );
    assign ready_in = inner_ready;
    assign valid_out = inner_valid;
    assign out_pixel_idx = inner_pixel;
    assign out_channel_idx = inner_channel;
    assign out_lane_mask = mask_pipe[9];
    assign out_data_int8 = inner_data;
    assign busy = inner_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 10; i = i + 1) mask_pipe[i] <= 4'd0;
        end else if (inner_ready) begin
            mask_pipe[0] <= valid_in ? lane_mask : 4'd0;
            for (i = 1; i < 10; i = i + 1)
                mask_pipe[i] <= mask_pipe[i-1];
        end
    end
endmodule

`default_nettype wire
