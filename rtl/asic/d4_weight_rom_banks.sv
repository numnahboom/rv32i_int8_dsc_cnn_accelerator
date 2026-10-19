`timescale 1ns/1ps
`default_nettype none
// Eight compiled synchronous mask ROMs, each supplying two output lanes' four
// INT8 coefficients. The 512-bit result has the same one-edge read latency.
module d4_weight_rom_banks(
    input wire clk,enable,
    input wire [11:0] address,
    output wire [511:0] data
);
    D4WROM0 b0(.D(data[63:0]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM1 b1(.D(data[127:64]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM2 b2(.D(data[191:128]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM3 b3(.D(data[255:192]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM4 b4(.D(data[319:256]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM5 b5(.D(data[383:320]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM6 b6(.D(data[447:384]),.A(address),.CLK(clk),.CSB(~enable));
    D4WROM7 b7(.D(data[511:448]),.A(address),.CLK(clk),.CSB(~enable));
endmodule
`default_nettype wire
