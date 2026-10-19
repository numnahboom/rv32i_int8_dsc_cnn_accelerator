`timescale 1ns/1ps
`default_nettype none
// Eight independent synchronous read ports replace four dual-port replicas.
// Each used signed9 value is exact; the macro's seven spare bits are ignored.
module d4_residual_rom_banks(
    input wire clk,enable,
    input wire [95:0] address,
    output wire [71:0] data
);
    wire [15:0] q [0:7];
    D4RROM0 b0(.D(q[0]),.A(address[11:0]),.CLK(clk),.CSB(~enable));
    D4RROM1 b1(.D(q[1]),.A(address[23:12]),.CLK(clk),.CSB(~enable));
    D4RROM2 b2(.D(q[2]),.A(address[35:24]),.CLK(clk),.CSB(~enable));
    D4RROM3 b3(.D(q[3]),.A(address[47:36]),.CLK(clk),.CSB(~enable));
    D4RROM4 b4(.D(q[4]),.A(address[59:48]),.CLK(clk),.CSB(~enable));
    D4RROM5 b5(.D(q[5]),.A(address[71:60]),.CLK(clk),.CSB(~enable));
    D4RROM6 b6(.D(q[6]),.A(address[83:72]),.CLK(clk),.CSB(~enable));
    D4RROM7 b7(.D(q[7]),.A(address[95:84]),.CLK(clk),.CSB(~enable));
    genvar i;
    generate for(i=0;i<8;i=i+1) begin: outputs_used
        assign data[i*9+:9]=q[i][8:0];
    end endgenerate
endmodule
`default_nettype wire
