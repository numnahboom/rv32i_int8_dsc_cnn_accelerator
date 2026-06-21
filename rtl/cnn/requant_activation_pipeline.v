`timescale 1ns/1ps
`default_nettype none

module requant_activation_pipeline (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               valid_in,
    input  wire signed [31:0] acc_int32,
    input  wire signed [31:0] bias_int32,
    input  wire signed [31:0] multiplier_int32,
    input  wire        [5:0]  shift,
    input  wire signed [31:0] output_zero_point_int32,
    input  wire signed [31:0] activation_min_int32,
    input  wire signed [31:0] activation_max_int32,

    output reg                valid_out,
    output reg  signed [7:0]  output_int8
);
    reg               valid_s1;
    reg signed [32:0] acc_bias_s1;
    reg signed [31:0] multiplier_s1;
    reg        [5:0]  shift_s1;
    reg signed [31:0] output_zero_point_s1;
    reg signed [31:0] activation_min_s1;
    reg signed [31:0] activation_max_s1;

    reg               valid_s2;
    reg        [32:0] abs_acc_s2;
    reg        [31:0] abs_mul_s2;
    reg               result_sign_s2;
    reg        [5:0]  shift_s2;
    reg signed [31:0] output_zero_point_s2;
    reg signed [31:0] activation_min_s2;
    reg signed [31:0] activation_max_s2;

    reg               valid_s3;
    reg        [31:0] p00_s3;
    reg        [31:0] p01_s3;
    reg        [31:0] p10_s3;
    reg        [31:0] p11_s3;
    reg        [15:0] p20_s3;
    reg        [15:0] p21_s3;
    reg               result_sign_s3;
    reg        [5:0]  shift_s3;
    reg signed [31:0] output_zero_point_s3;
    reg signed [31:0] activation_min_s3;
    reg signed [31:0] activation_max_s3;

    reg               valid_s4;
    reg        [31:0] psum_shift0_s4;
    reg        [32:0] psum_shift16_s4;
    reg        [32:0] psum_shift32_s4;
    reg        [15:0] psum_shift48_s4;
    reg               result_sign_s4;
    reg        [5:0]  shift_s4;
    reg signed [31:0] output_zero_point_s4;
    reg signed [31:0] activation_min_s4;
    reg signed [31:0] activation_max_s4;

    reg               valid_s5;
    reg        [64:0] product_abs_s5;
    reg               result_sign_s5;
    reg        [5:0]  shift_s5;
    reg signed [31:0] output_zero_point_s5;
    reg signed [31:0] activation_min_s5;
    reg signed [31:0] activation_max_s5;

    reg               valid_s6;
    reg        [64:0] product_abs_s6;
    reg               result_sign_s6;
    reg        [5:0]  shift_s6;
    reg signed [31:0] output_zero_point_s6;
    reg signed [31:0] activation_min_s6;
    reg signed [31:0] activation_max_s6;

    reg               valid_s7;
    reg signed [33:0] fixed_mul_s7;
    reg        [5:0]  shift_s7;
    reg signed [31:0] output_zero_point_s7;
    reg signed [31:0] activation_min_s7;
    reg signed [31:0] activation_max_s7;

    reg               valid_s8;
    reg signed [33:0] shifted_s8;
    reg signed [31:0] output_zero_point_s8;
    reg signed [31:0] activation_min_s8;
    reg signed [31:0] activation_max_s8;

    reg               valid_s9;
    reg signed [34:0] zero_point_added_s9;
    reg signed [31:0] activation_min_s9;
    reg signed [31:0] activation_max_s9;

    wire signed [32:0] acc_bias_w;
    wire        [32:0] abs_acc_w;
    wire        [31:0] abs_mul_w;
    wire               result_sign_w;
    wire        [31:0] p00_w;
    wire        [31:0] p01_w;
    wire        [31:0] p10_w;
    wire        [31:0] p11_w;
    wire        [15:0] p20_w;
    wire        [15:0] p21_w;
    wire        [31:0] psum_shift0_w;
    wire        [32:0] psum_shift16_w;
    wire        [32:0] psum_shift32_w;
    wire        [15:0] psum_shift48_w;
    wire        [64:0] product_abs_w;
    wire signed [33:0] fixed_mul_w;
    wire signed [33:0] shifted_w;
    wire signed [34:0] zero_point_added_w;
    wire signed [7:0]  clamped_w;

    assign acc_bias_w = {acc_int32[31], acc_int32} +
                        {bias_int32[31], bias_int32};
    assign abs_acc_w = acc_bias_s1[32]
                     ? ((~acc_bias_s1) + 33'd1)
                     : acc_bias_s1;
    assign abs_mul_w = multiplier_s1[31]
                     ? ((~multiplier_s1) + 32'd1)
                     : multiplier_s1;
    assign result_sign_w = acc_bias_s1[32] ^ multiplier_s1[31];

    assign p00_w = abs_acc_s2[15:0] * abs_mul_s2[15:0];
    assign p01_w = abs_acc_s2[15:0] * abs_mul_s2[31:16];
    assign p10_w = abs_acc_s2[31:16] * abs_mul_s2[15:0];
    assign p11_w = abs_acc_s2[31:16] * abs_mul_s2[31:16];
    assign p20_w = abs_acc_s2[32] ? abs_mul_s2[15:0] : 16'd0;
    assign p21_w = abs_acc_s2[32] ? abs_mul_s2[31:16] : 16'd0;

    assign psum_shift0_w = p00_s3;
    assign psum_shift16_w = {1'b0, p01_s3} + {1'b0, p10_s3};
    assign psum_shift32_w = {1'b0, p11_s3} + {17'd0, p20_s3};
    assign psum_shift48_w = p21_s3;
    assign product_abs_w = {33'd0, psum_shift0_s4} +
                           {16'd0, psum_shift16_s4, 16'd0} +
                           {psum_shift32_s4, 32'd0} +
                           {1'b0, psum_shift48_s4, 48'd0};

    assign fixed_mul_w = round_q31_away_from_zero(
        product_abs_s6,
        result_sign_s6
    );
    assign shifted_w = fixed_mul_s7 >>> shift_s7;
    assign zero_point_added_w =
        $signed({shifted_s8[33], shifted_s8}) +
        $signed({{3{output_zero_point_s8[31]}}, output_zero_point_s8});
    assign clamped_w = saturate_then_clamp_int8(
        zero_point_added_s9,
        activation_min_s9,
        activation_max_s9
    );

    function signed [33:0] round_q31_away_from_zero;
        input [64:0] magnitude;
        input        negative;
        reg   [64:0] rounded_magnitude;
        reg signed [33:0] positive_value;
        begin
            rounded_magnitude = (magnitude + (65'd1 << 30)) >> 31;
            positive_value = $signed(rounded_magnitude[33:0]);
            round_q31_away_from_zero = negative
                                     ? -positive_value
                                     : positive_value;
        end
    endfunction

    function signed [7:0] saturate_then_clamp_int8;
        input signed [34:0] value;
        input signed [31:0] clamp_min;
        input signed [31:0] clamp_max;
        reg signed [34:0] y;
        reg signed [34:0] act_min_ext;
        reg signed [34:0] act_max_ext;
        begin
            if (value > 35'sd127) begin
                y = 35'sd127;
            end else if (value < -35'sd128) begin
                y = -35'sd128;
            end else begin
                y = value;
            end

            act_min_ext = {{3{clamp_min[31]}}, clamp_min};
            act_max_ext = {{3{clamp_max[31]}}, clamp_max};
            if (y < act_min_ext) begin
                y = act_min_ext;
            end else if (y > act_max_ext) begin
                y = act_max_ext;
            end
            saturate_then_clamp_int8 = y[7:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            valid_s2 <= 1'b0;
            valid_s3 <= 1'b0;
            valid_s4 <= 1'b0;
            valid_s5 <= 1'b0;
            valid_s6 <= 1'b0;
            valid_s7 <= 1'b0;
            valid_s8 <= 1'b0;
            valid_s9 <= 1'b0;
            valid_out <= 1'b0;
            output_int8 <= 8'sd0;
        end else begin
            valid_s1 <= valid_in;
            if (valid_in) begin
                acc_bias_s1 <= acc_bias_w;
                multiplier_s1 <= multiplier_int32;
                shift_s1 <= shift;
                output_zero_point_s1 <= output_zero_point_int32;
                activation_min_s1 <= activation_min_int32;
                activation_max_s1 <= activation_max_int32;
            end

            valid_s2 <= valid_s1;
            if (valid_s1) begin
                abs_acc_s2 <= abs_acc_w;
                abs_mul_s2 <= abs_mul_w;
                result_sign_s2 <= result_sign_w;
                shift_s2 <= shift_s1;
                output_zero_point_s2 <= output_zero_point_s1;
                activation_min_s2 <= activation_min_s1;
                activation_max_s2 <= activation_max_s1;
            end

            valid_s3 <= valid_s2;
            if (valid_s2) begin
                p00_s3 <= p00_w;
                p01_s3 <= p01_w;
                p10_s3 <= p10_w;
                p11_s3 <= p11_w;
                p20_s3 <= p20_w;
                p21_s3 <= p21_w;
                result_sign_s3 <= result_sign_s2;
                shift_s3 <= shift_s2;
                output_zero_point_s3 <= output_zero_point_s2;
                activation_min_s3 <= activation_min_s2;
                activation_max_s3 <= activation_max_s2;
            end

            valid_s4 <= valid_s3;
            if (valid_s3) begin
                psum_shift0_s4 <= psum_shift0_w;
                psum_shift16_s4 <= psum_shift16_w;
                psum_shift32_s4 <= psum_shift32_w;
                psum_shift48_s4 <= psum_shift48_w;
                result_sign_s4 <= result_sign_s3;
                shift_s4 <= shift_s3;
                output_zero_point_s4 <= output_zero_point_s3;
                activation_min_s4 <= activation_min_s3;
                activation_max_s4 <= activation_max_s3;
            end

            valid_s5 <= valid_s4;
            if (valid_s4) begin
                product_abs_s5 <= product_abs_w;
                result_sign_s5 <= result_sign_s4;
                shift_s5 <= shift_s4;
                output_zero_point_s5 <= output_zero_point_s4;
                activation_min_s5 <= activation_min_s4;
                activation_max_s5 <= activation_max_s4;
            end

            valid_s6 <= valid_s5;
            if (valid_s5) begin
                product_abs_s6 <= product_abs_s5;
                result_sign_s6 <= result_sign_s5;
                shift_s6 <= shift_s5;
                output_zero_point_s6 <= output_zero_point_s5;
                activation_min_s6 <= activation_min_s5;
                activation_max_s6 <= activation_max_s5;
            end

            valid_s7 <= valid_s6;
            if (valid_s6) begin
                fixed_mul_s7 <= fixed_mul_w;
                shift_s7 <= shift_s6;
                output_zero_point_s7 <= output_zero_point_s6;
                activation_min_s7 <= activation_min_s6;
                activation_max_s7 <= activation_max_s6;
            end

            valid_s8 <= valid_s7;
            if (valid_s7) begin
                shifted_s8 <= shifted_w;
                output_zero_point_s8 <= output_zero_point_s7;
                activation_min_s8 <= activation_min_s7;
                activation_max_s8 <= activation_max_s7;
            end

            valid_s9 <= valid_s8;
            if (valid_s8) begin
                zero_point_added_s9 <= zero_point_added_w;
                activation_min_s9 <= activation_min_s8;
                activation_max_s9 <= activation_max_s8;
            end

            valid_out <= valid_s9;
            if (valid_s9) begin
                output_int8 <= clamped_w;
            end
        end
    end
endmodule

`default_nettype wire
