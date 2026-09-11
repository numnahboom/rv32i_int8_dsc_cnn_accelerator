`timescale 1ns/1ps
`default_nettype none

/* Compatibility Gate-B/fullnet entry point.  M1.1-A now owns descriptor
 * slots 1 and 2; the canonical entry point is
 * tb_cnn_top_fullnet_m11a_ds12.  Keep this independently compilable DS1-
 * named entry point for existing invocations while the base harness retains
 * its golden-logit and complete ledger checks. */
module tb_cnn_top_fullnet_m11a_ds1;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_M11A_DS1(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();
endmodule

`default_nettype wire
