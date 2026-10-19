`timescale 1ns/1ps
module tb_d4_residual_roms;
    reg clk=0,enable=0;
    always #5 clk=~clk;
    reg [95:0] address=0;
    wire [71:0] data;
    reg [31:0] original [0:4095];
    integer i,port,index;
    d4_residual_rom_banks dut(.*);
    initial begin
        for(i=0;i<4096;i=i+1) original[i]=0;
        $readmemh("build/d4_fullnet_vectors/sample_0/residual_lut.mem",original);
        repeat(2) @(negedge clk);
        for(i=0;i<4096;i=i+1) begin
            for(port=0;port<8;port=port+1) address[port*12+:12]=(i+port*137)&4095;
            enable=1;
            @(posedge clk);#3;
            for(port=0;port<8;port=port+1) begin
                index=(i+port*137)&4095;
                if(data[port*9+:9]!==original[index][8:0]) $fatal(1,"RESIDUAL_ROM port=%0d address=%0d",port,index);
            end
            @(negedge clk);
        end
        $display("D4_RESIDUAL_ROM_EXACT_PASS checks=32768 ports=8 used_bits=9 latency=1");
        $finish;
    end
endmodule
