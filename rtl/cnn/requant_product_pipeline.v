`timescale 1ns/1ps
`default_nettype none

// Throughput-one pipelined form of requant_activation_core.  The product is
// supplied by the FC MAC/product register; the staged implementation keeps
// the rounding, shift, offset and clamp carry chains off that register.
module requant_product_pipeline (
    input wire clk, input wire rst_n,
    input wire valid_in,
    input wire signed [63:0] product_int64,
    input wire [5:0] shift,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire [3:0] tag_in,
    output reg valid_out,
    output reg signed [7:0] output_int8,
    output reg [3:0] tag_out
);
    reg valid_s1, valid_s2, valid_s3, valid_s4;
    reg signed [63:0] product_s1;
    reg [5:0] shift_s1;
    reg signed [31:0] zp_s1, min_s1, max_s1;
    reg [3:0] tag_s1;
    reg signed [64:0] fixed_s2;
    reg [5:0] shift_s2;
    reg signed [31:0] zp_s2, min_s2, max_s2;
    reg [3:0] tag_s2;
    reg signed [64:0] shifted_s3;
    reg signed [31:0] zp_s3, min_s3, max_s3;
    reg [3:0] tag_s3;
    reg signed [64:0] value_s4;
    reg signed [31:0] min_s4, max_s4;
    reg [3:0] tag_s4;
    reg signed [64:0] abs_product;
    reg signed [64:0] rounded_abs;
    reg signed [64:0] clamp_value;
    reg signed [64:0] min_ext, max_ext;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1<=0; valid_s2<=0; valid_s3<=0; valid_s4<=0;
            valid_out<=0; output_int8<=0; tag_out<=0;
        end else begin
            valid_s1 <= valid_in;
            valid_s2 <= valid_s1;
            valid_s3 <= valid_s2;
            valid_s4 <= valid_s3;
            valid_out <= valid_s4;
            if (valid_in) begin
                product_s1<=product_int64; shift_s1<=shift;
                zp_s1<=output_zero_point_int32; min_s1<=activation_min_int32;
                max_s1<=activation_max_int32; tag_s1<=tag_in;
            end
            if (valid_s1) begin
                abs_product = product_s1[63] ? -$signed({product_s1[63],product_s1}) : $signed({product_s1[63],product_s1});
                rounded_abs = (abs_product + (65'sd1 <<< 30)) >>> 31;
                fixed_s2 <= product_s1[63] ? -rounded_abs : rounded_abs;
                shift_s2<=shift_s1; zp_s2<=zp_s1; min_s2<=min_s1; max_s2<=max_s1; tag_s2<=tag_s1;
            end
            if (valid_s2) begin
                shifted_s3 <= fixed_s2 >>> shift_s2;
                zp_s3<=zp_s2; min_s3<=min_s2; max_s3<=max_s2; tag_s3<=tag_s2;
            end
            if (valid_s3) begin
                value_s4 <= shifted_s3 + {{33{zp_s3[31]}},zp_s3};
                min_s4<=min_s3; max_s4<=max_s3; tag_s4<=tag_s3;
            end
            if (valid_s4) begin
                clamp_value = value_s4;
                if (clamp_value > 65'sd127) clamp_value=65'sd127;
                else if (clamp_value < -65'sd128) clamp_value=-65'sd128;
                min_ext={{33{min_s4[31]}},min_s4}; max_ext={{33{max_s4[31]}},max_s4};
                if (clamp_value < min_ext) clamp_value=min_ext;
                else if (clamp_value > max_ext) clamp_value=max_ext;
                output_int8<=clamp_value[7:0]; tag_out<=tag_s4;
            end
        end
    end
endmodule
`default_nettype wire
