`timescale 1ns/1ps
`default_nettype none
// Local compiler output is kept exclusively on the server. The compiler uses
// this default cell name even when -bitsnumber 128 -muxwidth 8 are selected;
// the checked macro manifest must assert actual width 128/depth 2048.
module d4_asic_sram_2048x128(
    input wire clk,en,we,
    input wire [10:0] addr,
    input wire [127:0] din,
    output wire [127:0] dout
);
    RASP2048X16M16 macro(
        // This compiler model uses active-high WE and active-low CEN.
        .DOUT(dout),.AD(addr),.CEN(~en),.CLK(clk),.DIN(din),.OE(1'b1),.WE(we)
    );
endmodule
`default_nettype wire
