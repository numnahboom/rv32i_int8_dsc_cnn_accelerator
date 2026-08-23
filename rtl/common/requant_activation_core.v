`timescale 1ns/1ps
`default_nettype none

// Combinational requantization definition shared by sequential wrappers.
// The product input is the signed (acc + bias) * multiplier value.  Rounding
// is Q31, half away from zero, followed by the post-multiply shift, zero-point
// addition, int8 saturation, and activation clamp in that order.
module requant_activation_core (
    input  wire signed [63:0] product_int64,
    input  wire        [5:0]  shift,
    input  wire signed [31:0] output_zero_point_int32,
    input  wire signed [31:0] activation_min_int32,
    input  wire signed [31:0] activation_max_int32,
    output wire signed [7:0]  output_int8
);
    reg signed [64:0] fixed_mul;
    reg signed [64:0] shifted;
    reg signed [64:0] value;
    reg signed [64:0] act_min_ext;
    reg signed [64:0] act_max_ext;
    reg signed [64:0] abs_value;
    reg signed [64:0] rounded_abs;
    reg signed [64:0] offset;
    reg signed [7:0]  result;

    always @(*) begin
        abs_value = 65'sd0;
        rounded_abs = 65'sd0;
        shifted = 65'sd0;
        value = 65'sd0;
        act_min_ext = 65'sd0;
        act_max_ext = 65'sd0;
        result = 8'sd0;
        // The multiplier is Q31; its rounding shift is fixed at 31 bits.
        // The programmable shift below is only the post-multiply shift.
        offset = 65'sd1 <<< 30;
        abs_value = -$signed({product_int64[63], product_int64});
        if (product_int64 >= 64'sd0) begin
            fixed_mul = ($signed({product_int64[63], product_int64}) + offset) >>> 31;
        end else begin
            rounded_abs = (abs_value + offset) >>> 31;
            fixed_mul = -rounded_abs;
        end

        shifted = fixed_mul >>> shift;
        value = shifted + {{33{output_zero_point_int32[31]}},
                           output_zero_point_int32};
        if (value > 65'sd127) begin
            value = 65'sd127;
        end else if (value < -65'sd128) begin
            value = -65'sd128;
        end

        act_min_ext = {{33{activation_min_int32[31]}}, activation_min_int32};
        act_max_ext = {{33{activation_max_int32[31]}}, activation_max_int32};
        if (value < act_min_ext) begin
            value = act_min_ext;
        end else if (value > act_max_ext) begin
            value = act_max_ext;
        end
        result = value[7:0];
    end

    assign output_int8 = result;
endmodule

`default_nettype wire
