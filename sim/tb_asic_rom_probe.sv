`timescale 1ns/1ps
module tb_asic_rom_probe;
    reg clk=0,csb=1;
    always #5 clk=~clk;
    reg [7:0] address=0;
    wire [7:0] data;
    D4ROM_PROBE8 dut(.D(data),.A(address),.CLK(clk),.CSB(csb));
    integer i;
    initial begin
        repeat(2) @(negedge clk);
        for(i=0;i<256;i=i+1) begin
            address=i;csb=0;
            @(posedge clk);#3;
            if(data!==i[7:0]) $fatal(1,"ROM_PROGRAM address=%0d got=%h",i,data);
            @(negedge clk);
        end
        csb=1;
        $display("ASIC_ROM_PROBE_PASS words=256 bits=8 synchronous_latency=1");
        $finish;
    end
endmodule
