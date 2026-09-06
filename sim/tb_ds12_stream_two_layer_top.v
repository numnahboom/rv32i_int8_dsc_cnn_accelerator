`timescale 1ns/1ps
`default_nettype none
module tb_ds12_stream_two_layer_top;
 reg clk=0, rst_n=0, start=0; always #5 clk=~clk;
 reg s1sv=0,s1v=0,s1b=1,s1last=0,c1v=0; reg [31:0] s1e=1,s1n=308,c1e=1; reg [31:0] s1a=0,s1d=0; reg [3:0] s1be=4'hf;
 reg s2sv=0,s2v=0,s2b=0,s2last=0,c2v=0; reg [31:0] s2e=2,s2n=4096,c2e=2; reg [31:0] s2a=0,s2d=0; reg [3:0] s2be=4'hf;
 wire s1r,s2r,w1r,w2r,k1r,k2r,d1,d2,done,err,swap; wire [7:0] ec; wire [1:0] b0s,b1s; wire [31:0] b0e,b1e,are,wer,wc,wen; wire arb,awb,aw;
 wire rr; reg rv=0,rrdy=1,rbank=0; reg [31:0] rep=0,ra=0; wire rvalid; wire [127:0] rdata; wire rrespbank; wire [31:0] rrespe,rrespa;
 ds12_stream_two_layer_top dut(.clk(clk),.rst_n(rst_n),.start(start),
  .ds1_start_valid(s1sv),.ds1_start_bank(s1b),.ds1_start_epoch(s1e),.ds1_start_words(s1n),.ds1_start_ready(s1r),.ds1_write_valid(s1v),.ds1_write_ready(w1r),.ds1_write_bank(s1b),.ds1_write_epoch(s1e),.ds1_write_addr(s1a),.ds1_write_data(s1d),.ds1_write_be(s1be),.ds1_write_last(s1last),.ds1_commit_valid(c1v),.ds1_commit_bank(s1b),.ds1_commit_epoch(c1e),.ds1_commit_ready(k1r),
  .ds2_start_valid(s2sv),.ds2_start_bank(s2b),.ds2_start_epoch(s2e),.ds2_start_words(s2n),.ds2_start_ready(s2r),.ds2_write_valid(s2v),.ds2_write_ready(w2r),.ds2_write_bank(s2b),.ds2_write_epoch(s2e),.ds2_write_addr(s2a),.ds2_write_data(s2d),.ds2_write_be(s2be),.ds2_write_last(s2last),.ds2_commit_valid(c2v),.ds2_commit_bank(s2b),.ds2_commit_epoch(c2e),.ds2_commit_ready(k2r),
  .read_req_valid(rv),.read_req_ready(rr),.read_req_bank(rbank),.read_req_epoch(rep),.read_req_addr(ra),.read_resp_valid(rvalid),.read_resp_ready(rrdy),.read_resp_data(rdata),.read_resp_bank(rrespbank),.read_resp_epoch(rrespe),.read_resp_addr(rrespa),.ds1_done(d1),.ds2_done(d2),.done(done),.error(err),.error_code(ec),.bank0_state(b0s),.bank1_state(b1s),.bank0_epoch(b0e),.bank1_epoch(b1e),.active_read_bank(arb),.active_read_epoch(are),.active_write(aw),.active_write_bank(awb),.write_epoch_active(wer),.write_count(wc),.write_expected_words(wen),.write_last_seen(aw),.atomic_swap(swap));
 integer i;
 initial begin repeat(2) @(posedge clk); rst_n=1; start=1; @(posedge clk); start=0;
   s1sv=1; @(posedge clk); s1sv=0; s1v=1; for(i=0;i<308;i=i+1) begin s1a=i*4; s1d=32'h10000000+i; s1last=(i==307); @(posedge clk); end s1v=0; s1last=0;
   while(!k1r) @(posedge clk); c1v=1; @(posedge clk); c1v=0; while(!d1) @(posedge clk);
   s2sv=1; @(posedge clk); s2sv=0; s2v=1; for(i=0;i<4096;i=i+1) begin s2a=i*4; s2d=32'h20000000+i; s2last=(i==4095); @(posedge clk); end s2v=0; s2last=0;
   while(!k2r) @(posedge clk); c2v=1; @(posedge clk); c2v=0; while(!d2) @(posedge clk);
   if(err || wc!==4096 || !swap) $fatal(1,"TWO_LAYER_FAIL err=%b ec=%h wc=%0d swap=%b",err,ec,wc,swap);
   $display("TWO_LAYER_PASS ds1_words=308 ds2_words=4096 epoch1=1 epoch2=2 final_bank=%b",arb); $finish;
 end
endmodule
`default_nettype wire
