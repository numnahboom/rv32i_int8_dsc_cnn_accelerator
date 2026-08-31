`timescale 1ns/1ps
`default_nettype none

module tb_native_word_response_pipe_vector16_shell;
  localparam integer N=2, EW=4, TW=8, XW=16;
  reg clk=0, rst_n=0; always #4 clk=~clk;
  reg [1:0] fs_v,fs_b,fs_or,fd_or,ac_or,cd_or,rel_or,rd_v,rd_or;
  wire [1:0] fs_r,fs_ov,fd_ov,ac_r,ac_ov,cd_r,cd_ov,rel_r,rel_ov,rd_r,rd_ov;
  reg [1:0][EW-1:0] fs_e; reg [1:0][TW-1:0] fs_t; reg [1:0][XW-1:0] fs_x;
  reg [1:0][23:0] fs_base; reg [1:0][31:0] fs_words;
  wire [1:0] fs_ok; wire [1:0][2:0] fs_err;
  wire [1:0][2:0] fd_err,ac_err,cd_err,rel_err;
  wire [1:0] fd_db,fd_ok,ac_ok,cd_ok,rel_ok;
  wire [1:0][EW-1:0] fd_de,ac_de; wire [1:0][TW-1:0] fd_dt,ac_dt; wire [1:0][XW-1:0] fd_dx,ac_dx;
  reg [1:0] ac_v,ac_b; reg [1:0][EW-1:0] ac_e; reg [1:0][TW-1:0] ac_t; reg [1:0][XW-1:0] ac_x;
  reg [1:0] cd_v,cd_b,rel_v,rel_b; reg [1:0][EW-1:0] cd_e,rel_e; reg [1:0][TW-1:0] cd_t,rel_t; reg [1:0][XW-1:0] cd_x,rel_x;
  wire [1:0] mem_req_v; reg [1:0] mem_req_r; wire [1:0][23:0] mem_req_a; reg [1:0] mem_resp_v, stale_v; reg [1:0][31:0] mem_resp_d, stale_d;
  wire [1:0] done_v,done_b,active_b; wire [1:0][EW-1:0] done_e; wire [1:0][TW-1:0] done_t; wire [1:0][XW-1:0] done_x; wire [1:0][2:0] done_err; wire [1:0] done_ok;
  wire [1:0] done_drain_clean;
  reg [1:0][6:0] rd_p; reg [1:0][1:0] rd_g; reg [1:0][15:0] rd_m; reg [1:0][TW-1:0] rd_t;
  wire [1:0][127:0] rd_d; wire [1:0][15:0] rd_rm; wire [1:0][TW-1:0] rd_rt;
  wire [1:0][2:0] st0,st1; wire [1:0][31:0] issue_count,response_count,stale_count;
  wire [1:0] fill_done_pipe_unused;
  integer NC [0:1]; integer i,j,n,c,p,g,errors=0,checks=0,cycles=0,req_streak=0,max_req_streak=0,vec_streak=0,max_vec_streak=0;
  reg [3:0] delay_v[0:1]; reg [31:0] delay_d[0:1][0:3];
  assign NC[0]=3; assign NC[1]=48;

  genvar k;
  generate for(k=0;k<2;k=k+1) begin : G
    native_word_response_pipe_vector16_shell #(.MAX_CHANNELS(k==0?3:48),.MAX_IN_H(10),.MAX_IN_W(10),.FIFO_DEPTH(64)) dut (
      .clk(clk),.rst_n(rst_n),.fill_start_valid(fs_v[k]),.fill_start_ready(fs_r[k]),.fill_bank(fs_b[k]),.fill_epoch(fs_e[k]),.fill_tag(fs_t[k]),.fill_extent(fs_x[k]),.fill_base_byte_addr(fs_base[k]),.fill_word_count(fs_words[k]),
      .fill_start_resp_valid(fs_ov[k]),.fill_start_resp_ready(fs_or[k]),.fill_start_resp_ok(fs_ok[k]),.fill_start_resp_error(fs_err[k]),.mem_req_valid(mem_req_v[k]),.mem_req_ready(mem_req_r[k]),.mem_req_addr(mem_req_a[k]),.mem_rvalid(mem_resp_v[k]|stale_v[k]),.mem_rdata(stale_v[k]?stale_d[k]:mem_resp_d[k]),
      .fill_done_desc_valid(done_v[k]),.fill_done_desc_ready(fd_or[k]),.fill_done_desc_bank(done_b[k]),.fill_done_desc_epoch(done_e[k]),.fill_done_desc_tag(done_t[k]),.fill_done_desc_extent(done_x[k]),.fill_done_ok(done_ok[k]),.fill_done_error(done_err[k]),
      .acquire_valid(ac_v[k]),.acquire_ready(ac_r[k]),.acquire_bank(ac_b[k]),.acquire_epoch(ac_e[k]),.acquire_tag(ac_t[k]),.acquire_extent(ac_x[k]),.active_desc_valid(ac_ov[k]),.active_desc_ready(ac_or[k]),.active_desc_bank(),.active_desc_epoch(),.active_desc_tag(),.active_desc_extent(),.acquire_ok(ac_ok[k]),.acquire_error(ac_err[k]),
      .consume_done_valid(cd_v[k]),.consume_done_ready(cd_r[k]),.consume_done_bank(cd_b[k]),.consume_done_epoch(cd_e[k]),.consume_done_tag(cd_t[k]),.consume_done_extent(cd_x[k]),.consume_done_resp_valid(cd_ov[k]),.consume_done_resp_ready(cd_or[k]),.consume_done_ok(cd_ok[k]),.consume_done_error(cd_err[k]),
      .release_valid(rel_v[k]),.release_ready(rel_r[k]),.release_bank(rel_b[k]),.release_epoch(rel_e[k]),.release_tag(rel_t[k]),.release_extent(rel_x[k]),.release_resp_valid(rel_ov[k]),.release_resp_ready(rel_or[k]),.release_ok(rel_ok[k]),.release_error(rel_err[k]),
      .rd_req_valid(rd_v[k]),.rd_req_ready(rd_r[k]),.rd_pixel_idx(rd_p[k]),.rd_channel_group(rd_g[k]),.rd_lane_mask(rd_m[k]),.rd_tag(rd_t[k]),.rd_resp_valid(rd_ov[k]),.rd_resp_ready(rd_or[k]),.rd_data_vector(rd_d[k]),.rd_resp_lane_mask(rd_rm[k]),.rd_resp_tag(rd_rt[k]),.bank0_state(st0[k]),.bank1_state(st1[k]),.active_bank(active_b[k]));
    assign done_drain_clean[k] = done_b[k] ?
      (!dut.u_shell.u_bank1.wr_active && !dut.u_shell.u_bank1.wr_bypass_valid) :
      (!dut.u_shell.u_bank0.wr_active && !dut.u_shell.u_bank0.wr_bypass_valid);
  end endgenerate

  function [7:0] source_byte(input integer a); source_byte=(a*13+8'h37)&8'hff; endfunction
  function [31:0] source_word(input integer a); source_word={source_byte(a+3),source_byte(a+2),source_byte(a+1),source_byte(a)}; endfunction

  generate for(k=0;k<2;k=k+1) begin : M
    always @(posedge clk) begin : MEM
      if(!rst_n) begin delay_v[k]<=0;mem_resp_v[k]<=0;mem_resp_d[k]<=0;delay_d[k][0]<=0;delay_d[k][1]<=0;delay_d[k][2]<=0;delay_d[k][3]<=0;end
      else begin
        delay_v[k] <= {delay_v[k][2:0],mem_req_v[k]&&mem_req_r[k]};
        if(mem_req_v[k]&&mem_req_r[k]) delay_d[k][0] <= source_word(mem_req_a[k]);
        delay_d[k][1] <= delay_d[k][0]; delay_d[k][2] <= delay_d[k][1]; delay_d[k][3] <= delay_d[k][2];
        mem_resp_v[k] <= delay_v[k][3]; mem_resp_d[k] <= delay_d[k][3];
      end
    end
  end endgenerate
  always @(negedge clk) begin if(!rst_n) begin mem_req_r<=0; end else begin mem_req_r[0]<=1;mem_req_r[1]<= (($urandom%11)!=2); end end
  always @(posedge clk) if(rst_n) begin
    cycles=cycles+1;
    for (c=0;c<2;c=c+1)
      if (done_v[c] && done_ok[c] && !done_drain_clean[c])
        errors=errors+1;
    if(mem_req_v[1]&&mem_req_r[1]) req_streak=req_streak+1;
    else begin if(req_streak>max_req_streak)max_req_streak=req_streak;req_streak=0;end
  end

  task automatic start_fill(input integer z,input integer b,input integer ep,input integer tg,input integer ex,input integer words);
    begin @(negedge clk);fs_v[z]=1;fs_b[z]=b;fs_e[z]=ep;fs_t[z]=tg;fs_x[z]=ex;fs_base[z]=0;fs_words[z]=words;while(!fs_r[z])@(negedge clk);@(posedge clk);#1;fs_v[z]=0; end
  endtask
  task automatic wait_done(input integer z,input integer b,input integer ep,input integer tg,input integer ex);
    begin while(!done_v[z])@(posedge clk);#1;if(!done_ok[z]||done_b[z]!==b||done_e[z]!==ep||done_t[z]!==tg||done_x[z]!==ex)errors=errors+1; end
  endtask
  task automatic acquire_tile(input integer z,input integer b,input integer ep,input integer tg,input integer ex);
    begin @(negedge clk);ac_v[z]=1;ac_b[z]=b;ac_e[z]=ep;ac_t[z]=tg;ac_x[z]=ex;while(!ac_r[z])@(negedge clk);@(posedge clk);#1;ac_v[z]=0; end
  endtask
  task automatic read_vec(input integer z,input integer pix,input integer grp,input [15:0] mask,input integer tg);
    integer cc,lin; reg [127:0] expected;
    begin @(negedge clk);rd_p[z]=pix;rd_g[z]=grp;rd_m[z]=mask;rd_t[z]=tg;rd_v[z]=1;while(!rd_r[z])@(negedge clk);@(posedge clk);#1;rd_v[z]=0;while(!rd_ov[z])@(posedge clk);#1;expected=0;for(cc=0;cc<16;cc=cc+1)begin lin=pix*NC[z]+grp*16+cc;if(mask[cc]&&cc<NC[z])expected[cc*8 +: 8]=source_byte(lin);end if(rd_d[z]!==expected)begin errors=errors+1;if(errors<5)$display("vector mismatch z=%0d p=%0d g=%0d got=%h exp=%h",z,pix,grp,rd_d[z],expected);end checks=checks+1;rd_or[z]=1;@(posedge clk);#1;rd_or[z]=0;end
  endtask
  task automatic finish_tile(input integer z,input integer b,input integer ep,input integer tg,input integer ex);
    begin @(negedge clk);cd_v[z]=1;cd_b[z]=b;cd_e[z]=ep;cd_t[z]=tg;cd_x[z]=ex;while(!cd_r[z])@(negedge clk);@(posedge clk);#1;cd_v[z]=0;@(negedge clk);rel_v[z]=1;rel_b[z]=b;rel_e[z]=ep;rel_t[z]=tg;rel_x[z]=ex;while(!rel_r[z])@(negedge clk);@(posedge clk);#1;rel_v[z]=0;end
  endtask

  initial begin
    fs_v=0;fs_b=0;fs_or=2'b11;fd_or=2'b11;ac_v=0;ac_or=2'b11;cd_v=0;cd_or=2'b11;rel_v=0;rel_or=2'b11;rd_v=0;rd_or=2'b11;stale_v=0;stale_d=0;rd_p=0;rd_g=0;rd_m=0;rd_t=0;fs_e=0;fs_t=0;fs_x=0;fs_base=0;fs_words=0;ac_b=0;ac_e=0;ac_t=0;ac_x=0;cd_b=0;cd_e=0;cd_t=0;cd_x=0;rel_b=0;rel_e=0;rel_t=0;rel_x=0;
    repeat(3)@(posedge clk);rst_n=1;
    for(n=0;n<2;n=n+1) begin
      start_fill(n,0,n+1,8'h20+n,16'h300+n,(n==0)?75:1200);wait_done(n,0,n+1,8'h20+n,16'h300+n);acquire_tile(n,0,n+1,8'h20+n,16'h300+n);
      for(i=0;i<100;i=i+1) read_vec(n,i,(n==0)?0:(i%3),16'hffff,i);
      stale_v[n]=1;stale_d[n]=32'hface0000+n;@(negedge clk);stale_v[n]=0;
      fork : FILL_OVERLAP
        begin start_fill(n,1,n+3,8'h40+n,16'h500+n,(n==0)?75:1200);end
        begin for(j=0;j<80;j=j+1) read_vec(n,j%100,(n==0)?0:(j%3),$urandom,j+1000); end
      join
      acquire_tile(n,1,n+3,8'h40+n,16'h500+n);finish_tile(n,0,n+1,8'h20+n,16'h300+n);finish_tile(n,1,n+3,8'h40+n,16'h500+n);
      if (n==0) begin rst_n=0; repeat(3) @(posedge clk); rst_n=1; end
    end
    if(max_req_streak<52 || errors)
      $fatal(1,"composition FAIL errors=%0d checks=%0d max_req_streak=%0d",errors,checks,max_req_streak);
    $display("PASS tb_native_word_response_pipe_vector16_shell checks=%0d errors=%0d max_req_streak=%0d cycles=%0d",checks,errors,max_req_streak,cycles);$finish;
  end
  initial begin repeat(20000)@(posedge clk);$display("WATCHDOG cycles=%0d fs_r=%b fs_v=%b fs_ov=%b st=%b/%b memv=%b memresp=%b pipeact=%b words=%0d idx=%0d tok=%0d cmd=%0d respct=%0d pending=%b shellfdready=%b shellfsready=%b",cycles,fs_r,fs_v,fs_ov,st0,st1,mem_req_v,mem_resp_v,G[0].dut.u_pipe.fill_active,G[0].dut.u_pipe.fill_word_count_reg,G[0].dut.u_pipe.issue_index_reg,G[0].dut.u_pipe.tok_count,G[0].dut.u_pipe.cmd_count,G[0].dut.u_pipe.response_count,G[0].dut.done_pending_reg,G[0].dut.u_shell.fill_done_ready,G[0].dut.u_shell.fill_start_ready);$fatal(1,"WATCHDOG");end
endmodule
`default_nettype wire
