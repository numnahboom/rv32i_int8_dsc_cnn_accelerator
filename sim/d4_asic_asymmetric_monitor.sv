`timescale 1ns/1ps
module d4_asic_asymmetric_bounds(
    input wire clk,a_re,b_re,halo_read,
    input wire [12:0] a_addr,b_addr
);
    integer masked_halo_reads=0,required_reads=0;
    always @(posedge clk) begin
        if(a_re && a_addr[12:11]==1 && a_addr[10]) begin
            if(!halo_read) $fatal(1,"ASIC_SHALLOW_REQUIRED_A_READ");
            masked_halo_reads=masked_halo_reads+1;
        end
        if(b_re && b_addr[12:11]==1 && b_addr[10]) $fatal(1,"ASIC_SHALLOW_REQUIRED_B_READ");
        if(a_re && !halo_read) required_reads=required_reads+1;
        if(b_re) required_reads=required_reads+1;
    end
endmodule
bind d4_fullnet_top d4_asic_asymmetric_bounds asymmetric_bounds(
    .clk(clk),.a_re(fm_read_a),.b_re(fm_read_b),.halo_read(issue_read && halo),
    .a_addr(port_a_addr),.b_addr(port_b_addr)
);
// Keep the independent reference's original 6144-word address space. Only
// halo reads proven to be discarded are exempt from comparing undefined data.
bind d4_fullnet_top d4_asic_sram_monitor asymmetric_memory_monitor(
    .clk(clk),.a_en(port_a_en),.a_we(write_en_a),.a_re(fm_read_a && !(issue_read && halo)),
    .a_addr(port_a_addr),.a_wdata(write_data),.a_rdata(fm_a),
    .b_en(port_b_en),.b_we(write_en_b),.b_re(fm_read_b),
    .b_addr(port_b_addr),.b_wdata(result_vector),.b_rdata(fm_b)
);
