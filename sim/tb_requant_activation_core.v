`timescale 1ns/1ps
`default_nettype none

module tb_requant_activation_core;
    reg signed [63:0] product;
    reg [5:0] shift;
    reg signed [31:0] zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    wire signed [7:0] output_int8;
    integer errors;

    requant_activation_core dut (
        .product_int64(product), .shift(shift),
        .output_zero_point_int32(zero_point),
        .activation_min_int32(activation_min),
        .activation_max_int32(activation_max),
        .output_int8(output_int8)
    );

    task check;
        input signed [63:0] t_product;
        input [5:0] t_shift;
        input signed [31:0] t_zero_point;
        input signed [31:0] t_min;
        input signed [31:0] t_max;
        input signed [7:0] expected;
        begin
            product = t_product; shift = t_shift; zero_point = t_zero_point;
            activation_min = t_min; activation_max = t_max;
            #1;
            if (output_int8 !== expected) begin
                $display("FAIL product=%0d shift=%0d expected=%0d actual=%0d",
                         t_product, t_shift, expected, output_int8);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        // Q31 positive/negative half ties, and shift=0 post-multiply.
        check(64'sd1073741824, 0, 0, -128, 127, 1);
        check(-64'sd1073741824, 0, 0, -128, 127, -1);
        // Post-shift, zero point, signed extrema and activation clamp.
        check(64'sd4294967296, 1, 3, -128, 127, 4);
        check(64'sh7fffffffffffffff, 0, 0, -128, 127, 127);
        check(-64'sh8000000000000000, 0, 0, -128, 127, -128);
        check(-64'sd12884901888, 0, 0, -5, 6, -5);
        check(64'sd15032385536, 0, 0, -5, 6, 6);
        if (errors == 0) begin
            $display("PASS tb_requant_activation_core cases=7");
            $finish;
        end else begin
            $display("FAIL tb_requant_activation_core errors=%0d", errors);
            $fatal;
        end
    end
endmodule

`default_nettype wire
