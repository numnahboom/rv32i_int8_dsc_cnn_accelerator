`timescale 1ns/1ps
`default_nettype none

/*
 * Physical-screening shell for the registered-input dual-mode pool.
 * Every operand, mode, tag, and output handshake remains a top-level signal
 * so Vivado cannot prove the PW or RQ path away.  This is an island OOC
 * wrapper only; it is not connected to cnn_top.
 */
module edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_wrapper (
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
    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin u_pool (
        .clk(clk),
        .rst_n(rst_n),
        .mode_rq(mode_rq),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .rq_acc_vec(rq_acc_vec),
        .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec),
        .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec),
        .rq_max_vec(rq_max_vec),
        .pw_act_vec(pw_act_vec),
        .pw_wgt_vec(pw_wgt_vec),
        .metadata_in(metadata_in),
        .valid_out(valid_out),
        .ready_out(ready_out),
        .mode_rq_out(mode_rq_out),
        .pw_product_vec(pw_product_vec),
        .rq_product_vec(rq_product_vec),
        .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out)
    );
endmodule

`default_nettype wire
