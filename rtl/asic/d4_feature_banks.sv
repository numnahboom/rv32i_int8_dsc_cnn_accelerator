`timescale 1ns/1ps
`default_nettype none
// Three physical single-port banks, each corresponding to a 2048-word slot.
// Requests retain the original one-edge read latency. Outputs are consumed
// only after their corresponding read; SRAM output during writes is unspecified.
module d4_feature_banks(
    input wire clk,
    input wire a_en, a_we, a_re,
    input wire [12:0] a_addr,
    input wire [127:0] a_wdata,
    output wire [127:0] a_rdata,
    input wire b_en, b_we, b_re,
    input wire [12:0] b_addr,
    input wire [127:0] b_wdata,
    output wire [127:0] b_rdata
);
    wire [127:0] bank_q [0:2];
    reg [1:0] a_read_bank, b_read_bank;
    always @(posedge clk) begin
        if (a_re) a_read_bank<=a_addr[12:11];
        if (b_re) b_read_bank<=b_addr[12:11];
    end
    assign a_rdata=bank_q[a_read_bank];
    assign b_rdata=bank_q[b_read_bank];
    genvar bank;
    generate for(bank=0;bank<3;bank=bank+1) begin: banks
        wire select_a=a_en && a_addr[12:11]==bank;
        wire select_b=b_en && b_addr[12:11]==bank;
        wire enable=select_a || select_b;
        wire write_enable=select_a?a_we:b_we;
        wire [10:0] address=select_a?a_addr[10:0]:b_addr[10:0];
        wire [127:0] write_data=select_a?a_wdata:b_wdata;
        d4_asic_sram_2048x128 mem(clk,enable,write_enable,address,write_data,bank_q[bank]);
    end endgenerate
`ifndef SYNTHESIS
    integer reads=0, writes=0;
    always @(posedge clk) begin
        if ((a_en && a_addr>=6144) || (b_en && b_addr>=6144)) $fatal(1,"ASIC_BANK_RANGE");
        if(a_en && b_en && a_addr[12:11]==b_addr[12:11]) $fatal(1,"ASIC_BANK_CONFLICT");
        if(a_re) reads=reads+1;
        if(b_re) reads=reads+1;
        if(a_en && a_we) writes=writes+1;
        if(b_en && b_we) writes=writes+1;
    end
`endif
endmodule

// Technology adapter is selected separately once a generated SRAM is verified.
// Behavioral mode deliberately has no initialization/reset, and invalidates Q
// on writes to detect accidental dependence on FPGA READ_FIRST behavior.
`ifndef D4_TECH_SRAM
module d4_asic_sram_2048x128(
    input wire clk,en,we,
    input wire [10:0] addr,
    input wire [127:0] din,
    output reg [127:0] dout
);
    reg [127:0] words [0:2047];
    always @(posedge clk) if(en) begin
        if(we) begin words[addr]<=din; dout<=128'bx; end
        else dout<=words[addr];
    end
endmodule
`endif
`default_nettype wire
