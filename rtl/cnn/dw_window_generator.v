`timescale 1ns/1ps
`default_nettype none

module dw_window_generator (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              valid_in,
    input  wire signed [7:0] p00,
    input  wire signed [7:0] p01,
    input  wire signed [7:0] p02,
    input  wire signed [7:0] p10,
    input  wire signed [7:0] p11,
    input  wire signed [7:0] p12,
    input  wire signed [7:0] p20,
    input  wire signed [7:0] p21,
    input  wire signed [7:0] p22,
    output reg               valid_out,
    output reg  signed [71:0] window_flat
);
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            window_flat <= 72'sd0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                window_flat[0 +: 8] <= p00;
                window_flat[8 +: 8] <= p01;
                window_flat[16 +: 8] <= p02;
                window_flat[24 +: 8] <= p10;
                window_flat[32 +: 8] <= p11;
                window_flat[40 +: 8] <= p12;
                window_flat[48 +: 8] <= p20;
                window_flat[56 +: 8] <= p21;
                window_flat[64 +: 8] <= p22;
            end
        end
    end
endmodule

`default_nettype wire
