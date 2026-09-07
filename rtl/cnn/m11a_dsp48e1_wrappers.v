`timescale 1ns/1ps
`default_nettype none

/*
 * M1.1-A physical arithmetic wrappers.
 *
 * The behavioral branches are deliberately cycle-identical to the Vivado
 * primitives: an enabled input is captured by the DSP P register on one
 * rising edge and the output is visible during the following cycle.  The
 * synthesis branches instantiate DSP48E1 directly so that the K feedback in
 * the INT8 MACs is the primitive's internal P feedback, not a fabric
 * accumulator wrapped around an inferred multiplier.
 */

/* One signed INT8 product with an internal DSP PREG accumulator. */
module m11a_dsp48e1_int8_accum (
    input  wire                     clk,
    input  wire                     rst_p,
    input  wire                     ce,
    input  wire                     clear_acc,
    input  wire signed [7:0]        a_in,
    input  wire signed [7:0]        b_in,
    output wire signed [47:0]       p_out
);
`ifdef SYNTHESIS
    wire signed [29:0] a_dsp = {{22{a_in[7]}}, a_in};
    wire signed [17:0] b_dsp = {{10{b_in[7]}}, b_in};
    /*
     * OPMODE 0000101 selects X=M, Y=0, Z=0 for the first term; OPMODE
     * 0100001 selects X=M, Y=0, Z=P for the recurrence.  OPMODEREG is kept
     * off because clear_acc changes only at a token/tap boundary and the
     * surrounding valid protocol already holds both operands stable.
     */
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .ACASCREG(0), .ADREG(0), .ALUMODEREG(0), .AREG(0), .BREG(0),
        .BCASCREG(0), .CARRYINREG(0), .CREG(0), .DREG(0),
        .INMODEREG(0), .MREG(0), .OPMODEREG(0), .PREG(1)
    ) u_dsp48e1_int8_accum (
        .A(a_dsp), .B(b_dsp), .C(48'd0), .D(25'd0),
        .INMODE(5'b00000),
        .OPMODE(clear_acc ? 7'b0000101 : 7'b0100001),
        .ALUMODE(4'b0000), .CARRYIN(1'b0), .CARRYINSEL(3'b000),
        .CLK(clk), .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0),
        .CEALUMODE(1'b0), .CEB1(1'b0), .CEB2(1'b0), .CEC(1'b0),
        .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
        .CEM(1'b0), .CEP(ce), .RSTA(1'b0), .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTCTRL(1'b0),
        .RSTD(1'b0), .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(rst_p),
        .PCIN(48'd0), .P(p_out), .ACOUT(), .BCOUT(),
        .CARRYCASCIN(1'b0), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNIN(1'b0), .MULTSIGNOUT(), .OVERFLOW(),
        .PATTERNBDETECT(), .PATTERNDETECT(), .PCOUT(), .UNDERFLOW()
    );
`else
    wire signed [47:0] a_ext = {{40{a_in[7]}}, a_in};
    wire signed [47:0] b_ext = {{40{b_in[7]}}, b_in};
    wire signed [47:0] product = a_ext * b_ext;
    reg signed [47:0] p_reg;
    always @(posedge clk) begin
        if (rst_p)
            p_reg <= 48'sd0;
        else if (ce)
            p_reg <= clear_acc ? product : (p_reg + product);
    end
    assign p_out = p_reg;
