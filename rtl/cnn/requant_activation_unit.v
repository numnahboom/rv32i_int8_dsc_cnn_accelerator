`timescale 1ns/1ps
`default_nettype none

/* Ten-stage, throughput-one requantizer with a globally stalled elastic
 * pipeline.  All valid/data stages freeze together when ready_out is low. */
module requant_activation_unit #(
    /* Optional physical min-delay stage used by the isolated unified64
     * requant lane.  The default keeps every existing production caller
     * bit-identical and free of extra logic. */
    parameter integer HOLD_BUFFER = 0
) (
    input wire clk, (* max_fanout = 500 *) input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [31:0] acc_int32, input wire signed [31:0] bias_int32,
    input wire signed [31:0] multiplier_int32, input wire [5:0] shift,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out, output wire valid_out,
    output wire signed [7:0] output_int8
);
    reg [9:0] v;
    wire advance = !v[9] || ready_out;
    assign ready_in = advance;
    assign valid_out = v[9];

    reg signed [32:0] acc_s0;
    /* Keep a local copy for each of the four DSP product terms.  This
     * prevents one multiplier bit from becoming a cross-DSP high-fanout
     * source after placement. */
    (* keep = "true" *) reg signed [31:0] mul_s0_00;
    (* keep = "true" *) reg signed [31:0] mul_s0_01;
    (* keep = "true" *) reg signed [31:0] mul_s0_10;
    (* keep = "true" *) reg signed [31:0] mul_s0_11;
    reg signed [31:0] zp_pipe [0:9];
    reg signed [31:0] min_pipe [0:9];
    reg signed [31:0] max_pipe [0:9];
    reg [5:0] shift_pipe [0:9];

    reg [32:0] p00_s1;
    reg signed [32:0] p01_s1;
    reg signed [31:0] p10_s1;
    reg signed [31:0] p11_s1;
    reg [63:0] csa_sum_s2, csa_carry_s2;
    reg [31:0] low_s3, high_sum_s3, high_carry_s3, low_s4, high_s4;
    reg low_carry_s3;
    reg signed [33:0] fixed_s5, shifted_low_s6, shifted_high_s7;
    reg signed [34:0] zp_added_s8;
    reg signed [7:0] out_s9;
    assign output_int8 = out_s9;

    wire signed [32:0] acc_bias_in =
        {acc_int32[31],acc_int32} + {bias_int32[31],bias_int32};
    wire [16:0] alo_u17 = acc_s0[16:0];
    wire signed [15:0] ahi_s16 = acc_s0[32:17];
    wire [15:0] blo_u16_00 = mul_s0_00[15:0];
    wire signed [15:0] bhi_s16_01 = mul_s0_01[31:16];
    wire [15:0] blo_u16_10 = mul_s0_10[15:0];
    wire signed [15:0] bhi_s16_11 = mul_s0_11[31:16];
    /* Explicitly widen the expression operands: Verilog otherwise sizes a
     * multiply to max(width(left),width(right)) and silently drops the upper
     * product bits.  The leading zeros/sign bits are trimmed by synthesis,
     * leaving the intended 17x16, 17x16, 16x16 and 16x16 DSP operations. */
    wire [32:0] p00_w = {16'd0,alo_u17} * {17'd0,blo_u16_00};
    wire signed [32:0] p01_w = $signed({16'd0,alo_u17}) *
                                $signed({{17{bhi_s16_01[15]}},bhi_s16_01});
    wire signed [31:0] p10_w = $signed({{16{ahi_s16[15]}},ahi_s16}) *
                                $signed({17'd0,blo_u16_10});
    wire signed [31:0] p11_w = $signed({{16{ahi_s16[15]}},ahi_s16}) *
                                $signed({{16{bhi_s16_11[15]}},bhi_s16_11});

    /* Two carry-save compressors, followed by split low/high CPA stages. */
    wire [63:0] term00 = {31'd0,p00_s1};
    wire [63:0] term01 = {{31{p01_s1[32]}},p01_s1} << 16;
    wire [63:0] term10 = {{32{p10_s1[31]}},p10_s1} << 17;
    wire [63:0] term11 = {{32{p11_s1[31]}},p11_s1} << 33;
    wire [63:0] csa1_sum = term00 ^ term01 ^ term10;
    wire [63:0] csa1_carry =
        ((term00 & term01) | (term00 & term10) | (term01 & term10)) << 1;
    wire [63:0] csa2_sum = csa1_sum ^ csa1_carry ^ term11;
    wire [63:0] csa2_carry =
        ((csa1_sum & csa1_carry) | (csa1_sum & term11) |
         (csa1_carry & term11)) << 1;
    wire [32:0] low_cpa = {1'b0,csa_sum_s2[31:0]} +
                          {1'b0,csa_carry_s2[31:0]};
    wire [32:0] high_cpa_s3 = {1'b0,high_sum_s3} +
                              {1'b0,high_carry_s3} + low_carry_s3;

    wire signed [64:0] product_ext_s4 = {high_s4[31],high_s4,low_s4};
    wire product_negative = product_ext_s4[64];
    // Derive the magnitude slices without a 65-bit negate chain.  For a
    // negative two's-complement value, the upper slice receives a carry only
    // when all lower 31 bits were zero.
    wire low_zero = (product_ext_s4[30:0] == 31'd0);
    wire round_up = product_negative
        ? (product_ext_s4[30]
           ? low_zero || (product_ext_s4[29:0] == 30'd0)
           : !low_zero)
        : (product_ext_s4[30:0] >= 31'h40000000);
    // Fold sign application into the same 34-bit CPA.  For a negative
    // magnitude, -(upper+round) == ~upper + (1-round), avoiding a second
    // 34-bit negate chain in the S5 timing cone.
    // For negative p, -(abs(p>>31)+round) is upper + (1-carry-round),
    // where carry is the low-slice zero carry.  This keeps S5 to one CPA.
    wire [33:0] round_addend = product_negative
        ? (low_zero && round_up ? {34{1'b1}} :
           (low_zero || round_up ? 34'd0 : 34'd1))
        : {{33{1'b0}},round_up};
    wire signed [33:0] fixed_w = $signed(product_ext_s4[64:31] + round_addend);
    wire signed [33:0] shifted_low_w = fixed_s5 >>> shift_pipe[5][2:0];
    wire signed [33:0] shifted_high_w_raw =
        shifted_low_s6 >>> {shift_pipe[6][5:3],3'b000};
    wire signed [33:0] shifted_high_w_buf;
    genvar hb;
    generate if (HOLD_BUFFER != 0) begin : gen_hold_buffer
        for (hb=0; hb<34; hb=hb+1) begin : gen_hold_bit
`ifdef SYNTHESIS
            (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_hold_buf
                (.I0(shifted_high_w_raw[hb]), .O(shifted_high_w_buf[hb]));
`else
            assign shifted_high_w_buf[hb] = shifted_high_w_raw[hb];
`endif
        end
    end else begin : gen_no_hold_buffer
        assign shifted_high_w_buf = shifted_high_w_raw;
    end endgenerate
    wire signed [33:0] shifted_high_w = shifted_high_w_buf;
    wire signed [34:0] zp_added_w =
        $signed({shifted_high_s7[33],shifted_high_s7}) +
        $signed({{3{zp_pipe[7][31]}},zp_pipe[7]});

    /* verilator lint_off BLKSEQ */
    function signed [7:0] clamp_int8;
        input signed [34:0] value;
        input signed [31:0] clamp_min, clamp_max;
        reg signed [34:0] y, mn, mx;
        begin
            if (value > 35'sd127) y = 35'sd127;
            else if (value < -35'sd128) y = -35'sd128;
            else y = value;
            mn = {{3{clamp_min[31]}},clamp_min};
            mx = {{3{clamp_max[31]}},clamp_max};
            if (y < mn) y = mn;
            else if (y > mx) y = mx;
            clamp_int8 = y[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            v <= 10'b0; acc_s0 <= 33'sd0;
            mul_s0_00 <= 32'sd0; mul_s0_01 <= 32'sd0;
            mul_s0_10 <= 32'sd0; mul_s0_11 <= 32'sd0;
            p00_s1 <= 33'd0; p01_s1 <= 33'sd0; p10_s1 <= 32'sd0; p11_s1 <= 32'sd0;
            csa_sum_s2 <= 64'd0; csa_carry_s2 <= 64'd0;
            low_s3 <= 32'd0; low_carry_s3 <= 1'b0;
            high_sum_s3 <= 32'd0; high_carry_s3 <= 32'd0;
            low_s4 <= 32'd0; high_s4 <= 32'd0; fixed_s5 <= 34'sd0;
            shifted_low_s6 <= 34'sd0; shifted_high_s7 <= 34'sd0;
            zp_added_s8 <= 35'sd0; out_s9 <= 8'sd0;
            for (i=0; i<10; i=i+1) begin
                zp_pipe[i] <= 32'sd0; min_pipe[i] <= 32'sd0;
                max_pipe[i] <= 32'sd0; shift_pipe[i] <= 6'd0;
            end
        end else begin
            if (advance) begin
                v[0] <= valid_in; v[1] <= v[0]; v[2] <= v[1];
                if (valid_in) begin
                    acc_s0 <= acc_bias_in;
                    mul_s0_00 <= multiplier_int32; mul_s0_01 <= multiplier_int32;
                    mul_s0_10 <= multiplier_int32; mul_s0_11 <= multiplier_int32;
                    zp_pipe[0] <= output_zero_point_int32;
                    min_pipe[0] <= activation_min_int32;
                    max_pipe[0] <= activation_max_int32; shift_pipe[0] <= shift;
                end
                if (v[0]) begin p00_s1 <= p00_w; p01_s1 <= p01_w;
                    p10_s1 <= p10_w; p11_s1 <= p11_w; end
                if (v[1]) begin csa_sum_s2 <= csa2_sum; csa_carry_s2 <= csa2_carry; end
                if (v[0]) begin zp_pipe[1] <= zp_pipe[0]; min_pipe[1] <= min_pipe[0];
                    max_pipe[1] <= max_pipe[0]; shift_pipe[1] <= shift_pipe[0]; end
                if (v[1]) begin zp_pipe[2] <= zp_pipe[1]; min_pipe[2] <= min_pipe[1];
                    max_pipe[2] <= max_pipe[1]; shift_pipe[2] <= shift_pipe[1]; end
            end
            if (advance) begin
                v[3] <= v[2]; v[4] <= v[3]; v[5] <= v[4];
                if (v[2]) begin
                    low_s3 <= low_cpa[31:0]; low_carry_s3 <= low_cpa[32];
                    high_sum_s3 <= csa_sum_s2[63:32]; high_carry_s3 <= csa_carry_s2[63:32];
                end
                if (v[3]) begin low_s4 <= low_s3; high_s4 <= high_cpa_s3[31:0]; end
                if (v[4]) fixed_s5 <= fixed_w;
                if (v[2]) begin zp_pipe[3] <= zp_pipe[2]; min_pipe[3] <= min_pipe[2];
                    max_pipe[3] <= max_pipe[2]; shift_pipe[3] <= shift_pipe[2]; end
                if (v[3]) begin zp_pipe[4] <= zp_pipe[3]; min_pipe[4] <= min_pipe[3];
                    max_pipe[4] <= max_pipe[3]; shift_pipe[4] <= shift_pipe[3]; end
                if (v[4]) begin zp_pipe[5] <= zp_pipe[4]; min_pipe[5] <= min_pipe[4];
                    max_pipe[5] <= max_pipe[4]; shift_pipe[5] <= shift_pipe[4]; end
            end
            if (advance) begin
                v[6] <= v[5]; v[7] <= v[6];
                if (v[5]) shifted_low_s6 <= shifted_low_w;
                if (v[6]) shifted_high_s7 <= shifted_high_w;
                if (v[5]) begin zp_pipe[6] <= zp_pipe[5]; min_pipe[6] <= min_pipe[5];
                    max_pipe[6] <= max_pipe[5]; shift_pipe[6] <= shift_pipe[5]; end
                if (v[6]) begin zp_pipe[7] <= zp_pipe[6]; min_pipe[7] <= min_pipe[6];
                    max_pipe[7] <= max_pipe[6]; shift_pipe[7] <= shift_pipe[6]; end
            end
            if (advance) begin
                v[8] <= v[7]; v[9] <= v[8];
                if (v[7]) zp_added_s8 <= zp_added_w;
                if (v[8]) out_s9 <= clamp_int8(zp_added_s8,min_pipe[8],max_pipe[8]);
                if (v[7]) begin zp_pipe[8] <= zp_pipe[7]; min_pipe[8] <= min_pipe[7];
                    max_pipe[8] <= max_pipe[7]; shift_pipe[8] <= shift_pipe[7]; end
                if (v[8]) begin zp_pipe[9] <= zp_pipe[8]; min_pipe[9] <= min_pipe[8];
                    max_pipe[9] <= max_pipe[8]; shift_pipe[9] <= shift_pipe[8]; end
            end
            /* All assignments below were partitioned above.  Keeping the
             * old data values when a lane is stalled preserves elastic
             * semantics exactly. */
`ifdef REQUANT_LEGACY
                acc_s0 <= acc_bias_in;
                mul_s0_00 <= multiplier_int32; mul_s0_01 <= multiplier_int32;
                mul_s0_10 <= multiplier_int32; mul_s0_11 <= multiplier_int32;
                zp_pipe[0] <= output_zero_point_int32;
                min_pipe[0] <= activation_min_int32;
                max_pipe[0] <= activation_max_int32; shift_pipe[0] <= shift;
            end
            if (v[0]) begin
                p00_s1 <= p00_w; p01_s1 <= p01_w;
                p10_s1 <= p10_w; p11_s1 <= p11_w;
            end
            if (v[1]) begin csa_sum_s2 <= csa2_sum; csa_carry_s2 <= csa2_carry; end
            if (v[2]) begin
                low_s3 <= low_cpa[31:0];
                low_carry_s3 <= low_cpa[32];
                high_sum_s3 <= csa_sum_s2[63:32];
                high_carry_s3 <= csa_carry_s2[63:32];
            end
            if (v[3]) begin
                low_s4 <= low_s3;
                high_s4 <= high_cpa_s3[31:0];
            end
            if (v[4]) fixed_s5 <= fixed_w;
            if (v[5]) shifted_low_s6 <= shifted_low_w;
            if (v[6]) shifted_high_s7 <= shifted_high_w;
            if (v[7]) zp_added_s8 <= zp_added_w;
            if (v[8]) out_s9 <= clamp_int8(zp_added_s8,min_pipe[8],max_pipe[8]);
            for (i=1; i<10; i=i+1) begin
                if (v[i-1]) begin
                    zp_pipe[i] <= zp_pipe[i-1]; min_pipe[i] <= min_pipe[i-1];
                    max_pipe[i] <= max_pipe[i-1]; shift_pipe[i] <= shift_pipe[i-1];
                end
            end
`endif
        end
    end
endmodule

`default_nettype wire
