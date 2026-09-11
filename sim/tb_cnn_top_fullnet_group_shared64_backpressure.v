`timescale 1ns/1ps
`default_nettype none

/* Group shared64 fullnet protocol stress entry point.  The common harness
 * keeps the external bus one-outstanding and applies a fixed-seed
 * pseudo-random request-ready stream plus a two-cycle response delay while
 * retaining all exact-logit and per-layer ledger checks. */
module tb_cnn_top_fullnet_group_shared64_backpressure;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        // Exercise the same production unified64 Stem under the fixed-seed
        // random-ready and two-cycle response stress path.
        .USE_SHARED_UNIFIED64(1),
        .MEM_READY_STALLS(1),
        .MEM_READY_RANDOM(1),
        .MEM_RESP_DELAY(2),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();
endmodule

`default_nettype wire
