`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v6 physical PW fetch contract.
 *
 * Activation and weight memories are independent one-cycle response
 * channels.  This boundary makes one request descriptor the unit of work for
 * both ports and only exposes a MAC transaction after both responses carry
 * the same descriptor.  The descriptor layout is intentionally compact and
 * fixed so it is cheap to carry through a RAMB response register:
 *
 *   [15:12] epoch, [11] slot, [10] project, [9] group,
 *   [8] pass, [7:2] K, [1] first, [0] last.
 *
 * There is no speculative request or independent K counter here.  A request
 * fires only when both physical ports accept it; a response is consumed only
 * when both valid bits and all descriptor fields agree.  If either response
 * stalls, both response-ready signals stay low, preserving the descriptor and
 * data until the paired consumer is ready.  When the pair is consumed on an
 * edge, both underlying one-entry RAM response queues may accept the next
 * request on that same edge (II=1).
 */
module edgembconv_hwacandidate_d4_vstream_v6_fetch_pair #(
    parameter integer ACT_WIDTH = 256,
    parameter integer WGT_WIDTH = 128
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    req_valid,
    output wire                    req_ready,
    input  wire [15:0]             req_desc,

    output wire                    act_req_valid,
    input  wire                    act_req_ready,
    output wire [15:0]             act_req_desc,
    output wire                    wgt_req_valid,
    input  wire                    wgt_req_ready,
    output wire [15:0]             wgt_req_desc,

    input  wire                    act_resp_valid,
    output wire                    act_resp_ready,
    input  wire [ACT_WIDTH-1:0]    act_resp_data,
    input  wire [15:0]             act_resp_desc,
    input  wire                    wgt_resp_valid,
    output wire                    wgt_resp_ready,
    input  wire [WGT_WIDTH-1:0]    wgt_resp_data,
    input  wire [15:0]             wgt_resp_desc,

    output wire                    pair_resp_valid,
    input  wire                    pair_resp_ready,
    output wire [ACT_WIDTH-1:0]    pair_act_data,
    output wire [WGT_WIDTH-1:0]    pair_wgt_data,
    output wire [15:0]             pair_resp_desc,
    output wire                    descriptor_mismatch
);
    wire descriptors_equal = (act_resp_desc == wgt_resp_desc);
    wire pair_ready = act_resp_valid && wgt_resp_valid &&
                      descriptors_equal && pair_resp_ready;

    /* Both request ports see the exact same descriptor and fire together. */
    assign req_ready = rst_n && act_req_ready && wgt_req_ready;
    assign act_req_valid = req_valid && req_ready;
    assign wgt_req_valid = req_valid && req_ready;
    assign act_req_desc = req_desc;
    assign wgt_req_desc = req_desc;

    /* A partial response is held at its memory boundary.  A mismatched pair
     * is deliberately not consumed; descriptor_mismatch lets a TB or parent
     * diagnostic report the contract failure instead of silently MACing it. */
    assign pair_resp_valid = act_resp_valid && wgt_resp_valid &&
                             descriptors_equal;
    assign act_resp_ready = pair_ready;
    assign wgt_resp_ready = pair_ready;
    assign pair_act_data = act_resp_data;
    assign pair_wgt_data = wgt_resp_data;
    assign pair_resp_desc = act_resp_desc;
    assign descriptor_mismatch = act_resp_valid && wgt_resp_valid &&
                                 !descriptors_equal;

    /* Keep clk in the interface so the pair is an explicit clock-domain
     * contract even though all state is held by the two physical RAM ports. */
    wire unused_clk = clk;
endmodule

`default_nettype wire
