`timescale 1ns/1ps
`default_nettype none

/* Full C0 production entry point for the mutually-exclusive
 * group-published shared64 DS backend. */
module tb_cnn_top_fullnet_group_shared64;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        // Promote the exact unified64 row-bank Stem into this production
        // envelope.  The runner's generate selects it exclusively, so the
        // legacy Stem arithmetic plane is not elaborated alongside it.
        .USE_SHARED_UNIFIED64(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();
endmodule

`default_nettype wire
