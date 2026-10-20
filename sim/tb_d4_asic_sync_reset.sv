`timescale 1ns/1ps
// Unit for the ASIC synthesis reset policy; no state is forced or initialized.
module tb_d4_asic_sync_reset;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,start=0,valid=0;
    wire [9:0] index;
    wire active;
    d4_sync_reset_probe dut(.*);
    integer expected=0,checks=0,i;
    initial begin
        repeat(5) @(negedge clk);
        if(index!==0 || active!==0) $fatal(1,"SYNC_RESET_START_X index=%b active=%b",index,active);
        rst_n=1;start=1;
        @(negedge clk);start=0;
        for(i=0;i<1100;i=i+1) begin
            valid=(i%5)!=0;
            @(negedge clk);
            if(valid && expected<1023) expected=expected+1;
            if(index!==expected || active!==1'b1) $fatal(1,"SYNC_RESET_COUNT index=%h expected=%h",index,expected);
            checks=checks+1;
        end
        rst_n=0;
        repeat(3) @(negedge clk);
        if(index!==0 || active!==0) $fatal(1,"SYNC_RESET_RESTART");
        $display("D4_SYNC_RESET_PROBE_PASS checks=%0d uninitialized_start=1",checks);
        $finish;
    end
endmodule
