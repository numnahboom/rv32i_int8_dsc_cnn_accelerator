`timescale 1ns/1ps
`default_nettype none

/* Complete-network retained DS1 integration harness.  Keep the historical
 * fullnet testbench's stimulus, golden-byte checks, and metrics intact while
 * selecting the strict DS1 runner path through its compile-time parameter. */
module tb_cnn_top_fullnet_sram_datapath_retained;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_DS1_RETAINED_ORCHESTRATOR(1)
    ) u_fullnet ();
endmodule

`default_nettype wire
