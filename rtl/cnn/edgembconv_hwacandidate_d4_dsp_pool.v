`timescale 1ns/1ps
`default_nettype none

/*
 * D4 hardware-aware candidate: one physically shared arithmetic pool.
 *
 * Sixteen DSP48E1 instances are the complete arithmetic pool.  In PW mode
 * every instance performs one signed INT8 x INT8 product per accepted token.
 * In RQ mode the same instances are grouped four-at-a-time; each group
 * computes one exact signed INT32 x INT32 product as four signed/unsigned
 * 16-bit partial products.  The mode is part of the transaction and may only
 * change when the previous output has been accepted (ready_in is low while a
 * result is blocked).  There are deliberately no second RQ multipliers: the
 * only multiplication operators in this hierarchy are the sixteen
 * d4_dsp48e1_mul wrappers, each containing exactly one DSP48E1 under
 * synthesis.
 *
 * The primitive is intentionally a narrow, independently verifiable contract
 * for the D4 mapping.  PW products are exposed to the surrounding 128-MAC
 * output-stationary tile; RQ returns four quantized lanes.  The physical DSP
 * grouping is visible in the synthesis hierarchy and reports.  The isolated
 * contract is single-entry: PW has one-cycle visible latency after the DSP
 * capture, while RQ is deliberately temporal and reports its longer latency
 * in the accompanying testbench/report.
 */
