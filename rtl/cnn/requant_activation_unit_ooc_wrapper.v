`timescale 1ns/1ps
`default_nettype none

// Isolated timing wrapper: every DUT input is source-registered and every
// DUT output is sink-registered.  The timing result therefore measures the
// requantizer datapath rather than unconstrained top-level I/O paths.
module requant_activation_unit_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire valid_in,
    input wire signed [31:0] acc_int32, bias_int32, multiplier_int32,
    input wire [5:0] shift,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    output reg valid_out,
    output reg signed [7:0] output_int8
);
    reg src_valid;
    reg signed [31:0] src_acc, src_bias, src_multiplier;
    reg [5:0] src_shift;
    reg signed [31:0] src_zp, src_min, src_max;
    wire core_ready;
    wire core_valid;
    wire signed [7:0] core_output;

    always @(posedge clk) begin
        if (!rst_n) begin
            src_valid <= 1'b0;
            src_acc <= 0; src_bias <= 0; src_multiplier <= 0;
            src_shift <= 0; src_zp <= 0; src_min <= -128; src_max <= 127;
            valid_out <= 1'b0; output_int8 <= 0;
        end else begin
            src_valid <= valid_in;
            if (valid_in) begin
                src_acc <= acc_int32; src_bias <= bias_int32;
                src_multiplier <= multiplier_int32; src_shift <= shift;
                src_zp <= output_zero_point_int32;
                src_min <= activation_min_int32;
                src_max <= activation_max_int32;
            end
            valid_out <= core_valid;
            if (core_valid) output_int8 <= core_output;
        end
    end

    requant_activation_unit u_core (
        .clk(clk), .rst_n(rst_n), .valid_in(src_valid), .ready_in(core_ready),
        .acc_int32(src_acc), .bias_int32(src_bias),
        .multiplier_int32(src_multiplier), .shift(src_shift),
        .output_zero_point_int32(src_zp),
        .activation_min_int32(src_min), .activation_max_int32(src_max),
        .ready_out(1'b1), .valid_out(core_valid), .output_int8(core_output)
    );
endmodule

`default_nettype wire
