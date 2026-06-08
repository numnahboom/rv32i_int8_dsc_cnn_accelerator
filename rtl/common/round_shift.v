`timescale 1ns/1ps
`default_nettype none

module round_shift #(
    parameter WIDTH = 64,
    parameter SHIFT_WIDTH = 6
) (
    input  wire signed [WIDTH-1:0]       value_in,
    input  wire        [SHIFT_WIDTH-1:0] shift,
    output reg  signed [WIDTH-1:0]       value_out
);
    reg signed [WIDTH-1:0] abs_value;
    reg signed [WIDTH-1:0] rounded_abs;
    reg signed [WIDTH-1:0] offset;

    always @(*) begin
        if (shift == {SHIFT_WIDTH{1'b0}}) begin
            value_out = value_in;
        end else begin
            offset = {{(WIDTH-1){1'b0}}, 1'b1} <<< (shift - 1'b1);
            if (value_in >= {WIDTH{1'b0}}) begin
                value_out = (value_in + offset) >>> shift;
            end else begin
                abs_value = -value_in;
                rounded_abs = (abs_value + offset) >>> shift;
                value_out = -rounded_abs;
            end
        end
    end
endmodule

`default_nettype wire