module edgembconv_hwacandidate_d4_dsp_pool (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         mode_rq,
    input  wire                         valid_in,
    output wire                         ready_in,

    input  wire [127:0]                 pw_act_vec,
    input  wire [127:0]                 pw_wgt_vec,

    input  wire signed [127:0]          rq_acc_vec,
    input  wire signed [127:0]          rq_multiplier_vec,
    input  wire [23:0]                  rq_shift_vec,
    input  wire signed [127:0]          rq_zero_point_vec,
    input  wire signed [127:0]          rq_min_vec,
    input  wire signed [127:0]          rq_max_vec,

    input  wire [31:0]                  metadata_in,
    input  wire                         ready_out,
    output reg                          valid_out,
    output reg                          mode_rq_out,
    output reg [255:0]                  pw_product_vec,
    output reg signed [31:0]            rq_product0,
    output reg signed [31:0]            rq_product1,
    output reg signed [31:0]            rq_product2,
    output reg signed [31:0]            rq_product3,
    output reg signed [255:0]           rq_product_vec,
    output reg signed [31:0]            rq_result_vec,
    output reg [31:0]                  metadata_out
);
    localparam integer DSP_COUNT = 16;

    wire input_fire = valid_in && ready_in;

    /*
     * The sixteen DSPs are a single transaction-boundary-switched pool.  A
     * request is accepted only when the complete temporal pipeline is empty;
     * consequently a mode change can never invalidate an in-flight request.
     * This is intentionally a one-entry elastic interface: it sacrifices
     * issue rate in this isolated primitive so that every arithmetic boundary
     * is explicit and can be timed independently.
     */
    reg dsp_pending;
    reg dsp_mode_pending;
    reg [31:0] dsp_metadata_pending;
    reg rq_partial_valid;
    reg rq_sum_valid;
    reg rq_product_valid;
    reg rq_mag_valid;
    reg rq_round_sum_valid;
    reg rq_shifted_valid;
    reg rq_rounded_valid;
    reg rq_scaled_valid;
    /* Saturation is deliberately split into two registered stages.  The
     * first stage only narrows the 64-bit scaled value to the native int8
     * range; the second applies the transaction-local activation min/max.
     * Keeping the candidate and its metadata in registers removes the wide
     * sign/range cone from the output commit boundary. */
    reg rq_clamp_candidate_valid;
    reg rq_result_valid;

    wire pipeline_busy = dsp_pending || rq_partial_valid || rq_sum_valid ||
                          rq_product_valid || rq_mag_valid ||
                          rq_round_sum_valid || rq_shifted_valid ||
                          rq_rounded_valid || rq_scaled_valid ||
                          rq_clamp_candidate_valid ||
                          rq_result_valid;
    assign ready_in = rst_n && !pipeline_busy && (!valid_out || ready_out);

    wire signed [47:0] dsp_p [0:DSP_COUNT-1];

    /* RQ input/partial-product capture.  The coefficient registers are held
     * for the entire transaction, which both documents their association
     * with the four lanes and avoids a coefficient fanout path crossing a
     * stage boundary. */
    reg signed [31:0] rq_partial_reg [0:15];
    reg [5:0] rq_shift_reg [0:3];
    reg signed [31:0] rq_zp_reg [0:3];
    reg signed [31:0] rq_min_reg [0:3];
    reg signed [31:0] rq_max_reg [0:3];
    reg [31:0] rq_metadata_stage;

    /* Partitioned exact INT32xINT32 reconstruction.  Each lane has two
     * registered pair sums followed by a registered final product. */
    reg signed [63:0] rq_sum_a_stage [0:3];
    reg signed [63:0] rq_sum_b_stage [0:3];
    reg signed [63:0] rq_product_stage [0:3];

    /* Fixed-point stages: magnitude -> add half-LSB -> variable shift ->
     * sign restore -> zero-point -> int8 saturation -> output commit. */
    reg signed [63:0] rq_magnitude_stage [0:3];
    reg rq_negative_stage [0:3];
    reg signed [63:0] rq_round_sum_stage [0:3];
    reg signed [63:0] rq_shifted_mag_stage [0:3];
    reg signed [63:0] rq_rounded_stage [0:3];
    reg signed [63:0] rq_scaled_stage [0:3];
    reg signed [7:0] rq_clamp_candidate_stage [0:3];
    reg signed [7:0] rq_result_stage [0:3];
    reg signed [31:0] rq_candidate_min_reg [0:3];
    reg signed [31:0] rq_candidate_max_reg [0:3];
    reg [31:0] rq_candidate_metadata_stage;
    reg [31:0] rq_result_metadata_stage;

    wire signed [63:0] rq_term00 [0:3];
    wire signed [63:0] rq_term01 [0:3];
    wire signed [63:0] rq_term10 [0:3];
    wire signed [63:0] rq_term11 [0:3];
    wire signed [63:0] rq_sum_a_wire [0:3];
    wire signed [63:0] rq_sum_b_wire [0:3];
    wire signed [63:0] rq_product_wire [0:3];
    wire signed [63:0] rq_magnitude_wire [0:3];
    wire signed [63:0] rq_round_sum_wire [0:3];
    wire signed [63:0] rq_shifted_mag_wire [0:3];
    wire signed [63:0] rq_rounded_wire [0:3];
    wire signed [63:0] rq_scaled_wire [0:3];

    genvar dg;
    generate
        for (dg = 0; dg < DSP_COUNT; dg = dg + 1) begin : gen_d4_dsp_pool
            localparam integer RQ_LANE = dg / 4;
            localparam integer RQ_PART = dg % 4;
            wire [31:0] rq_a_word = rq_acc_vec[(RQ_LANE*32) +: 32];
            wire [31:0] rq_b_word = rq_multiplier_vec[(RQ_LANE*32) +: 32];
            /* Lower limbs are unsigned; upper limbs are signed.  The zero
             * top bit on a lower limb is essential: DSP48 multiplication is
             * signed, while this decomposition is two's-complement exact. */
            wire [24:0] rq_a_operand = (RQ_PART == 0 || RQ_PART == 2)
                ? {9'd0, rq_a_word[15:0]}
                : {{9{rq_a_word[31]}}, rq_a_word[31:16]};
            wire [17:0] rq_b_operand = (RQ_PART == 0 || RQ_PART == 1)
                ? {2'd0, rq_b_word[15:0]}
                : {{2{rq_b_word[31]}}, rq_b_word[31:16]};
            wire [24:0] pw_a_operand = {{17{pw_act_vec[(dg*8)+7]}},
                                          pw_act_vec[(dg*8) +: 8]};
            wire [17:0] pw_b_operand = {{10{pw_wgt_vec[(dg*8)+7]}},
                                          pw_wgt_vec[(dg*8) +: 8]};
            /* The mode mux is before the sole physical DSP.  No RQ operator
             * is instantiated alongside the PW operator. */
            wire [24:0] dsp_a_operand = mode_rq ? rq_a_operand : pw_a_operand;
            wire [17:0] dsp_b_operand = mode_rq ? rq_b_operand : pw_b_operand;
            edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp (
                .clk(clk), .rst_n(rst_n), .a_in(dsp_a_operand), .b_in(dsp_b_operand),
                .p_out(dsp_p[dg])
            );
        end
    endgenerate

    genvar qg;
    generate
        for (qg = 0; qg < 4; qg = qg + 1) begin : gen_d4_rq_product
            wire [31:0] pp00_u = rq_partial_reg[qg*4+0];
            wire signed [31:0] pp01_s = rq_partial_reg[qg*4+1];
            wire signed [31:0] pp10_s = rq_partial_reg[qg*4+2];
            wire signed [31:0] pp11_s = rq_partial_reg[qg*4+3];
            wire signed [63:0] pp00 = {32'd0, pp00_u};
            wire signed [63:0] pp01 = $signed({{32{pp01_s[31]}}, pp01_s}) <<< 16;
            wire signed [63:0] pp10 = $signed({{32{pp10_s[31]}}, pp10_s}) <<< 16;
            wire signed [63:0] pp11 = $signed({{32{pp11_s[31]}}, pp11_s}) <<< 32;
            assign rq_term00[qg] = pp00;
            assign rq_term01[qg] = pp01;
            assign rq_term10[qg] = pp10;
            assign rq_term11[qg] = pp11;
            assign rq_sum_a_wire[qg] = rq_term00[qg] + rq_term01[qg];
            assign rq_sum_b_wire[qg] = rq_term10[qg] + rq_term11[qg];
            assign rq_product_wire[qg] = rq_sum_a_stage[qg] + rq_sum_b_stage[qg];
            assign rq_magnitude_wire[qg] = rq_product_stage[qg][63]
                ? -rq_product_stage[qg] : rq_product_stage[qg];
            assign rq_round_sum_wire[qg] = rq_magnitude_stage[qg] +
                ((rq_shift_reg[qg] == 0) ? 64'sd0 :
                 (64'sd1 <<< (rq_shift_reg[qg] - 1'b1)));
            assign rq_shifted_mag_wire[qg] = (rq_shift_reg[qg] == 0)
                ? rq_round_sum_stage[qg]
                : (rq_round_sum_stage[qg] >>> rq_shift_reg[qg]);
            assign rq_rounded_wire[qg] = rq_negative_stage[qg]
                ? -rq_shifted_mag_stage[qg] : rq_shifted_mag_stage[qg];
            assign rq_scaled_wire[qg] = rq_rounded_stage[qg] +
                $signed({{32{rq_zp_reg[qg][31]}}, rq_zp_reg[qg]});
        end
    endgenerate

    function signed [7:0] d4_int8_candidate;
        input signed [63:0] scaled_value;
        reg signed [7:0] clamped_value;
        begin
            /* A signed 64-bit value is in the int8 range iff bits [63:7]
             * are all copies of the sign bit.  This avoids two 64-bit
             * comparators and leaves only the eight useful result bits on
             * the activation-boundary path. */
            if (scaled_value[63:7] != {57{scaled_value[63]}})
                clamped_value = scaled_value[63] ? -8'sd128 : 8'sd127;
            else
                clamped_value = scaled_value[7:0];
            d4_int8_candidate = clamped_value;
        end
    endfunction

    function signed [7:0] d4_apply_activation_clamp;
        input signed [7:0] candidate_value;
        input signed [31:0] min_value;
        input signed [31:0] max_value;
        reg signed [31:0] candidate_ext;
        begin
            candidate_ext = {{24{candidate_value[7]}}, candidate_value};
            if (candidate_ext < min_value)
                d4_apply_activation_clamp = min_value[7:0];
            else if (candidate_ext > max_value)
                d4_apply_activation_clamp = max_value[7:0];
            else
                d4_apply_activation_clamp = candidate_value;
        end
    endfunction

    wire signed [7:0] rq_clamp_candidate_wire [0:3];
    wire signed [7:0] rq_result_wire [0:3];

    genvar qx;
    generate
        for (qx = 0; qx < 4; qx = qx + 1) begin : gen_d4_rq_quant
            assign rq_clamp_candidate_wire[qx] = d4_int8_candidate(
                rq_scaled_stage[qx]);
            assign rq_result_wire[qx] = d4_apply_activation_clamp(
                rq_clamp_candidate_stage[qx], rq_candidate_min_reg[qx],
                rq_candidate_max_reg[qx]);
        end
    endgenerate

    integer oi;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            dsp_pending <= 1'b0;
            dsp_mode_pending <= 1'b0;
            dsp_metadata_pending <= 32'd0;
            rq_partial_valid <= 1'b0;
            rq_sum_valid <= 1'b0;
            rq_product_valid <= 1'b0;
            rq_mag_valid <= 1'b0;
            rq_round_sum_valid <= 1'b0;
            rq_shifted_valid <= 1'b0;
            rq_rounded_valid <= 1'b0;
            rq_scaled_valid <= 1'b0;
            rq_clamp_candidate_valid <= 1'b0;
            rq_result_valid <= 1'b0;
            mode_rq_out <= 1'b0;
            pw_product_vec <= 256'd0;
            rq_product0 <= 32'sd0;
            rq_product1 <= 32'sd0;
            rq_product2 <= 32'sd0;
            rq_product3 <= 32'sd0;
            rq_product_vec <= 256'sd0;
            rq_result_vec <= 32'sd0;
            metadata_out <= 32'd0;
            rq_metadata_stage <= 32'd0;
            rq_candidate_metadata_stage <= 32'd0;
            rq_result_metadata_stage <= 32'd0;
            for (oi = 0; oi < 16; oi = oi + 1)
                rq_partial_reg[oi] <= 32'sd0;
            for (oi = 0; oi < 4; oi = oi + 1) begin
                rq_sum_a_stage[oi] <= 64'sd0;
                rq_sum_b_stage[oi] <= 64'sd0;
                rq_product_stage[oi] <= 64'sd0;
                rq_magnitude_stage[oi] <= 64'sd0;
                rq_negative_stage[oi] <= 1'b0;
                rq_round_sum_stage[oi] <= 64'sd0;
                rq_shifted_mag_stage[oi] <= 64'sd0;
                rq_rounded_stage[oi] <= 64'sd0;
                rq_scaled_stage[oi] <= 64'sd0;
                rq_clamp_candidate_stage[oi] <= 8'sd0;
                rq_result_stage[oi] <= 8'sd0;
                rq_candidate_min_reg[oi] <= -32'sd128;
                rq_candidate_max_reg[oi] <= 32'sd127;
                rq_shift_reg[oi] <= 6'd0;
                rq_zp_reg[oi] <= 32'sd0;
                rq_min_reg[oi] <= -32'sd128;
                rq_max_reg[oi] <= 32'sd127;
            end
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;

            /* Output commit is separate from saturation so the output mux and
             * ready/valid state do not sit on the variable-shift path. */
            if (rq_result_valid) begin
                rq_product_vec[(0*64) +: 64] <= rq_product_stage[0];
                rq_product_vec[(1*64) +: 64] <= rq_product_stage[1];
                rq_product_vec[(2*64) +: 64] <= rq_product_stage[2];
                rq_product_vec[(3*64) +: 64] <= rq_product_stage[3];
                rq_product0 <= rq_product_stage[0][31:0];
                rq_product1 <= rq_product_stage[1][31:0];
                rq_product2 <= rq_product_stage[2][31:0];
                rq_product3 <= rq_product_stage[3][31:0];
                rq_result_vec <= {rq_result_stage[3], rq_result_stage[2],
                                  rq_result_stage[1], rq_result_stage[0]};
                metadata_out <= rq_result_metadata_stage;
                mode_rq_out <= 1'b1;
                valid_out <= 1'b1;
                rq_result_valid <= 1'b0;
            end

            /* Saturation is evaluated only after the scaled value is
             * registered; min/max remain transaction-local metadata. */
            if (rq_scaled_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_clamp_candidate_stage[oi] <= rq_clamp_candidate_wire[oi];
                for (oi = 0; oi < 4; oi = oi + 1) begin
                    rq_candidate_min_reg[oi] <= rq_min_reg[oi];
                    rq_candidate_max_reg[oi] <= rq_max_reg[oi];
                end
                rq_candidate_metadata_stage <= rq_metadata_stage;
                rq_clamp_candidate_valid <= 1'b1;
                rq_scaled_valid <= 1'b0;
            end

            /* The candidate stage has a separate activation-boundary
             * register.  This path now contains only the 8-bit candidate
             * extension and the configured min/max comparisons. */
            if (rq_clamp_candidate_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_result_stage[oi] <= rq_result_wire[oi];
                rq_result_metadata_stage <= rq_candidate_metadata_stage;
                rq_result_valid <= 1'b1;
                rq_clamp_candidate_valid <= 1'b0;
            end

            /* Zero-point addition is its own 64-bit registered stage. */
            if (rq_rounded_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_scaled_stage[oi] <= rq_scaled_wire[oi];
                rq_scaled_valid <= 1'b1;
                rq_rounded_valid <= 1'b0;
            end

            /* Restore the product sign after the variable right shift. */
            if (rq_shifted_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_rounded_stage[oi] <= rq_rounded_wire[oi];
                rq_rounded_valid <= 1'b1;
                rq_shifted_valid <= 1'b0;
            end

            /* Variable shift is isolated from the add-half and sign CPA. */
            if (rq_round_sum_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_shifted_mag_stage[oi] <= rq_shifted_mag_wire[oi];
                rq_shifted_valid <= 1'b1;
                rq_round_sum_valid <= 1'b0;
            end

            /* Nearest-away rounding adds half an LSB to the non-negative
             * magnitude.  The sign is deliberately not folded into this
             * stage, preserving exact negative tie behavior. */
            if (rq_mag_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_round_sum_stage[oi] <= rq_round_sum_wire[oi];
                rq_round_sum_valid <= 1'b1;
                rq_mag_valid <= 1'b0;
            end

            /* Product magnitude extraction is a registered boundary. */
            if (rq_product_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1) begin
                    rq_magnitude_stage[oi] <= rq_magnitude_wire[oi];
                    rq_negative_stage[oi] <= rq_product_stage[oi][63];
                end
                rq_mag_valid <= 1'b1;
                rq_product_valid <= 1'b0;
            end

            /* Final CPA of the two registered partial-product pair sums. */
            if (rq_sum_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1)
                    rq_product_stage[oi] <= rq_product_wire[oi];
                rq_product_valid <= 1'b1;
                rq_sum_valid <= 1'b0;
            end

            /* First level of the partitioned four-term product adder. */
            if (rq_partial_valid) begin
                for (oi = 0; oi < 4; oi = oi + 1) begin
                    rq_sum_a_stage[oi] <= rq_sum_a_wire[oi];
                    rq_sum_b_stage[oi] <= rq_sum_b_wire[oi];
                end
                rq_sum_valid <= 1'b1;
                rq_partial_valid <= 1'b0;
            end

            /* The DSP PREG makes this the capture boundary.  PW commits its
             * sixteen exact INT8 products here; RQ captures the sixteen
             * partial products and then enters the temporal pipeline. */
            if (dsp_pending) begin
                dsp_pending <= 1'b0;
                if (!dsp_mode_pending) begin
                    valid_out <= 1'b1;
                    mode_rq_out <= 1'b0;
                    metadata_out <= dsp_metadata_pending;
                    for (oi = 0; oi < DSP_COUNT; oi = oi + 1)
                        pw_product_vec[(oi*16) +: 16] <= dsp_p[oi][15:0];
                end else begin
                    rq_metadata_stage <= dsp_metadata_pending;
                    for (oi = 0; oi < 16; oi = oi + 1)
                        rq_partial_reg[oi] <= dsp_p[oi][31:0];
                    rq_partial_valid <= 1'b1;
                end
            end

            /* Capture all request metadata at the same edge as the DSP
             * transaction.  These values are never changed until this
             * single in-flight transaction has committed. */
            if (input_fire) begin
                dsp_pending <= 1'b1;
                dsp_mode_pending <= mode_rq;
                dsp_metadata_pending <= metadata_in;
                if (mode_rq) begin
                    for (oi = 0; oi < 4; oi = oi + 1) begin
                        rq_shift_reg[oi] <= rq_shift_vec[(oi*6) +: 6];
                        rq_zp_reg[oi] <= rq_zero_point_vec[(oi*32) +: 32];
                        rq_min_reg[oi] <= rq_min_vec[(oi*32) +: 32];
                        rq_max_reg[oi] <= rq_max_vec[(oi*32) +: 32];
                    end
                end
            end
        end
    end
endmodule

/* Behavioral simulation shell around exactly one physical DSP48E1.  Keeping
 * the primitive in a dedicated module makes post-synthesis hierarchy checks
 * straightforward and avoids a simulator dependency on the Vivado library. */
module edgembconv_hwacandidate_d4_dsp_pool_dsp (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [24:0]                  a_in,
    input  wire [17:0]                  b_in,
    output wire signed [47:0]            p_out
);
`ifdef SYNTHESIS
    wire signed [29:0] a_dsp = {{5{a_in[24]}}, a_in};
    wire signed [17:0] b_dsp = b_in;
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
            .ACASCREG(0), .ADREG(0), .ALUMODEREG(0), .AREG(0), .BREG(0),
            .BCASCREG(0),
        .CARRYINREG(0), .CREG(0), .DREG(0), .INMODEREG(0), .MREG(0),
            .OPMODEREG(0), .PREG(1)
    ) u_dsp48e1 (
        .A(a_dsp), .B(b_dsp), .C(48'd0), .D(25'd0),
        .INMODE(5'b00000), .OPMODE(7'b0000101), .ALUMODE(4'b0000),
        .CARRYIN(1'b0), .CARRYINSEL(3'b000), .CLK(clk),
        .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEB1(1'b0), .CEB2(1'b0), .CEC(1'b0), .CECARRYIN(1'b0),
            .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
            .CEP(1'b1), .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0),
        .RSTB(1'b0), .RSTC(1'b0), .RSTCTRL(1'b0), .RSTD(1'b0),
            .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(!rst_n),
        .P(p_out), .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
        .PCOUT(), .UNDERFLOW()
    );
`else
    /* Match the one-cycle PREG latency used by the physical DSP. */
    reg signed [47:0] p_reg;
    always @(posedge clk) begin
        if (!rst_n)
            p_reg <= 48'sd0;
        else
            p_reg <= $signed(a_in) * $signed(b_in);
    end
    assign p_out = p_reg;
`endif
endmodule

`default_nettype wire
