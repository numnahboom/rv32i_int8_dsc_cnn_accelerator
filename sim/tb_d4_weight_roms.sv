`timescale 1ns/1ps
module tb_d4_weight_roms;
    reg clk=0,enable=0;
    always #5 clk=~clk;
    reg [11:0] address=0;
    wire [511:0] data;
    reg [511:0] expected [0:4095];
    integer i;
    d4_weight_rom_banks dut(.*);
    initial begin
        for(i=0;i<4096;i=i+1) expected[i]=0;
        $readmemh("build/d4_fullnet_vectors/sample_0/weights.mem",expected);
        repeat(2) @(negedge clk);
        for(i=0;i<4096;i=i+1) begin
            address=i;enable=1;
            @(posedge clk);#3;
            if(data!==expected[i]) $fatal(1,"WEIGHT_ROM_MISMATCH address=%0d got=%h expected=%h",i,data,expected[i]);
            @(negedge clk);
        end
        enable=0;
        $display("D4_WEIGHT_ROM_EXACT_PASS words=4096 bits=512 banks=8");
        $finish;
    end
endmodule
