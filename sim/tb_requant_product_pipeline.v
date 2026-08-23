`timescale 1ns/1ps
`default_nettype none
module tb_requant_product_pipeline;
 reg clk=0,rst_n=0,valid_in=0; reg signed [63:0] product; reg [5:0] shift; reg signed [31:0] zp,minv,maxv; reg [3:0] tag;
 wire valid_out; wire signed [7:0] output_int8; wire [3:0] tag_out; wire signed [7:0] expected;
 integer i, errors=0, sent=0, received=0;
 requant_activation_core refcore(.product_int64(product),.shift(shift),.output_zero_point_int32(zp),.activation_min_int32(minv),.activation_max_int32(maxv),.output_int8(expected));
 requant_product_pipeline dut(.clk(clk),.rst_n(rst_n),.valid_in(valid_in),.product_int64(product),.shift(shift),.output_zero_point_int32(zp),.activation_min_int32(minv),.activation_max_int32(maxv),.tag_in(tag),.valid_out(valid_out),.output_int8(output_int8),.tag_out(tag_out));
 always #5 clk=~clk;
 reg signed [7:0] exp_q[0:31]; reg [3:0] tag_q[0:31]; integer qin=0,qout=0;
 always @(posedge clk) begin
   if (!rst_n) begin qin=0; qout=0; end else begin
     if (valid_in) begin exp_q[qin]=expected; tag_q[qin]=tag; qin=qin+1; sent=sent+1; end
     if (valid_out) begin if (output_int8!==exp_q[qout] || tag_out!==tag_q[qout]) begin $display("FAIL idx=%0d got=%0d/%0d exp=%0d/%0d",qout,output_int8,tag_out,exp_q[qout],tag_q[qout]); errors=errors+1; end qout=qout+1; received=received+1; end
   end
 end
 initial begin
   product=0; shift=0; zp=0; minv=-128; maxv=127; tag=0; repeat(2) @(posedge clk); rst_n=1;
   for(i=0;i<12;i=i+1) begin @(negedge clk); valid_in=1; tag=i[3:0]; product=(i==0)?64'sd0:(i==1)?64'sd1073741824:(i==2)?-64'sd1073741824:(i==3)?64'sh7fffffffffffffff:(i==4)?-64'sh8000000000000000:((i-6)*64'sd123456789); shift=i[2:0]; zp=(i-5)*3; minv=-128; maxv=127; end
   @(negedge clk) valid_in=0; repeat(8) @(posedge clk);
   if(errors==0 && received==sent) $display("PASS tb_requant_product_pipeline cases=%0d",sent); else $display("FAIL cases=%0d received=%0d errors=%0d",sent,received,errors); $finish;
 end
endmodule
`default_nettype wire
