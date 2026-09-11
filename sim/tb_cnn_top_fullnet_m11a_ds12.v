`timescale 1ns/1ps
`default_nettype none

/* Gate-B/fullnet entry point: the base harness retains its golden-logit and
 * complete ledger checks, while cnn_top routes descriptor slots 1 and 2 to
 * the M1.1-A runner and leaves DS3..DS6 plus the tail on the legacy runner. */
module tb_cnn_top_fullnet_m11a_ds12;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_M11A_DS1(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();
endmodule

`default_nettype wire
