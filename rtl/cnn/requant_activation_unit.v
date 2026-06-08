`timescale 1ns/1ps
`default_nettype none

module requant_activation_unit (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               valid_in,
    output wire               ready_in,

    input  wire signed [31:0] acc_int32,
    input  wire signed [31:0] bias_int32,
    input  wire signed [31:0] multiplier_int32,
    input  wire        [5:0]  shift,

    input  wire signed [31:0] output_zero_point_int32,
    input  wire signed [31:0] activation_min_int32,
    input  wire signed [31:0] activation_max_int32,

    input  wire               ready_out,
    output reg                valid_out,
    output reg  signed [7:0]  output_int8
);
    reg                valid_s1;
    reg                valid_s2;
    reg signed [63:0] product_s1;
    reg        [5:0]  shift_s1;
    reg signed [31:0] output_zero_point_s1;
    reg signed [31:0] activation_min_s1;
    reg signed [31:0] activation_max_s1;
    reg signed [63:0] shifted_s2;
    reg signed [31:0] output_zero_point_s2;
    reg signed [31:0] activation_min_s2;
    reg signed [31:0] activation_max_s2;

    wire ready_s1;
    wire ready_s2;
    wire ready_s3;
    wire signed [63:0] acc_bias_w;
    wire signed [63:0] product_w;
    wire signed [63:0] fixed_mul_w;
    wire signed [63:0] shifted_after_mul_w;
    wire signed [63:0] zero_point_added_w;

    assign ready_s3 = (!valid_out) || ready_out;
    assign ready_s2 = (!valid_s2) || ready_s3;
    assign ready_s1 = (!valid_s1) || ready_s2;
    assign ready_in = ready_s1;

    assign acc_bias_w = {{32{acc_int32[31]}}, acc_int32} +
                        {{32{bias_int32[31]}}, bias_int32};
    assign product_w = acc_bias_w * {{32{multiplier_int32[31]}}, multiplier_int32};
    assign fixed_mul_w = round_shift_s64(product_s1, 6'd31);
    assign shifted_after_mul_w = fixed_mul_w >>> shift_s1;
    assign zero_point_added_w = shifted_s2 +
                                {{32{output_zero_point_s2[31]}}, output_zero_point_s2};

    function signed [63:0] round_shift_s64;
        input signed [63:0] value;
        input        [5:0]  shift_amount;
        reg signed [63:0] abs_value;
        reg signed [63:0] rounded_abs;
        reg signed [63:0] offset;
        begin
            if (shift_amount == 6'd0) begin
                round_shift_s64 = value;
            end else begin
                offset = 64'sd1 <<< (shift_amount - 6'd1);
                if (value >= 64'sd0) begin
                    round_shift_s64 = (value + offset) >>> shift_amount;
                end else begin
                    abs_value = -value;
                    rounded_abs = (abs_value + offset) >>> shift_amount;
                    round_shift_s64 = -rounded_abs;
                end
            end
        end
    endfunction

    /* verilator lint_off BLKSEQ */
    function signed [7:0] saturate_then_clamp_int8;
        input signed [63:0] value;
        input signed [31:0] activation_min;
        input signed [31:0] activation_max;
        reg signed [63:0] y;
        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        begin
            if (value > 64'sd127) begin
                y = 64'sd127;
            end else if (value < -64'sd128) begin
                y = -64'sd128;
            end else begin
                y = value;
            end

            act_min_ext = {{32{activation_min[31]}}, activation_min};
            act_max_ext = {{32{activation_max[31]}}, activation_max};
            if (y < act_min_ext) begin
                y = act_min_ext;
            end else if (y > act_max_ext) begin
                y = act_max_ext;
            end
            saturate_then_clamp_int8 = y[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            valid_s2 <= 1'b0;
            valid_out <= 1'b0;
            product_s1 <= 64'sd0;
            shift_s1 <= 6'd0;
            output_zero_point_s1 <= 32'sd0;
            activation_min_s1 <= 32'sd0;
            activation_max_s1 <= 32'sd0;
            shifted_s2 <= 64'sd0;
            output_zero_point_s2 <= 32'sd0;
            activation_min_s2 <= 32'sd0;
            activation_max_s2 <= 32'sd0;
            output_int8 <= 8'sd0;
        end else begin
            if (ready_s1) begin
                valid_s1 <= valid_in;
                if (valid_in) begin
                    product_s1 <= product_w;
                    shift_s1 <= shift;
                    output_zero_point_s1 <= output_zero_point_int32;
                    activation_min_s1 <= activation_min_int32;
                    activation_max_s1 <= activation_max_int32;
                end
            end

            if (ready_s2) begin
                valid_s2 <= valid_s1;
                if (valid_s1) begin
                    shifted_s2 <= shifted_after_mul_w;
                    output_zero_point_s2 <= output_zero_point_s1;
                    activation_min_s2 <= activation_min_s1;
                    activation_max_s2 <= activation_max_s1;
                end
            end

            if (ready_s3) begin
                valid_out <= valid_s2;
                if (valid_s2) begin
                    output_int8 <= saturate_then_clamp_int8(
                        zero_point_added_w,
                        activation_min_s2,
                        activation_max_s2
                    );
                end
            end
        end
    end
endmodule

`default_nettype wire
