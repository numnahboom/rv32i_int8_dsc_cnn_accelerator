`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream RQ milestone.
 *
 * This module is deliberately independent of the single-entry
 * edgembconv_hwacandidate_d4_dsp_pool contract.  It instantiates exactly the
 * same sixteen d4_dsp_pool_dsp primitives (four partial products per output
 * lane), but puts the complete requant transaction context in an elastic
 * pipeline.  There is no second RQ multiplier array and no LUT multiplier.
 * The input side can therefore issue one transaction per cycle whenever the
 * output side is able to drain the pipeline.
 *
 * The DSP wrappers have a one-cycle PREG.  pending_ctx is the one-cycle
 * alignment register between that fixed-latency primitive and the first
 * elastic stage.  Every stage below is a standard one-entry ready/valid
 * register: when full it holds both data and all transaction-local context.
 */
module edgembconv_hwacandidate_d4_vstream_elastic_rq_pool #(
    parameter integer STAGE_COUNT = 9
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire signed [127:0]          rq_acc_vec,
    input  wire signed [127:0]          rq_multiplier_vec,
    input  wire [23:0]                  rq_shift_vec,
    input  wire signed [127:0]          rq_zero_point_vec,
    input  wire signed [127:0]           rq_min_vec,
    input  wire signed [127:0]           rq_max_vec,
    input  wire [31:0]                  metadata_in,
    output wire                         valid_out,
    input  wire                         ready_out,
    output wire signed [255:0]           rq_product_vec,
    output wire signed [31:0]            rq_result_vec,
    output wire [31:0]                  metadata_out
);
    localparam integer DSP_COUNT = 16;

    /* The DSP input is always driven by the current request.  It is only
     * considered a transaction when input_fire is asserted. */
    wire input_fire = valid_in && ready_in;
    /* Do not let an unaccepted, backpressured request perturb the DSP PREG.
     * Without this hold, stage zero could pair a pending context with the
     * product of the next request merely because valid_in stayed asserted. */
    reg signed [127:0] last_acc_reg;
    reg signed [127:0] last_multiplier_reg;
    wire signed [127:0] dsp_acc_bus = input_fire ? rq_acc_vec : last_acc_reg;
    wire signed [127:0] dsp_multiplier_bus = input_fire ? rq_multiplier_vec : last_multiplier_reg;
    wire signed [47:0] dsp_p [0:DSP_COUNT-1];
    genvar dg;
    generate
        for (dg = 0; dg < DSP_COUNT; dg = dg + 1) begin : gen_vstream_dsp
            localparam integer LANE = dg / 4;
            localparam integer PART = dg % 4;
            wire [31:0] a_word = dsp_acc_bus[(LANE*32) +: 32];
            wire [31:0] b_word = dsp_multiplier_bus[(LANE*32) +: 32];
            wire [24:0] a_operand = (PART == 0 || PART == 2)
                ? {9'd0, a_word[15:0]}
                : {{9{a_word[31]}}, a_word[31:16]};
            wire [17:0] b_operand = (PART == 0 || PART == 1)
                ? {2'd0, b_word[15:0]}
                : {{2{b_word[31]}}, b_word[31:16]};
            edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp (
                .clk(clk), .rst_n(rst_n), .a_in(a_operand), .b_in(b_operand),
                .p_out(dsp_p[dg])
            );
        end
    endgenerate

    /* Input context is held exactly until its corresponding DSP PREG result
     * reaches stage zero. */
    reg pending_valid;
    reg [23:0] pending_shift;
    reg signed [127:0] pending_zp;
    reg signed [127:0] pending_min;
    reg signed [127:0] pending_max;
    reg [31:0] pending_metadata;

    reg v0, v1, v2, v3, v4, v5, v6, v7, v8;
    wire r8 = !v8 || ready_out;
    wire r7 = !v7 || r8;
    wire r6 = !v6 || r7;
    wire r5 = !v5 || r6;
    wire r4 = !v4 || r5;
    wire r3 = !v3 || r4;
    wire r2 = !v2 || r3;
    wire r1 = !v1 || r2;
    wire r0 = !v0 || r1;
    /* If pending is full, it can be replaced only on the edge where stage
     * zero consumes it.  This is the fixed-latency DSP alignment invariant. */
    assign ready_in = rst_n && (!pending_valid || r0);

    reg [511:0] partial0;
    reg signed [255:0] prod0;
    reg [23:0] shift0;
    reg signed [127:0] zp0, min0, max0;
    reg [31:0] meta0;

    reg signed [255:0] sum_a1, sum_b1;
    reg [23:0] shift1;
    reg signed [127:0] zp1, min1, max1;
    reg [31:0] meta1;

    reg signed [255:0] product2;
    reg [23:0] shift2;
    reg signed [127:0] zp2, min2, max2;
    reg [31:0] meta2;

    reg signed [255:0] magnitude3;
    reg [3:0] negative3;
    reg [23:0] shift3;
    reg signed [127:0] zp3, min3, max3;
    reg [255:0] prod3;
    reg [31:0] meta3;

    reg signed [255:0] round_sum4;
    reg [3:0] negative4;
    reg [23:0] shift4;
    reg signed [127:0] zp4, min4, max4;
    reg [255:0] prod4;
    reg [31:0] meta4;

    reg signed [255:0] shifted5;
    reg [3:0] negative5;
    reg signed [127:0] zp5, min5, max5;
    reg [255:0] prod5;
    reg [31:0] meta5;

    reg signed [255:0] scaled6;
    reg signed [127:0] min6, max6;
    reg [255:0] prod6;
    reg [31:0] meta6;

    reg signed [7:0] candidate7 [0:3];
    reg signed [127:0] min7, max7;
    reg [255:0] prod7;
    reg [31:0] meta7;

    reg signed [7:0] result8 [0:3];
    reg [255:0] prod8;
    reg [31:0] meta8;

    wire signed [63:0] p0 [0:3];
    wire signed [63:0] p1 [0:3];
    wire signed [63:0] p2 [0:3];
    wire signed [63:0] p3 [0:3];
    wire signed [63:0] sa_wire [0:3];
    wire signed [63:0] sb_wire [0:3];
    wire signed [63:0] product_wire [0:3];
    wire signed [63:0] magnitude_wire [0:3];
    wire signed [63:0] round_wire [0:3];
    wire signed [63:0] shifted_wire [0:3];
    wire signed [63:0] scaled_wire [0:3];

    genvar q;
    generate
        for (q = 0; q < 4; q = q + 1) begin : gen_vstream_math
            wire [31:0] pp00_u = partial0[(q*128) + 0*32 +: 32];
            wire signed [31:0] pp01_s = partial0[(q*128) + 1*32 +: 32];
            wire signed [31:0] pp10_s = partial0[(q*128) + 2*32 +: 32];
            wire signed [31:0] pp11_s = partial0[(q*128) + 3*32 +: 32];
            assign p0[q] = $signed({32'd0, pp00_u});
            assign p1[q] = $signed({{32{pp01_s[31]}}, pp01_s}) <<< 16;
            assign p2[q] = $signed({{32{pp10_s[31]}}, pp10_s}) <<< 16;
            assign p3[q] = $signed({{32{pp11_s[31]}}, pp11_s}) <<< 32;
            assign sa_wire[q] = p0[q] + p1[q];
            assign sb_wire[q] = p2[q] + p3[q];
            assign product_wire[q] = sum_a1[(q*64) +: 64] +
                                     sum_b1[(q*64) +: 64];
            assign magnitude_wire[q] = product2[(q*64)+63]
                ? -product2[(q*64) +: 64] : product2[(q*64) +: 64];
            assign round_wire[q] = magnitude3[(q*64) +: 64] +
                ((shift3[(q*6) +: 6] == 0) ? 64'sd0 :
                 (64'sd1 <<< (shift3[(q*6) +: 6] - 1'b1)));
            assign shifted_wire[q] = (shift4[(q*6) +: 6] == 0)
                ? round_sum4[(q*64) +: 64]
                : (round_sum4[(q*64) +: 64] >>> shift4[(q*6) +: 6]);
            assign scaled_wire[q] = (negative5[q]
                ? -shifted5[(q*64) +: 64] : shifted5[(q*64) +: 64]) +
                $signed({{32{zp5[(q*32)+31]}}, zp5[(q*32) +: 32]});
        end
    endgenerate

    function signed [7:0] vstream_candidate;
        input signed [63:0] x;
        begin
            if (x[63:7] != {57{x[63]}})
                vstream_candidate = x[63] ? -8'sd128 : 8'sd127;
            else
                vstream_candidate = x[7:0];
        end
    endfunction

    function signed [7:0] vstream_clamp;
        input signed [7:0] x;
        input signed [31:0] mn;
        input signed [31:0] mx;
        reg signed [31:0] xe;
        begin
            xe = {{24{x[7]}}, x};
            if (xe < mn) vstream_clamp = mn[7:0];
            else if (xe > mx) vstream_clamp = mx[7:0];
            else vstream_clamp = x;
        end
    endfunction

    wire signed [7:0] candidate_wire [0:3];
    wire signed [7:0] result_wire [0:3];
    genvar c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : gen_vstream_clamp
            assign candidate_wire[c] = vstream_candidate(
                scaled6[(c*64) +: 64]);
            assign result_wire[c] = vstream_clamp(candidate7[c],
                min7[(c*32) +: 32], max7[(c*32) +: 32]);
        end
    endgenerate

    assign valid_out = v8;
    assign rq_product_vec = prod8;
    assign rq_result_vec = {result8[3], result8[2], result8[1], result8[0]};
    assign metadata_out = meta8;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending_valid <= 1'b0;
            last_acc_reg <= 128'sd0;
            last_multiplier_reg <= 128'sd0;
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            v4 <= 1'b0; v5 <= 1'b0; v6 <= 1'b0; v7 <= 1'b0; v8 <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                candidate7[i] <= 8'sd0;
                result8[i] <= 8'sd0;
            end
        end else begin
            /* Stage eight is also the external output register. */
            if (r8) begin
                v8 <= v7;
                if (v7) begin
                    for (i = 0; i < 4; i = i + 1)
                        result8[i] <= result_wire[i];
                    prod8 <= prod7;
                    meta8 <= meta7;
                end
            end

            if (r7) begin
                v7 <= v6;
                if (v6) begin
                    for (i = 0; i < 4; i = i + 1)
                        candidate7[i] <= candidate_wire[i];
                    min7 <= min6; max7 <= max6; prod7 <= prod6; meta7 <= meta6;
                end
            end
            if (r6) begin
                v6 <= v5;
                if (v5) begin
                    for (i = 0; i < 4; i = i + 1)
                        scaled6[(i*64) +: 64] <= scaled_wire[i];
                    min6 <= min5; max6 <= max5; prod6 <= prod5; meta6 <= meta5;
                end
            end
            if (r5) begin
                v5 <= v4;
                if (v4) begin
                    for (i = 0; i < 4; i = i + 1)
                        shifted5[(i*64) +: 64] <= shifted_wire[i];
                    negative5 <= negative4; zp5 <= zp4;
                    min5 <= min4; max5 <= max4; prod5 <= prod4; meta5 <= meta4;
                end
            end
            if (r4) begin
                v4 <= v3;
                if (v3) begin
                    for (i = 0; i < 4; i = i + 1)
                        round_sum4[(i*64) +: 64] <= round_wire[i];
                    shift4 <= shift3; negative4 <= negative3;
                    zp4 <= zp3; min4 <= min3; max4 <= max3;
                    prod4 <= prod3; meta4 <= meta3;
                end
            end
            if (r3) begin
                v3 <= v2;
                if (v2) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        magnitude3[(i*64) +: 64] <= magnitude_wire[i];
                        negative3[i] <= product2[(i*64)+63];
                    end
                    shift3 <= shift2; zp3 <= zp2; min3 <= min2; max3 <= max2;
                    prod3 <= product2; meta3 <= meta2;
                end
            end
            if (r2) begin
                v2 <= v1;
                if (v1) begin
                    for (i = 0; i < 4; i = i + 1)
                        product2[(i*64) +: 64] <= product_wire[i];
                    shift2 <= shift1; zp2 <= zp1; min2 <= min1; max2 <= max1;
                    meta2 <= meta1;
                end
            end
            if (r1) begin
                v1 <= v0;
                if (v0) begin
                    for (i = 0; i < 4; i = i + 1) begin
                        sum_a1[(i*64) +: 64] <= sa_wire[i];
                        sum_b1[(i*64) +: 64] <= sb_wire[i];
                    end
                    shift1 <= shift0; zp1 <= zp0; min1 <= min0; max1 <= max0;
                    meta1 <= meta0;
                end
            end
            if (r0) begin
                v0 <= pending_valid;
                if (pending_valid) begin
                    for (i = 0; i < DSP_COUNT; i = i + 1)
                        partial0[(i*32) +: 32] <= dsp_p[i][31:0];
                    shift0 <= pending_shift; zp0 <= pending_zp; min0 <= pending_min;
                    max0 <= pending_max; meta0 <= pending_metadata;
                    prod0 <= 256'd0;
                end
            end

            if (ready_in) begin
                pending_valid <= valid_in;
                if (valid_in) begin
                    last_acc_reg <= rq_acc_vec;
                    last_multiplier_reg <= rq_multiplier_vec;
                    pending_shift <= rq_shift_vec;
                    pending_zp <= rq_zero_point_vec;
                    pending_min <= rq_min_vec;
                    pending_max <= rq_max_vec;
                    pending_metadata <= metadata_in;
                end
            end
        end
    end
endmodule

`default_nettype wire
