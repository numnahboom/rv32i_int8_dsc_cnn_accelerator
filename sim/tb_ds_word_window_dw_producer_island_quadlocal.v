`timescale 1ns/1ps
`default_nettype none

/* Reuse the established exact producer-island stimulus while selecting the
 * quad-local DW implementation through the non-production parameter hook. */
module tb_ds_word_window_dw_producer_island_quadlocal #(
    parameter integer TB_CIN = 48,
    parameter integer TB_STRIDE = 1
);
    tb_ds_word_window_dw_producer_island #(
        .TB_CIN(TB_CIN), .TB_STRIDE(TB_STRIDE), .TB_USE_QUADLOCAL(1)
    ) base;
endmodule

`default_nettype wire
