`timescale 1ns/1ps
`default_nettype none

module saturate_int8 (
    input  wire signed [31:0] value_in,
    output reg  signed [7:0]  value_out
);
    always @(*) begin
        if (value_in > 32'sd127) begin
            value_out = 8'sd127;
        end else if (value_in < -32'sd128) begin
            value_out = -8'sd128;
        end else begin
            value_out = value_in[7:0];
        end
    end
endmodule

`default_nettype wire
