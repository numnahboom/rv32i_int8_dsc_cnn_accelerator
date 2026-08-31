`timescale 1ns/1ps
`default_nettype none

/* End-to-end ownership/storage scoreboard for both supported tile shapes. */
module tb_feature_tile_vector16_pingpong_shell;
  localparam integer EW=4, TW=8, XW=12, BA=13, PA=7, GA=2, BAA=9;
  localparam integer FREE=0, FILL=1, READY=2, ACTIVE=3, DONE=4;
  reg clk=0, rst_n=0; always #4 clk=~clk;

  /* Keep identical shell port widths for both instances; the 3-channel
   * instance intentionally overprovisions byte/bank address buses. */
  reg [1:0] fs_v, fd_v, ac_v, cd_v, rel_v;
  wire [1:0] fs_r, fd_r, ac_r, cd_r, rel_r;
  reg [1:0] fs_b,fd_b,ac_b,cd_b,rel_b;
  reg [1:0][EW-1:0] fs_e,fd_e,ac_e,cd_e,rel_e;
  reg [1:0][TW-1:0] fs_t,fd_t,ac_t,cd_t,rel_t;
  reg [1:0][XW-1:0] fs_x,fd_x,ac_x,cd_x,rel_x;
  wire [1:0] fs_ov,fd_ov,ac_ov,cd_ov,rel_ov;
  reg [1:0] fs_or,fd_or,ac_or,cd_or,rel_or;
  wire [1:0] fs_ok,fd_ok,ac_ok,cd_ok,rel_ok;
  wire [1:0][2:0] fs_err,fd_err,ac_err,cd_err,rel_err;
  wire [1:0][2:0] st0,st1;
  reg [1:0] wr_v,wr_bank; wire [1:0] wr_r;
  reg [1:0][BA-1:0] wr_base; reg [1:0][31:0] wr_data; reg [1:0][3:0] wr_be;
  reg [1:0] rd_v; wire [1:0] rd_r,resp_v; reg [1:0][PA-1:0] rd_pixel;
  reg [1:0][GA-1:0] rd_group; reg [1:0][15:0] rd_mask; reg [1:0][TW-1:0] rd_tag;
  reg [1:0] rd_use; reg [1:0][16*BAA-1:0] rd_addr; reg [1:0] resp_r;
  wire [1:0][127:0] resp_data; wire [1:0][15:0] resp_mask; wire [1:0][TW-1:0] resp_tag;
  wire [1:0] fill_active,active_valid,fill_bank,active_bank;

  genvar g;
  generate for (g=0; g<2; g=g+1) begin : G
    localparam integer NC = (g==0) ? 48 : 3;
    feature_tile_vector16_pingpong_shell #(
      .MAX_CHANNELS(NC), .MAX_IN_H(10), .MAX_IN_W(10), .BYTE_ADDR_WIDTH(BA),
      .PIXEL_ADDR_WIDTH(PA), .GROUP_ADDR_WIDTH(GA), .BANK_ADDR_WIDTH(BAA)
    ) dut (
      .clk(clk),.rst_n(rst_n),
      .fill_start_valid(fs_v[g]),.fill_start_ready(fs_r[g]),.fill_start_bank(fs_b[g]),.fill_start_epoch(fs_e[g]),.fill_start_tag(fs_t[g]),.fill_start_extent(fs_x[g]),.fill_start_resp_valid(fs_ov[g]),.fill_start_resp_ready(fs_or[g]),.fill_start_resp_ok(fs_ok[g]),.fill_start_resp_error(fs_err[g]),
      .fill_done_valid(fd_v[g]),.fill_done_ready(fd_r[g]),.fill_done_bank(fd_b[g]),.fill_done_epoch(fd_e[g]),.fill_done_tag(fd_t[g]),.fill_done_extent(fd_x[g]),.fill_done_desc_valid(fd_ov[g]),.fill_done_desc_ready(fd_or[g]),.fill_done_desc_bank(),.fill_done_desc_epoch(),.fill_done_desc_tag(),.fill_done_desc_extent(),.fill_done_ok(fd_ok[g]),.fill_done_error(fd_err[g]),
      .acquire_valid(ac_v[g]),.acquire_ready(ac_r[g]),.acquire_bank(ac_b[g]),.acquire_epoch(ac_e[g]),.acquire_tag(ac_t[g]),.acquire_extent(ac_x[g]),.active_desc_valid(ac_ov[g]),.active_desc_ready(ac_or[g]),.active_desc_bank(),.active_desc_epoch(),.active_desc_tag(),.active_desc_extent(),.acquire_ok(ac_ok[g]),.acquire_error(ac_err[g]),
      .consume_done_valid(cd_v[g]),.consume_done_ready(cd_r[g]),.consume_done_bank(cd_b[g]),.consume_done_epoch(cd_e[g]),.consume_done_tag(cd_t[g]),.consume_done_extent(cd_x[g]),.consume_done_resp_valid(cd_ov[g]),.consume_done_resp_ready(cd_or[g]),.consume_done_ok(cd_ok[g]),.consume_done_error(cd_err[g]),
      .release_valid(rel_v[g]),.release_ready(rel_r[g]),.release_bank(rel_b[g]),.release_epoch(rel_e[g]),.release_tag(rel_t[g]),.release_extent(rel_x[g]),.release_resp_valid(rel_ov[g]),.release_resp_ready(rel_or[g]),.release_ok(rel_ok[g]),.release_error(rel_err[g]),
      .wr_valid(wr_v[g]),.wr_ready(wr_r[g]),.wr_bank(wr_bank[g]),.wr_base_byte_addr(wr_base[g]),.wr_data(wr_data[g]),.wr_byte_en(wr_be[g]),
      .rd_req_valid(rd_v[g]),.rd_req_ready(rd_r[g]),.rd_pixel_idx(rd_pixel[g]),.rd_channel_group(rd_group[g]),.rd_lane_mask(rd_mask[g]),.rd_tag(rd_tag[g]),.rd_use_lane_addr(rd_use[g]),.rd_lane_addr(rd_addr[g]),.rd_resp_valid(resp_v[g]),.rd_resp_ready(resp_r[g]),.rd_data_vector(resp_data[g]),.rd_resp_lane_mask(resp_mask[g]),.rd_resp_tag(resp_tag[g]),.bank0_state(st0[g]),.bank1_state(st1[g]),.fill_active(fill_active[g]),.active_valid(active_valid[g]),.fill_bank(fill_bank[g]),.active_bank(active_bank[g])
    );
  end endgenerate

  reg [7:0] mem0 [0:4799]; reg [7:0] mem1 [0:4799]; reg [7:0] mem3a [0:299]; reg [7:0] mem3b [0:299];
  integer errors=0, checks=0, accepted_writes=0, accepted_reads=0, overlap=0;
  integer i,j,k,which,base,pix,grp,hold; reg [15:0] mask; reg [7:0] tag;
  reg [127:0] exp;

  task automatic own_start(input integer n,input integer b,input integer e,input integer t,input integer x);
    begin @(negedge clk); fs_v[n]=1;fs_b[n]=b;fs_e[n]=e;fs_t[n]=t;fs_x[n]=x; while(!fs_r[n]) @(negedge clk); @(posedge clk); #1 fs_v[n]=0; while(!fs_ov[n]) @(posedge clk); #1 if(!fs_ok[n]) errors=errors+1; fs_or[n]=1; @(posedge clk); #1 fs_or[n]=0; end
  endtask
  task automatic own_done(input integer n,input integer b,input integer e,input integer t,input integer x);
    begin @(negedge clk); fd_v[n]=1;fd_b[n]=b;fd_e[n]=e;fd_t[n]=t;fd_x[n]=x; while(!fd_r[n]) @(negedge clk); @(posedge clk); #1 fd_v[n]=0; while(!fd_ov[n]) @(posedge clk); #1 if(!fd_ok[n]) errors=errors+1; fd_or[n]=1; @(posedge clk); #1 fd_or[n]=0; end
  endtask
  task automatic own_acquire(input integer n,input integer b,input integer e,input integer t,input integer x);
    begin @(negedge clk); ac_v[n]=1;ac_b[n]=b;ac_e[n]=e;ac_t[n]=t;ac_x[n]=x; while(!ac_r[n]) @(negedge clk); @(posedge clk); #1 ac_v[n]=0; while(!ac_ov[n]) @(posedge clk); #1 if(!ac_ok[n]) errors=errors+1; ac_or[n]=1; @(posedge clk); #1 ac_or[n]=0; end
  endtask
  task automatic own_consume(input integer n,input integer b,input integer e,input integer t,input integer x);
    begin @(negedge clk); cd_v[n]=1;cd_b[n]=b;cd_e[n]=e;cd_t[n]=t;cd_x[n]=x; while(!cd_r[n]) @(negedge clk); @(posedge clk); #1 cd_v[n]=0; while(!cd_ov[n]) @(posedge clk); #1 if(!cd_ok[n]) errors=errors+1; cd_or[n]=1; @(posedge clk); #1 cd_or[n]=0; end
  endtask
  task automatic own_release(input integer n,input integer b,input integer e,input integer t,input integer x);
    begin @(negedge clk); rel_v[n]=1;rel_b[n]=b;rel_e[n]=e;rel_t[n]=t;rel_x[n]=x; while(!rel_r[n]) @(negedge clk); @(posedge clk); #1 rel_v[n]=0; while(!rel_ov[n]) @(posedge clk); #1 if(!rel_ok[n]) errors=errors+1; rel_or[n]=1; @(posedge clk); #1 rel_or[n]=0; end
  endtask

  task automatic put_word(input integer n,input integer b,input integer a,input [31:0] d,input [3:0] be);
    begin @(negedge clk); wr_v[n]=1;wr_bank[n]=b;wr_base[n]=a;wr_data[n]=d;wr_be[n]=be; while(!wr_r[n]) @(negedge clk); @(posedge clk); #1 wr_v[n]=0; accepted_writes=accepted_writes+1;
      for(j=0;j<4;j=j+1) if(be[j] && a+j < ((n==0)?4800:300)) begin
        if(n==0) begin if(b==0) mem0[a+j]=d[j*8 +: 8]; else mem1[a+j]=d[j*8 +: 8]; end
        else if(b==0) mem3a[a+j]=d[j*8 +: 8]; else mem3b[a+j]=d[j*8 +: 8];
      end
    end
  endtask

  task automatic get_vec(input integer n,input integer p,input integer q,input [15:0] m,input [7:0] tg,input integer h);
    integer c,lin; begin rd_pixel[n]=p;rd_group[n]=q;rd_mask[n]=m;rd_tag[n]=tg;rd_use[n]=0;rd_v[n]=1;resp_r[n]=0; while(!rd_r[n]) @(negedge clk); @(posedge clk); #1 rd_v[n]=0; while(!resp_v[n]) @(posedge clk); #1;
      exp=0; for(c=0;c<16;c=c+1) begin lin=p*((n==0)?48:3)+q*16+c; if(m[c] && c<((n==0)?48:3) && lin<((n==0)?4800:300)) begin
        if(n==0) exp[c*8 +: 8]=(active_bank[n]==0)?mem0[lin]:mem1[lin];
        else exp[c*8 +: 8]=(active_bank[n]==0)?mem3a[lin]:mem3b[lin];
      end end
      for(k=0;k<h;k=k+1) begin if(!resp_v[n] || resp_data[n]!==exp || resp_mask[n]!==m || resp_tag[n]!==tg) errors=errors+1; @(posedge clk); #1; end
      if(resp_data[n]!==exp || resp_mask[n]!==m || resp_tag[n]!==tg) begin errors=errors+1; if(errors<5) $display("mismatch n=%0d p=%0d q=%0d ab=%0d got=%h exp=%h gm=%h em=%h gt=%h et=%h",n,p,q,active_bank[n],resp_data[n],exp,resp_mask[n],m,resp_tag[n],tg); end checks=checks+1;accepted_reads=accepted_reads+1;resp_r[n]=1;@(posedge clk);#1;resp_r[n]=0;
    end
  endtask

  initial begin
    fs_v=0;fd_v=0;ac_v=0;cd_v=0;rel_v=0; fs_b=0;fd_b=0;ac_b=0;cd_b=0;rel_b=0; fs_e=0;fd_e=0;ac_e=0;cd_e=0;rel_e=0;fs_t=0;fd_t=0;ac_t=0;cd_t=0;rel_t=0;fs_x=0;fd_x=0;ac_x=0;cd_x=0;rel_x=0;fs_or=0;fd_or=0;ac_or=0;cd_or=0;rel_or=0;wr_v=0;wr_bank=0;wr_base=0;wr_data=0;wr_be=0;rd_v=0;rd_pixel=0;rd_group=0;rd_mask=0;rd_tag=0;rd_use=0;rd_addr=0;resp_r=0;
    for(i=0;i<4800;i=i+1) begin mem0[i]=0;mem1[i]=0;end
    for(i=0;i<300;i=i+1) begin mem3a[i]=0;mem3b[i]=0;end
    repeat(3) @(posedge clk); rst_n=1;
    /* Invalid storage commands are backpressured while ownership is FREE. */
    @(negedge clk); wr_v[0]=1;wr_bank[0]=0;wr_base[0]=0;wr_data[0]=32'hdeadbeef;wr_be[0]=15; repeat(5) @(negedge clk); if(wr_r[0]) errors=errors+1; wr_v[0]=0;
    @(negedge clk); rd_v[0]=1;rd_pixel[0]=0;rd_group[0]=0;rd_mask[0]=16'hffff;rd_tag[0]=1;repeat(5) @(negedge clk);if(rd_r[0]) errors=errors+1;rd_v[0]=0;
    own_start(0,0,1,8'h10,100); own_start(1,0,2,8'h20,100);
    /* Fill bank zero and bank one with masked/unaligned words. */
    for(i=0;i<4800;i=i+4) put_word(0,0,i,{8'h5a+i[7:0],8'h37+i[7:0],8'h13+i[7:0],8'ha5+i[7:0]},4'hf);
    for(i=0;i<300;i=i+4) put_word(1,0,i,{8'hc3+i[7:0],8'h71+i[7:0],8'h29+i[7:0],8'he7+i[7:0]},4'hf);
    put_word(0,0,1,32'h44332211,4'b1011); put_word(1,0,1,32'h78563412,4'b1101);
    own_done(0,0,1,8'h10,100); own_done(1,0,2,8'h20,100); own_acquire(0,0,1,8'h10,100); own_acquire(1,0,2,8'h20,100);
    own_start(0,1,2,8'h20,100); own_start(1,1,3,8'h30,100);
    for(i=0;i<4800;i=i+4) put_word(0,1,i,{8'h91+i[7:0],8'h46+i[7:0],8'he2+i[7:0],8'h18+i[7:0]},4'hf);
    for(i=0;i<300;i=i+4) put_word(1,1,i,{8'hd1+i[7:0],8'h5c+i[7:0],8'hb4+i[7:0],8'h2e+i[7:0]},4'hf);
    put_word(0,1,3,32'h88776655,4'b1110); put_word(1,1,3,32'hfedcba98,4'b1011);
    /* Reads from active bank while the other bank is still filling are the
     * overlap interval. */
    for(i=0;i<260;i=i+1) begin pix=$urandom_range(0,99);grp=$urandom_range(0,2);mask=$urandom;hold=$urandom_range(0,3);get_vec(0,pix,grp,mask,8'h40+i,hold); if(st0[0]==ACTIVE && st1[0]==FILL) overlap=overlap+1; end
    own_done(0,1,2,8'h20,100); own_done(1,1,3,8'h30,100);
    own_acquire(0,1,2,8'h20,100); own_acquire(1,1,3,8'h30,100);
    own_consume(0,0,1,8'h10,100); own_release(0,0,1,8'h10,100);
    own_consume(1,0,2,8'h20,100); own_release(1,0,2,8'h20,100);
    for(i=0;i<260;i=i+1) begin pix=$urandom_range(0,99);grp=$urandom_range(0,0);mask=$urandom;hold=$urandom_range(0,2);get_vec(1,pix,grp,mask,8'ha0+i,hold); if(st0[1]==FILL && st1[1]==ACTIVE) overlap=overlap+1; end
    /* Invalid descriptor is acknowledged without changing ownership. */
    @(negedge clk); fd_v[1]=1;fd_b[1]=0;fd_e[1]=0;fd_t[1]=0;fd_x[1]=0;while(!fd_r[1])@(negedge clk);@(posedge clk);#1;fd_v[1]=0;while(!fd_ov[1])@(posedge clk);#1;if(fd_ok[1])errors=errors+1;fd_or[1]=1;@(posedge clk);#1;fd_or[1]=0;
    if(!overlap || checks<500 || accepted_writes<1200 || errors) $fatal(1,"shell FAIL errors=%0d checks=%0d writes=%0d reads=%0d overlap=%0d",errors,checks,accepted_writes,accepted_reads,overlap);
    $display("feature_tile_vector16_pingpong_shell PASS checks=%0d writes=%0d reads=%0d overlap_cycles=%0d",checks,accepted_writes,accepted_reads,overlap);$finish;
  end
endmodule
`default_nettype wire
