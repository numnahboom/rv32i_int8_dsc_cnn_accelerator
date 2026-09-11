`timescale 1ns/1ps
`default_nettype none

/*
 * Dense 3x3 output-stationary primitive, 8 pixels by 16 output channels.
 *
 * One accepted token is one reduction position K.  The activation vector is
 * shared by both physical slices (eight pixels); each slice owns an
 * independent eight-channel weight vector and accumulator bank.  Therefore a
 * full token performs exactly 8*16 signed INT8 products.  first_k/last_k are
 * the boundaries of the complete reduction, not a group boundary; k_idx is
 * an optional monotonic protocol tag.  The current C1 stem uses K=27 in
 * [input-channel][kernel-y][kernel-x] order.
 *
 * This module intentionally stops at the INT32 output-stationary psum.  The
 * psum vector and lane mask are the stable contract consumed by the existing
 * exact requantizer.  Keeping requant outside this 128-MAC primitive avoids
 * duplicating 128 ten-stage quantizers and preserves the same arithmetic
 * boundary used by the existing unified engines.
 */
module dense128_os_8x16 (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire                 first_k,
    input  wire                 last_k,
    input  wire [7:0]           k_idx,
    input  wire [7:0]           pixel_mask,
    input  wire [15:0]          cout_mask,
    input  wire signed [63:0]   act_vec,
    input  wire signed [63:0]   wgt_vec_lo,
    input  wire signed [63:0]   wgt_vec_hi,
    input  wire                 ready_out,
    output wire                 valid_out,
    output wire signed [4095:0] psum_out,
    output wire [127:0]         lane_mask_out
);
    wire lo_ready, hi_ready;
    wire lo_valid, hi_valid;
    wire signed [2047:0] lo_psum, hi_psum;
    wire [63:0] lo_mask, hi_mask;

    /* Both slices see the same flow-control decision.  They receive the
     * identical activation token and can only advance together, so their
     * output blocks remain aligned even under arbitrary ready_out stalls. */
    assign ready_in = lo_ready && hi_ready;
    assign valid_out = lo_valid && hi_valid;
    /* Re-interleave the two physical Cout halves at the external boundary so
     * the logical lane order stays pixel-major: p0/c0..c15, p1/c0..c15,
     * ... .  Each source slice itself remains independently output
     * stationary and owns its own Cout weights/psum registers. */
    genvar pixel_g, cout_g;
    generate
        for (pixel_g = 0; pixel_g < 8; pixel_g = pixel_g + 1) begin : gen_pixel
            for (cout_g = 0; cout_g < 8; cout_g = cout_g + 1) begin : gen_cout
                localparam integer LO_LANE = pixel_g * 8 + cout_g;
                localparam integer FULL_LO = pixel_g * 16 + cout_g;
                localparam integer FULL_HI = pixel_g * 16 + cout_g + 8;
                assign psum_out[(FULL_LO*32) +: 32] = lo_psum[(LO_LANE*32) +: 32];
                assign psum_out[(FULL_HI*32) +: 32] = hi_psum[(LO_LANE*32) +: 32];
                assign lane_mask_out[FULL_LO] = lo_mask[LO_LANE];
                assign lane_mask_out[FULL_HI] = hi_mask[LO_LANE];
            end
        end
    endgenerate

    pw_direct_8x8_dsp u_slice_lo (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(lo_ready),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask[7:0]),
        .act_vec(act_vec), .wgt_vec(wgt_vec_lo),
        .ready_out(ready_out), .valid_out(lo_valid), .psum_out(lo_psum),
        .lane_mask_out(lo_mask)
    );

    pw_direct_8x8_dsp u_slice_hi (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(hi_ready),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask[15:8]),
        .act_vec(act_vec), .wgt_vec(wgt_vec_hi),
        .ready_out(ready_out), .valid_out(hi_valid), .psum_out(hi_psum),
        .lane_mask_out(hi_mask)
    );
endmodule

`default_nettype wire
