`timescale 1ns/1ps
`default_nettype none

module dw_line_buffer (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              valid_in,
    input  wire [4:0]        x_idx,
    input  wire signed [7:0] pixel_in,
    output reg  signed [7:0] row0_data,
    output reg  signed [7:0] row1_data,
    output reg  signed [7:0] row2_data
);
    reg signed [7:0] row0 [0:16];
    reg signed [7:0] row1 [0:16];
    reg signed [7:0] row2 [0:16];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            row0_data <= 8'sd0;
            row1_data <= 8'sd0;
            row2_data <= 8'sd0;
            for (i = 0; i < 17; i = i + 1) begin
                row0[i] <= 8'sd0;
                row1[i] <= 8'sd0;
                row2[i] <= 8'sd0;
            end
        end else begin
            if (valid_in && x_idx < 17) begin
                row2[x_idx] <= row1[x_idx];
                row1[x_idx] <= row0[x_idx];
                row0[x_idx] <= pixel_in;
            end
            if (x_idx < 17) begin
                row0_data <= row0[x_idx];
                row1_data <= row1[x_idx];
                row2_data <= row2[x_idx];
            end else begin
                row0_data <= 8'sd0;
                row1_data <= 8'sd0;
                row2_data <= 8'sd0;
            end
        end
    end
endmodule

`default_nettype wire
