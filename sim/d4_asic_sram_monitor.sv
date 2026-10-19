`timescale 1ns/1ps
// Independent word-level reference at the feature-bank interface. For debug
// and macro acceptance only; never synthesized into the design.
module d4_asic_sram_monitor(
    input wire clk,a_en,a_we,a_re,b_en,b_we,b_re,
    input wire [12:0] a_addr,b_addr,
    input wire [127:0] a_wdata,b_wdata,a_rdata,b_rdata
);
    reg [127:0] reference_words [0:6143];
    reg [127:0] expected_a,expected_b;
    reg check_a,check_b;
    reg [12:0] saved_a,saved_b;
    integer reads=0,writes=0;
    always @(posedge clk) begin
        check_a=a_re;check_b=b_re;saved_a=a_addr;saved_b=b_addr;
        if(a_re) expected_a=reference_words[a_addr];
        if(b_re) expected_b=reference_words[b_addr];
        if(a_en && a_we) begin reference_words[a_addr]=a_wdata;writes=writes+1;end
        if(b_en && b_we) begin reference_words[b_addr]=b_wdata;writes=writes+1;end
        #3;
        if(check_a && a_rdata!==expected_a)
            $fatal(1,"ASIC_SRAM_A_MISMATCH address=%0d got=%h expected=%h reads=%0d writes=%0d",saved_a,a_rdata,expected_a,reads,writes);
        if(check_b && b_rdata!==expected_b)
            $fatal(1,"ASIC_SRAM_B_MISMATCH address=%0d got=%h expected=%h reads=%0d writes=%0d",saved_b,b_rdata,expected_b,reads,writes);
        if(check_a) reads=reads+1;
        if(check_b) reads=reads+1;
    end
endmodule
bind d4_feature_banks d4_asic_sram_monitor monitor(.*);
