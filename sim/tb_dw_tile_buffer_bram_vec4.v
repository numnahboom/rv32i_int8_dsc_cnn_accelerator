`timescale 1ns/1ps
`default_nettype none
module tb_dw_tile_buffer_bram_vec4;
    reg clk=0, rst_n=0, wr_en=0, wr_vec4_en=0, rd_en=0;
    reg [5:0] wr_pixel_idx=0, wr_vec4_pixel_idx=0, rd_pixel_base=0;
    reg [6:0] wr_channel_idx=0, wr_vec4_channel_idx=0, rd_channel_idx=0;
    reg signed [7:0] wr_data_int8=0;
    reg [31:0] wr_vec4_data_int8=0;
    reg [3:0] wr_vec4_byte_en=0;
    wire rd_valid; wire signed [63:0] rd_data_vector;
    integer errors=0, i;
    dw_tile_buffer_bram dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_pixel_idx(wr_pixel_idx),
        .wr_channel_idx(wr_channel_idx), .wr_data_int8(wr_data_int8),
        .wr_vec4_en(wr_vec4_en), .wr_vec4_pixel_idx(wr_vec4_pixel_idx),
        .wr_vec4_channel_idx(wr_vec4_channel_idx),
        .wr_vec4_data_int8(wr_vec4_data_int8), .wr_vec4_byte_en(wr_vec4_byte_en),
        .rd_en(rd_en), .rd_pixel_base(rd_pixel_base),
        .rd_channel_idx(rd_channel_idx), .rd_valid(rd_valid),
        .rd_data_vector(rd_data_vector)
    );
    always #5 clk=~clk;
    task read_expect; input [6:0] c; input [7:0] value; reg [63:0] exp; begin
        @(negedge clk); rd_channel_idx=c; rd_en=1'b1;
        @(posedge clk); #1;
        exp=64'd0; exp[24 +: 8]=value;
        if (!rd_valid || rd_data_vector[24 +: 8] !== value) begin
            $display("FAIL c=%0d valid=%b data=%h exp=%h",c,rd_valid,rd_data_vector,exp);
            errors=errors+1;
        end
        @(negedge clk); rd_en=1'b0;
    end endtask
    initial begin
        repeat(3) @(posedge clk); rst_n=1;
        @(negedge clk); wr_vec4_en=1; wr_vec4_pixel_idx=6'd3;
        wr_vec4_channel_idx=7'd0; wr_vec4_data_int8=32'h44332211;
        wr_vec4_byte_en=4'b1111;
        @(posedge clk); #1; wr_vec4_en=0; wr_vec4_byte_en=0;
        for(i=0;i<4;i=i+1) read_expect(i,8'h11 + i*8'h11);
        if(errors==0) $display("PASS tb_dw_tile_buffer_bram_vec4 checks=4");
        else $fatal(1,"vector buffer errors=%0d",errors);
        $finish;
    end
endmodule
`default_nettype wire