`endif
endmodule

/* One signed partial product with an internal DSP PREG. */
module m11a_dsp48e1_mul16 (
    input  wire                     clk,
    input  wire                     rst_p,
    input  wire                     ce,
    input  wire signed [24:0]       a_in,
    input  wire signed [17:0]       b_in,
    output wire signed [47:0]       p_out
);
`ifdef SYNTHESIS
    wire signed [29:0] a_dsp = {{5{a_in[24]}}, a_in};
    wire signed [17:0] b_dsp = b_in;
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .ACASCREG(0), .ADREG(0), .ALUMODEREG(0), .AREG(0), .BREG(0),
        .BCASCREG(0), .CARRYINREG(0), .CREG(0), .DREG(0),
        .INMODEREG(0), .MREG(0), .OPMODEREG(0), .PREG(1)
    ) u_dsp48e1_mul16 (
        .A(a_dsp), .B(b_dsp), .C(48'd0), .D(25'd0),
        .INMODE(5'b00000), .OPMODE(7'b0000101), .ALUMODE(4'b0000),
        .CARRYIN(1'b0), .CARRYINSEL(3'b000), .CLK(clk),
        .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEB1(1'b0), .CEB2(1'b0), .CEC(1'b0), .CECARRYIN(1'b0),
        .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
        .CEP(ce), .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTB(1'b0), .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0),
        .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(rst_p), .PCIN(48'd0),
        .P(p_out), .ACOUT(), .BCOUT(), .CARRYCASCIN(1'b0),
        .CARRYCASCOUT(), .CARRYOUT(), .MULTSIGNIN(1'b0),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(),
        .PATTERNDETECT(), .PCOUT(), .UNDERFLOW()
    );
`else
    wire signed [47:0] a_ext = {{23{a_in[24]}}, a_in};
    wire signed [47:0] b_ext = {{30{b_in[17]}}, b_in};
    wire signed [47:0] product = a_ext * b_ext;
    reg signed [47:0] p_reg;
    always @(posedge clk) begin
        if (rst_p)
            p_reg <= 48'sd0;
        else if (ce)
            p_reg <= product;
    end
    assign p_out = p_reg;
`endif
endmodule

/*
 * Exact signed 33x32 product using four signed 16x16 partial products.
 * The accumulator+bias sum is nominally a signed 32-bit value, but retaining
 * the 33rd carry bit avoids changing behavior for the legal endpoint where
 * the two signed 32-bit operands sum outside the 32-bit range.  The low 32
 * bits are decomposed into unsigned-low/signed-high halves.  If the 33rd
 * bit differs from the low-word sign bit, the corresponding +/-2^32*m term
 * is added in fabric; this is only a sign correction, not another multiplier.
 */
module m11a_rq32x32_lane (
    input  wire                     clk,
    input  wire                     rst_p,
    input  wire                     ce,
    input  wire signed [32:0]       x_in,
    input  wire signed [31:0]       m_in,
    output wire signed [64:0]       product_out
);
    wire signed [24:0] x_lo_a = {{8{1'b0}}, 1'b0, x_in[15:0]};
    wire signed [24:0] x_hi_a = {{9{x_in[31]}}, x_in[31:16]};
    wire signed [17:0] m_lo_b = {2'b00, m_in[15:0]};
    wire signed [17:0] m_hi_b = {{2{m_in[31]}}, m_in[31:16]};
    wire signed [47:0] p00, p01, p10, p11;

    m11a_dsp48e1_mul16 u_p00 (
        .clk(clk), .rst_p(rst_p), .ce(ce), .a_in(x_lo_a), .b_in(m_lo_b),
        .p_out(p00)
    );
    m11a_dsp48e1_mul16 u_p01 (
        .clk(clk), .rst_p(rst_p), .ce(ce), .a_in(x_lo_a), .b_in(m_hi_b),
        .p_out(p01)
    );
    m11a_dsp48e1_mul16 u_p10 (
        .clk(clk), .rst_p(rst_p), .ce(ce), .a_in(x_hi_a), .b_in(m_lo_b),
        .p_out(p10)
    );
    m11a_dsp48e1_mul16 u_p11 (
        .clk(clk), .rst_p(rst_p), .ce(ce), .a_in(x_hi_a), .b_in(m_hi_b),
        .p_out(p11)
    );

    wire signed [64:0] p00_ext = {{17{p00[47]}}, p00};
    wire signed [64:0] p01_ext = {{17{p01[47]}}, p01};
    wire signed [64:0] p10_ext = {{17{p10[47]}}, p10};
    wire signed [64:0] p11_ext = {{17{p11[47]}}, p11};
    wire signed [64:0] base_product = p00_ext +
                                       (p01_ext <<< 16) +
                                       (p10_ext <<< 16) +
                                       (p11_ext <<< 32);
    wire signed [64:0] m_ext = {{33{m_in[31]}}, m_in};
    wire signed [64:0] correction_product =
        (x_in[31] && !x_in[32]) ? (m_ext <<< 32) :
        (!x_in[31] && x_in[32]) ? -(m_ext <<< 32) :
        65'sd0;
    assign product_out = base_product + correction_product;
endmodule

/*
 * Four-lane registered requantizer.  Each accepted word uses four lanes x
 * four partial-product DSPs (16 DSP48E1 total).  The metadata and valid bit
 * are held until the output is accepted, so output address/data/context can
 * remain stable under arbitrary backpressure.
 */
module m11a_rq4 (
    input  wire                     clk,
    input  wire                     rst_p,
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire signed [127:0]      acc_bus,
    input  wire signed [127:0]      bias_bus,
    input  wire signed [127:0]      multiplier_bus,
    input  wire [23:0]              shift_bus,
    input  wire signed [31:0]       zero_point,
    input  wire signed [31:0]       activation_min,
    input  wire signed [31:0]       activation_max,
    output wire                     out_valid,
    input  wire                     out_ready,
    output wire [31:0]              out_data
);
    reg valid_r;
    reg operand_valid_r, product_valid_r, rounded_valid_r, shifted_valid_r, q_valid_r;
    reg sat_valid_r;
    reg clamp_valid_r;
    reg signed [31:0] zero_point_r, activation_min_r, activation_max_r;
    reg [23:0] shift_r;
    reg signed [32:0] x_r [0:3];
    reg signed [31:0] multiplier_r [0:3];
    reg signed [64:0] product_r [0:3];
    reg signed [64:0] rounded_r [0:3];
    reg signed [64:0] shifted_r [0:3];
    reg signed [64:0] q_r [0:3];
    reg signed [7:0] sat_r [0:3];
    wire signed [32:0] x_in [0:3];
    wire signed [31:0] m_in [0:3];
    wire signed [64:0] product [0:3];
    integer l;

    assign x_in[0] = {acc_bus[31], acc_bus[31:0]} +
                     {bias_bus[31], bias_bus[31:0]};
    assign x_in[1] = {acc_bus[63], acc_bus[63:32]} +
                     {bias_bus[63], bias_bus[63:32]};
    assign x_in[2] = {acc_bus[95], acc_bus[95:64]} +
                     {bias_bus[95], bias_bus[95:64]};
    assign x_in[3] = {acc_bus[127], acc_bus[127:96]} +
                     {bias_bus[127], bias_bus[127:96]};
    assign m_in[0] = multiplier_bus[31:0];
    assign m_in[1] = multiplier_bus[63:32];
    assign m_in[2] = multiplier_bus[95:64];
    assign m_in[3] = multiplier_bus[127:96];

    wire in_fire = in_valid && in_ready;
    wire out_fire = valid_r && out_ready;
    /* Keep one word in flight and expose explicit register boundaries for
     * product reconstruction, rounding, shifting, addition, and clamping. */
    assign in_ready = !valid_r && !operand_valid_r && !product_valid_r && !rounded_valid_r &&
                      !shifted_valid_r && !q_valid_r && !sat_valid_r && !clamp_valid_r;
    assign out_valid = valid_r;

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : GEN_RQ_LANE
            m11a_rq32x32_lane u_lane (
                .clk(clk), .rst_p(rst_p), .ce(operand_valid_r), .x_in(x_r[g]),
                .m_in(multiplier_r[g]), .product_out(product[g])
            );
        end
    endgenerate

    function automatic signed [64:0] round_product;
        input signed [64:0] product_value;
        reg signed [64:0] magnitude;
        reg signed [64:0] rounded;
        begin
            if (product_value < 0) begin
                magnitude = -product_value;
                rounded = -((magnitude + 65'sd1073741824) >>> 31);
            end else begin
                rounded = (product_value + 65'sd1073741824) >>> 31;
            end
            round_product = rounded;
        end
    endfunction

    /*
     * Split the original 65-bit saturation and activation clamp across two
     * registered stages.  A value fits INT8 exactly when bits [64:7] are a
     * sign extension of bit 7; this avoids a 65-bit carry-chain comparator
     * on the final output-register path while preserving the old ordering:
     * INT8 saturation first, then activation bounds.
     */
    function automatic signed [7:0] saturate_i8;
        input signed [64:0] q_value;
        begin
            if (!q_value[64] && (|q_value[63:7]))
                saturate_i8 = 8'sd127;
            else if (q_value[64] && !(&q_value[63:7]))
                saturate_i8 = -8'sd128;
            else
                saturate_i8 = q_value[7:0];
        end
    endfunction

    function automatic [7:0] clamp_i8;
        input signed [7:0] q_value;
        input signed [31:0] activation_min_value;
        input signed [31:0] activation_max_value;
        reg signed [7:0] q;
        reg signed [7:0] activation_min_i8;
        reg signed [7:0] activation_max_i8;
        begin
            q = q_value;
            if (activation_min_value > 32'sd127)
                activation_min_i8 = 8'sd127;
            else if (activation_min_value < -32'sd128)
                activation_min_i8 = -8'sd128;
            else
                activation_min_i8 = activation_min_value[7:0];
            if (activation_max_value > 32'sd127)
                activation_max_i8 = 8'sd127;
            else if (activation_max_value < -32'sd128)
                activation_max_i8 = -8'sd128;
            else
                activation_max_i8 = activation_max_value[7:0];
            if (q < activation_min_i8) q = activation_min_i8;
            if (q > activation_max_i8) q = activation_max_i8;
            clamp_i8 = q;
        end
    endfunction

    reg [31:0] out_data_r;
    assign out_data = out_data_r;

    always @(posedge clk) begin
        if (rst_p) begin
            valid_r <= 1'b0;
            product_valid_r <= 1'b0;
            rounded_valid_r <= 1'b0;
            shifted_valid_r <= 1'b0;
            q_valid_r <= 1'b0;
            sat_valid_r <= 1'b0;
            clamp_valid_r <= 1'b0;
            zero_point_r <= 32'sd0;
            activation_min_r <= -32'sd128;
            activation_max_r <= 32'sd127;
            shift_r <= 24'd0;
            out_data_r <= 32'd0;
            for (l = 0; l < 4; l = l + 1) begin
                x_r[l] <= 33'sd0;
                multiplier_r[l] <= 32'sd0;
                product_r[l] <= 65'sd0;
                rounded_r[l] <= 65'sd0;
                shifted_r[l] <= 65'sd0;
                q_r[l] <= 65'sd0;
                sat_r[l] <= 8'sd0;
            end
        end else begin
            if (in_fire) begin
                /* The four DSP PREG outputs become available after this
                 * edge; operand_valid_r starts the DSP PREG capture on the
                 * following edge. */
                operand_valid_r <= 1'b1;
                zero_point_r <= zero_point;
                activation_min_r <= activation_min;
                activation_max_r <= activation_max;
                shift_r <= shift_bus;
                for (l = 0; l < 4; l = l + 1) begin
                    x_r[l] <= x_in[l];
                    multiplier_r[l] <= m_in[l];
                end
            end else if (operand_valid_r) begin
                operand_valid_r <= 1'b0;
                product_valid_r <= 1'b1;
            end else if (product_valid_r) begin
                product_valid_r <= 1'b0;
                rounded_valid_r <= 1'b1;
                for (l = 0; l < 4; l = l + 1)
                    product_r[l] <= product[l];
            end else if (rounded_valid_r) begin
                rounded_valid_r <= 1'b0;
                shifted_valid_r <= 1'b1;
                for (l = 0; l < 4; l = l + 1)
                    rounded_r[l] <= round_product(product_r[l]);
            end else if (shifted_valid_r) begin
                shifted_valid_r <= 1'b0;
                q_valid_r <= 1'b1;
                for (l = 0; l < 4; l = l + 1)
                    shifted_r[l] <= rounded_r[l] >>> shift_r[l*6 +: 6];
            end else if (q_valid_r) begin
                q_valid_r <= 1'b0;
                sat_valid_r <= 1'b1;
                for (l = 0; l < 4; l = l + 1)
                    q_r[l] <= shifted_r[l] + zero_point_r;
            end else if (sat_valid_r) begin
                sat_valid_r <= 1'b0;
                clamp_valid_r <= 1'b1;
                for (l = 0; l < 4; l = l + 1)
                    sat_r[l] <= saturate_i8(q_r[l]);
            end else if (clamp_valid_r) begin
                clamp_valid_r <= 1'b0;
                valid_r <= 1'b1;
                out_data_r[7:0] <= clamp_i8(sat_r[0], activation_min_r, activation_max_r);
                out_data_r[15:8] <= clamp_i8(sat_r[1], activation_min_r, activation_max_r);
                out_data_r[23:16] <= clamp_i8(sat_r[2], activation_min_r, activation_max_r);
                out_data_r[31:24] <= clamp_i8(sat_r[3], activation_min_r, activation_max_r);
            end else if (valid_r && out_fire) begin
                valid_r <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
