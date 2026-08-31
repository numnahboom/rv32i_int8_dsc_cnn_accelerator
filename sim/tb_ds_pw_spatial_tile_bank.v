`timescale 1ns/1ps
module tb_ds_pw_spatial_tile_bank;
    reg clk=0, rst_n=0; always #1 clk=~clk;
    reg av=0, ab=0; reg [3:0] ae=0; reg [7:0] at=0; reg [63:0] ap=0; reg [7:0] ag=0;
    wire ar;
    reg wv=0, wb=0; reg [3:0] we=0; reg [7:0] wt=0; reg [5:0] wp=0; reg [2:0] wg=0; reg [127:0] wd=0; reg [15:0] wm=0; wire wr;
    reg cv=0, cb=0; reg [3:0] ce=0; reg [7:0] ct=0; wire cr;
    reg pav=0, pab=0; reg [3:0] pae=0; reg [7:0] pat=0; wire par;
    reg prv=0, prb=0; reg [3:0] pre=0; reg [7:0] prt=0; reg [6:0] pci=0; reg [5:0] ppb=0; wire prr;
    wire pov; reg por=0; wire pob; wire [3:0] poe; wire [7:0] pot; wire [63:0] pod; wire [7:0] pom;
    reg plv=0, plb=0; reg [3:0] ple=0; reg [7:0] plt=0; wire plr;
    wire [1:0] state; wire [3:0] se; wire [7:0] st; wire cp,qp,rp; wire [31:0] rc,wc;
    ds_pw_spatial_tile_bank dut(.clk(clk),.rst_n(rst_n),
      .dw_acquire_valid(av),.dw_acquire_ready(ar),.dw_acquire_bank(ab),.dw_acquire_epoch(ae),.dw_acquire_tile(at),.dw_acquire_pixel_mask(ap),.dw_acquire_group_mask(ag),
      .dw_write_valid(wv),.dw_write_ready(wr),.dw_write_bank(wb),.dw_write_epoch(we),.dw_write_tile(wt),.dw_write_pixel_idx(wp),.dw_write_group(wg),.dw_write_data(wd),.dw_write_lane_mask(wm),
      .dw_commit_valid(cv),.dw_commit_ready(cr),.dw_commit_bank(cb),.dw_commit_epoch(ce),.dw_commit_tile(ct),
      .pw_acquire_valid(pav),.pw_acquire_ready(par),.pw_acquire_bank(pab),.pw_acquire_epoch(pae),.pw_acquire_tile(pat),
      .pw_read_valid(prv),.pw_read_ready(prr),.pw_read_bank(prb),.pw_read_epoch(pre),.pw_read_tile(prt),.pw_read_channel_idx(pci),.pw_read_pixel_base(ppb),.pw_out_valid(pov),.pw_out_ready(por),.pw_out_bank(pob),.pw_out_epoch(poe),.pw_out_tile(pot),.pw_out_data(pod),.pw_out_lane_mask(pom),
      .pw_release_valid(plv),.pw_release_ready(plr),.pw_release_bank(plb),.pw_release_epoch(ple),.pw_release_tile(plt),.state(state),.state_epoch(se),.state_tile(st),.commit_pulse(cp),.acquire_pulse(qp),.release_pulse(rp),.read_count(rc),.write_count(wc));
    integer p,g,i,errors=0; reg [127:0] expv;
    function [7:0] value; input integer pix,chan; begin value = (pix*3+chan*5+7) & 8'hff; end endfunction
    task write_cmd; input integer pix,grp; begin
      @(negedge clk); wp=pix; wg=grp; we=4'h3; wt=8'h22; wb=0; wm=16'hffff; wd=0; for(i=0;i<16;i=i+1) wd[i*8 +:8]=value(pix,grp*16+i); wv=1;
      while(!wr) @(posedge clk); @(posedge clk); @(negedge clk); wv=0;
    end endtask
    task read_cmd; input integer ch,row; integer timeout; begin
      begin : wait_response
        @(negedge clk); pci=ch; ppb=row*8; pre=4'h3; prt=8'h22; prb=0; prv=1; timeout=0; while(!prr) begin @(posedge clk); timeout=timeout+1; if(timeout>20) begin $display("READ_READY_TIMEOUT ch=%0d row=%0d prr=%b pov=%b rdpend=%b owner=%b",ch,row,prr,pov,dut.rd_data_pending,dut.owner); errors=errors+1; disable wait_response; end end @(posedge clk); @(negedge clk); prv=0; timeout=0; while(!pov) begin @(posedge clk); timeout=timeout+1; if(timeout>20) begin $display("READ_TIMEOUT ch=%0d row=%0d prr=%b pov=%b rdpend=%b",ch,row,prr,pov,dut.rd_data_pending); errors=errors+1; disable wait_response; end end
      end
      por=1; @(posedge clk); @(negedge clk);
      for(i=0;i<8;i=i+1) if(pod[i*8 +:8] !== value(row*8+i,ch)) errors=errors+1;
      if(pom!==8'hff) errors=errors+1;
    end endtask
    initial begin
      fork
        begin #200000; $display("TIMEOUT bank state=%b wc=%0d rc=%0d",state,wc,rc); $finish; end
      join_none
      repeat(3) @(posedge clk); rst_n=1;
      @(negedge clk); av=1; ae=4'h3; at=8'h22; ap={64{1'b1}}; ag=8'h03; while(!ar) @(posedge clk); @(posedge clk); @(negedge clk); av=0;
      for(p=0;p<64;p=p+1) for(g=0;g<2;g=g+1) write_cmd(p,g);
      @(negedge clk); cv=1; cb=0; ce=4'h3; ct=8'h22; while(!cr) @(posedge clk); @(posedge clk); @(negedge clk); cv=0;
      @(negedge clk); pav=1; pab=0; pae=4'h3; pat=8'h22; while(!par) @(posedge clk); @(posedge clk); @(negedge clk); pav=0; por=1;
      read_cmd(0,0); read_cmd(17,3); read_cmd(31,7);
      @(negedge clk); plv=1; plb=0; ple=4'h3; plt=8'h22; while(!plr) @(posedge clk); @(posedge clk); @(negedge clk); plv=0;
      if(errors==0) $display("PASS tb_ds_pw_spatial_tile_bank writes=%0d reads=%0d",wc,rc); else $display("FAIL tb_ds_pw_spatial_tile_bank errors=%0d",errors);
      $finish;
    end
endmodule
