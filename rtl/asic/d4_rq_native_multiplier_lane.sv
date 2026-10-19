`timescale 1ns/1ps
`default_nettype none
// ASIC candidate: full signed32 arithmetic, same four-edge valid pipeline and
// clock enables as the inherited FPGA partial-product lane. No precision loss.
module d4_rq_native_multiplier_lane(
    input wire clk, rst_n, in_valid,
    input wire signed [31:0] a, b,
    output reg signed [63:0] product,
    output reg out_valid
);
    reg signed [31:0] a_q, b_q;
    reg signed [63:0] multiply_q, delay_q;
    reg input_valid_q, multiply_valid_q, delay_valid_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            a_q<=0; b_q<=0; multiply_q<=0; delay_q<=0; product<=0;
            input_valid_q<=0; multiply_valid_q<=0; delay_valid_q<=0; out_valid<=0;
        end else begin
            if (in_valid) begin a_q<=a; b_q<=b; end
            if (input_valid_q) multiply_q<=$signed(a_q)*$signed(b_q);
            if (multiply_valid_q) delay_q<=multiply_q;
            if (delay_valid_q) product<=delay_q;
            input_valid_q<=in_valid;
            multiply_valid_q<=input_valid_q;
            delay_valid_q<=multiply_valid_q;
            out_valid<=delay_valid_q;
        end
    end
endmodule
`default_nettype wire
