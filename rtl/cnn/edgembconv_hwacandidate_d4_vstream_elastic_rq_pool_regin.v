`timescale 1ns/1ps
`default_nettype none

/*
 * Registered-input shell for the vstream dual-mode pool.
 *
 * The arithmetic pool already carries an elastic output pipeline and a
 * one-cycle DSP48E1/PREG boundary.  This shell adds the transaction boundary
 * that a real producer needs: every accepted operand vector, mode, metadata,
 * and RQ post-processing tag is captured before it enters the pool.  The
 * one-entry input register is a fall-through queue at the handshake level:
 * while the pool consumes its current entry, a new request can be captured on
 * the same edge, so the external contract remains II=1 whenever the pool is
 * ready.  When the pool is stalled, all accepted context remains stable.
 *
 * No arithmetic is duplicated here.  The wrapped pool retains its sixteen
 * DSP48E1 primitives and its existing PREG alignment; this module only makes
 * the accepted-operand/tag boundary explicit for synthesis and integration.
 */
module edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin #(
    parameter integer STAGE_COUNT = 9
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         mode_rq,
    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire signed [127:0]          rq_acc_vec,
    input  wire signed [127:0]          rq_multiplier_vec,
    input  wire [23:0]                  rq_shift_vec,
    input  wire signed [127:0]          rq_zero_point_vec,
    input  wire signed [127:0]          rq_min_vec,
    input  wire signed [127:0]          rq_max_vec,
    input  wire [127:0]                 pw_act_vec,
    input  wire [127:0]                 pw_wgt_vec,
    input  wire [31:0]                  metadata_in,
    output wire                         valid_out,
    input  wire                         ready_out,
    output wire                         mode_rq_out,
    output wire [255:0]                 pw_product_vec,
    output wire signed [255:0]          rq_product_vec,
    output wire signed [31:0]            rq_result_vec,
    output wire [31:0]                  metadata_out
);
    reg input_valid;
    reg input_mode;
    reg signed [127:0] input_rq_acc;
    reg signed [127:0] input_rq_multiplier;
    reg [23:0] input_rq_shift;
    reg signed [127:0] input_rq_zero_point;
    reg signed [127:0] input_rq_min;
    reg signed [127:0] input_rq_max;
    reg [127:0] input_pw_act;
    reg [127:0] input_pw_wgt;
    reg [31:0] input_metadata;

    wire pool_ready;
    wire pool_input_fire = input_valid && pool_ready;
    wire input_fire = valid_in && ready_in;

    /* Empty storage accepts immediately.  A full storage slot is available
     * for replacement exactly when the wrapped pool consumes its entry. */
    assign ready_in = rst_n && (!input_valid || pool_ready);

    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool #(
        .STAGE_COUNT(STAGE_COUNT)
    ) u_pool (
        .clk(clk),
        .rst_n(rst_n),
        .mode_rq(input_mode),
        .valid_in(input_valid),
        .ready_in(pool_ready),
        .rq_acc_vec(input_rq_acc),
        .rq_multiplier_vec(input_rq_multiplier),
        .rq_shift_vec(input_rq_shift),
        .rq_zero_point_vec(input_rq_zero_point),
        .rq_min_vec(input_rq_min),
        .rq_max_vec(input_rq_max),
        .pw_act_vec(input_pw_act),
        .pw_wgt_vec(input_pw_wgt),
        .metadata_in(input_metadata),
        .valid_out(valid_out),
        .ready_out(ready_out),
        .mode_rq_out(mode_rq_out),
        .pw_product_vec(pw_product_vec),
        .rq_product_vec(rq_product_vec),
        .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            input_valid <= 1'b0;
            input_mode <= 1'b1;
            input_rq_acc <= 128'sd0;
            input_rq_multiplier <= 128'sd0;
            input_rq_shift <= 24'd0;
            input_rq_zero_point <= 128'sd0;
            input_rq_min <= 128'sd0;
            input_rq_max <= 128'sd0;
            input_pw_act <= 128'd0;
            input_pw_wgt <= 128'd0;
            input_metadata <= 32'd0;
        end else if (ready_in) begin
            /* Replacement and first fill are intentionally one assignment:
             * input_fire captures the next request while pool_input_fire
             * retires the prior entry on this same edge. */
            input_valid <= input_fire;
            if (input_fire) begin
                input_mode <= mode_rq;
                input_rq_acc <= rq_acc_vec;
                input_rq_multiplier <= rq_multiplier_vec;
                input_rq_shift <= rq_shift_vec;
                input_rq_zero_point <= rq_zero_point_vec;
                input_rq_min <= rq_min_vec;
                input_rq_max <= rq_max_vec;
                input_pw_act <= pw_act_vec;
                input_pw_wgt <= pw_wgt_vec;
                input_metadata <= metadata_in;
            end
        end
    end
endmodule

`default_nettype wire
