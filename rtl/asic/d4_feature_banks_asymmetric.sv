`timescale 1ns/1ps
`default_nettype none
// Frozen descriptor peaks: slot0=2048, slot1=1024, slot2=2048 words.
// Slot1's unused halo addresses may alias; their operand is forced to zero by
// unchanged core logic. Every meaningful read/write is checked in simulation.
module d4_feature_banks_asymmetric(
    input wire clk,
    input wire a_en,a_we,a_re,
    input wire [12:0] a_addr,
    input wire [127:0] a_wdata,
    output wire [127:0] a_rdata,
    input wire b_en,b_we,b_re,
    input wire [12:0] b_addr,
    input wire [127:0] b_wdata,
    output wire [127:0] b_rdata
);
    wire [127:0] bank_q [0:2];
    reg [1:0] a_read_bank,b_read_bank;
    always @(posedge clk) begin
        if(a_re) a_read_bank<=a_addr[12:11];
        if(b_re) b_read_bank<=b_addr[12:11];
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
        if(bank==1) begin: shallow
            d4_asic_sram_1024x128 mem(clk,enable,write_enable,address[9:0],write_data,bank_q[bank]);
        end else begin: deep
            d4_asic_sram_2048x128 mem(clk,enable,write_enable,address,write_data,bank_q[bank]);
        end
    end endgenerate
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if((a_en && a_addr>=6144) || (b_en && b_addr>=6144)) $fatal(1,"ASIC_BANK_RANGE");
        if(a_en && b_en && a_addr[12:11]==b_addr[12:11]) $fatal(1,"ASIC_BANK_CONFLICT");
        if(a_en && a_we && a_addr[12:11]==1 && a_addr[10]) $fatal(1,"ASIC_SHALLOW_A_WRITE");
        if(b_en && b_we && b_addr[12:11]==1 && b_addr[10]) $fatal(1,"ASIC_SHALLOW_B_WRITE");
    end
`endif
endmodule

module d4_asic_sram_1024x128(
    input wire clk,en,we,
    input wire [9:0] addr,
    input wire [127:0] din,
    output wire [127:0] dout
);
`ifdef D4_TECH_SRAM
    D4_ACT_1024X128_M8 macro(.DOUT(dout),.AD(addr),.CEN(~en),.CLK(clk),.DIN(din),.OE(1'b1),.WE(we));
`else
    reg [127:0] words [0:1023];
    reg [127:0] q;
    assign dout=q;
    always @(posedge clk) if(en) begin
        if(we) begin words[addr]<=din;q<=128'bx;end
        else q<=words[addr];
    end
`endif
endmodule
`default_nettype wire
