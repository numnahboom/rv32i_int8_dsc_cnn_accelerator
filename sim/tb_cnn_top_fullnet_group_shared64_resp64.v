`timescale 1ns/1ps
`default_nettype none

/* Production shared64 fullnet exact gate with a fixed 64-cycle external
 * memory response delay.  This keeps the stress mode independent from the
 * normal no-backpressure and two-cycle randomized wrappers. */
module tb_cnn_top_fullnet_group_shared64_resp64;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        .USE_SHARED_UNIFIED64(1),
        .PACKED_WEIGHTS(1),
        .MEM_RESP_DELAY(64),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();
endmodule

`default_nettype wire
