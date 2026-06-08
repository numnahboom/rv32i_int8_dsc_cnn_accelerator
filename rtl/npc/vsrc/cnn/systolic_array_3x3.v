`default_nettype none

module systolic_array_3x3(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               load_weight,
    input  wire               enable,
    input  wire               valid_in,
    input  wire signed [71:0] weights,
    input  wire signed [23:0] pixels,
    output wire               valid_out,
    output wire signed [31:0] result
);
    wire signed [7:0] w00 = weights[0*8 +: 8];
    wire signed [7:0] w01 = weights[1*8 +: 8];
    wire signed [7:0] w02 = weights[2*8 +: 8];
    wire signed [7:0] w10 = weights[3*8 +: 8];
    wire signed [7:0] w11 = weights[4*8 +: 8];
    wire signed [7:0] w12 = weights[5*8 +: 8];
    wire signed [7:0] w20 = weights[6*8 +: 8];
    wire signed [7:0] w21 = weights[7*8 +: 8];
    wire signed [7:0] w22 = weights[8*8 +: 8];

    wire signed [7:0] p00 = pixels[0*8 +: 8];
    wire signed [7:0] p01;
    wire signed [7:0] p02;
    wire signed [7:0] p10_0 = pixels[1*8 +: 8];
    wire signed [7:0] p11;
    wire signed [7:0] p12;
    wire signed [7:0] p20_0 = pixels[2*8 +: 8];
    wire signed [7:0] p21;
    wire signed [7:0] p22;

    reg signed [7:0] p10_1, p20_1, p20_2;

    wire v00;
    wire v01;
    wire v02;
    wire v10;
    wire v11;
    wire v12;
    wire v20;
    wire v21;

    wire signed [31:0] psum00;
    wire signed [31:0] psum01;
    wire signed [31:0] psum02;
    wire signed [31:0] psum10;
    wire signed [31:0] psum11;
    wire signed [31:0] psum12;
    wire signed [31:0] psum20; 
    wire signed [31:0] psum21;
    wire signed [31:0] psum22;

    reg signed [31:0] psum20_1, psum20_2, psum21_1;

    always @(posedge clk) begin
        if (!rst_n) begin
            p10_1 <= 8'sd0;
            p20_1 <= 8'sd0;
            p20_2 <= 8'sd0;
            psum20_1 <= 32'sd0;
            psum20_2 <= 32'sd0;
            psum21_1 <= 32'sd0;
        end
        else if (enable) begin
            p10_1 <= p10_0;
            p20_1 <= p20_0;
            p20_2 <= p20_1;
            psum20_1 <= psum20;
            psum20_2 <= psum20_1;
            psum21_1 <= psum21;
        end
    end

    systolic_pe pe00(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(valid_in),
        .weight_in(w00), .pixel_in(p00), .psum_in(32'sd0),
        .valid_out(v00), .psum_out(psum00), .pixel_out(p01)
    );

    systolic_pe pe01(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v00),
        .weight_in(w01), .pixel_in(p01), .psum_in(32'sd0),
        .valid_out(v01), .psum_out(psum01), .pixel_out(p02)
    );

    systolic_pe pe02(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v01),
        .weight_in(w02), .pixel_in(p02), .psum_in(32'sd0),
        .valid_out(v02), .psum_out(psum02), .pixel_out()
    );

    systolic_pe pe10(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v00),
        .weight_in(w10), .pixel_in(p10_1), .psum_in(psum00),
        .valid_out(v10), .psum_out(psum10), .pixel_out(p11)
    );

    systolic_pe pe11(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v10),
        .weight_in(w11), .pixel_in(p11), .psum_in(psum01),
        .valid_out(v11), .psum_out(psum11), .pixel_out(p12)
    );

    systolic_pe pe12(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v11),
        .weight_in(w12), .pixel_in(p12), .psum_in(psum02),
        .valid_out(v12), .psum_out(psum12), .pixel_out()
    );

    systolic_pe pe20(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v10),
        .weight_in(w20), .pixel_in(p20_2), .psum_in(psum10),
        .valid_out(v20), .psum_out(psum20), .pixel_out(p21)
    );

    systolic_pe pe21(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v20),
        .weight_in(w21), .pixel_in(p21), .psum_in(psum11),
        .valid_out(v21), .psum_out(psum21), .pixel_out(p22)
    );

    systolic_pe pe22(
        .clk(clk), .rst_n(rst_n), .load_weight(load_weight),
        .enable(enable), .valid_in(v21),
        .weight_in(w22), .pixel_in(p22), .psum_in(psum12),
        .valid_out(valid_out), .psum_out(psum22), .pixel_out()
    );

    assign result = psum22 + psum21_1 + psum20_2;

endmodule


`default_nettype wire
