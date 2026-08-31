`timescale 1ns/1ps
`default_nettype none

/* Randomized reference-model scoreboard for feature_tile_pingpong_ctrl. */
module tb_feature_tile_pingpong_ctrl;
    localparam integer EW=4, TW=8, XW=12;
    localparam integer FREE=0, FILL=1, READY=2, ACTIVE=3, DONE=4;
    localparam integer ERR_NONE=0, ERR_STATE=1, ERR_DESC=2;
    reg clk=0, rst_n=0;
    always #4 clk=~clk;

    reg fs_v, fd_v, ac_v, cd_v, rel_v;
    wire fs_r, fd_r, ac_r, cd_r, rel_r;
    reg fs_b, fd_b, ac_b, cd_b, rel_b;
    reg [EW-1:0] fs_e, fd_e, ac_e, cd_e, rel_e;
    reg [TW-1:0] fs_t, fd_t, ac_t, cd_t, rel_t;
    reg [XW-1:0] fs_x, fd_x, ac_x, cd_x, rel_x;
    wire fs_ov, fd_ov, ac_ov, cd_ov, rel_ov;
    reg fs_or, fd_or, ac_or, cd_or, rel_or;
    wire fs_ok, fd_ok, ac_ok, cd_ok, rel_ok;
    wire [2:0] fs_err, fd_err, ac_err, cd_err, rel_err;
    wire fd_ob, ac_ob;
    wire [EW-1:0] fd_oe, ac_oe;
    wire [TW-1:0] fd_ot, ac_ot;
    wire [XW-1:0] fd_ox, ac_ox;
    wire [2:0] s0, s1;

    feature_tile_pingpong_ctrl #(.EPOCH_WIDTH(EW),.TAG_WIDTH(TW),.EXTENT_WIDTH(XW)) dut (
      .clk(clk),.rst_n(rst_n),
      .fill_start_valid(fs_v),.fill_start_ready(fs_r),.fill_start_bank(fs_b),.fill_start_epoch(fs_e),.fill_start_tag(fs_t),.fill_start_extent(fs_x),
      .fill_start_resp_valid(fs_ov),.fill_start_resp_ready(fs_or),.fill_start_resp_ok(fs_ok),.fill_start_resp_error(fs_err),
      .fill_done_valid(fd_v),.fill_done_ready(fd_r),.fill_done_bank(fd_b),.fill_done_epoch(fd_e),.fill_done_tag(fd_t),.fill_done_extent(fd_x),
      .fill_done_desc_valid(fd_ov),.fill_done_desc_ready(fd_or),.fill_done_desc_bank(fd_ob),.fill_done_desc_epoch(fd_oe),.fill_done_desc_tag(fd_ot),.fill_done_desc_extent(fd_ox),.fill_done_ok(fd_ok),.fill_done_error(fd_err),
      .acquire_valid(ac_v),.acquire_ready(ac_r),.acquire_bank(ac_b),.acquire_epoch(ac_e),.acquire_tag(ac_t),.acquire_extent(ac_x),
      .active_desc_valid(ac_ov),.active_desc_ready(ac_or),.active_desc_bank(ac_ob),.active_desc_epoch(ac_oe),.active_desc_tag(ac_ot),.active_desc_extent(ac_ox),.acquire_ok(ac_ok),.acquire_error(ac_err),
      .consume_done_valid(cd_v),.consume_done_ready(cd_r),.consume_done_bank(cd_b),.consume_done_epoch(cd_e),.consume_done_tag(cd_t),.consume_done_extent(cd_x),
      .consume_done_resp_valid(cd_ov),.consume_done_resp_ready(cd_or),.consume_done_ok(cd_ok),.consume_done_error(cd_err),
      .release_valid(rel_v),.release_ready(rel_r),.release_bank(rel_b),.release_epoch(rel_e),.release_tag(rel_t),.release_extent(rel_x),
      .release_resp_valid(rel_ov),.release_resp_ready(rel_or),.release_ok(rel_ok),.release_error(rel_err),.bank0_state(s0),.bank1_state(s1));

    integer ms[0:1], me[0:1], mt[0:1], mx[0:1];
    integer errors=0, checks=0, accepted=0, overlap_seen=0;
    reg ffs, ffd, fac, fcd, frel;
    reg old_fs_ov, old_fd_ov, old_ac_ov, old_cd_ov, old_rel_ov;
    reg [2:0] old_fs_err, old_fd_err, old_ac_err, old_cd_err, old_rel_err;
    reg old_fs_ok, old_fd_ok, old_ac_ok, old_cd_ok, old_rel_ok;
    integer cycle, sel, b, z;

    task automatic check_stable;
      begin
        if (old_fs_ov && !fs_or && (fs_ov!==1'b1 || fs_ok!==old_fs_ok || fs_err!==old_fs_err)) errors=errors+1;
        if (old_fd_ov && !fd_or && (fd_ov!==1'b1 || fd_ok!==old_fd_ok || fd_err!==old_fd_err)) errors=errors+1;
        if (old_ac_ov && !ac_or && (ac_ov!==1'b1 || ac_ok!==old_ac_ok || ac_err!==old_ac_err)) errors=errors+1;
        if (old_cd_ov && !cd_or && (cd_ov!==1'b1 || cd_ok!==old_cd_ok || cd_err!==old_cd_err)) errors=errors+1;
        if (old_rel_ov && !rel_or && (rel_ov!==1'b1 || rel_ok!==old_rel_ok || rel_err!==old_rel_err)) errors=errors+1;
      end
    endtask

    task automatic model_one;
      integer ok, desc, st, err;
      begin
        /* Current responses are checked after the edge.  A response fired on
         * this edge is the only newly visible response (the command ready
         * bubble prevents queue overwrite). */
        check_stable();
        if (ffs) begin
          ok=(ms[fs_b]==FREE); err=ok?ERR_NONE:ERR_STATE;
          if (fs_ov!==1'b1 || fs_ok!==ok || fs_err!==err) errors=errors+1;
          if (ok) begin ms[fs_b]=FILL; me[fs_b]=fs_e; mt[fs_b]=fs_t; mx[fs_b]=fs_x; end
          accepted=accepted+1;
        end
        if (ffd) begin
          st=(ms[fd_b]==FILL); desc=(me[fd_b]==fd_e && mt[fd_b]==fd_t && mx[fd_b]==fd_x); ok=st&&desc; err=!st?ERR_STATE:(desc?ERR_NONE:ERR_DESC);
          if (fd_ov!==1'b1 || fd_ok!==ok || fd_err!==err || fd_ob!==fd_b || fd_oe!==fd_e || fd_ot!==fd_t || fd_ox!==fd_x) errors=errors+1;
          if (ok) ms[fd_b]=READY; accepted=accepted+1;
        end
        if (fac) begin
          st=(ms[ac_b]==READY); desc=(me[ac_b]==ac_e && mt[ac_b]==ac_t && mx[ac_b]==ac_x); ok=st&&desc; err=!st?ERR_STATE:(desc?ERR_NONE:ERR_DESC);
          if (ac_ov!==1'b1 || ac_ok!==ok || ac_err!==err || ac_ob!==ac_b || ac_oe!==ac_e || ac_ot!==ac_t || ac_ox!==ac_x) errors=errors+1;
          if (ok) ms[ac_b]=ACTIVE; accepted=accepted+1;
        end
        if (fcd) begin
          st=(ms[cd_b]==ACTIVE); desc=(me[cd_b]==cd_e && mt[cd_b]==cd_t && mx[cd_b]==cd_x); ok=st&&desc; err=!st?ERR_STATE:(desc?ERR_NONE:ERR_DESC);
          if (cd_ov!==1'b1 || cd_ok!==ok || cd_err!==err) errors=errors+1;
          if (ok) ms[cd_b]=DONE; accepted=accepted+1;
        end
        if (frel) begin
          st=(ms[rel_b]==DONE); desc=(me[rel_b]==rel_e && mt[rel_b]==rel_t && mx[rel_b]==rel_x); ok=st&&desc; err=!st?ERR_STATE:(desc?ERR_NONE:ERR_DESC);
          if (rel_ov!==1'b1 || rel_ok!==ok || rel_err!==err) errors=errors+1;
          if (ok) begin ms[rel_b]=FREE; me[rel_b]=0; mt[rel_b]=0; mx[rel_b]=0; end accepted=accepted+1;
        end
        if (s0!==ms[0] || s1!==ms[1]) errors=errors+1;
        if ((ms[0]==ACTIVE && ms[1]==FILL) || (ms[1]==ACTIVE && ms[0]==FILL)) overlap_seen=1;
        checks=checks+1;
        old_fs_ov=fs_ov; old_fd_ov=fd_ov; old_ac_ov=ac_ov; old_cd_ov=cd_ov; old_rel_ov=rel_ov;
        old_fs_ok=fs_ok; old_fd_ok=fd_ok; old_ac_ok=ac_ok; old_cd_ok=cd_ok; old_rel_ok=rel_ok;
        old_fs_err=fs_err; old_fd_err=fd_err; old_ac_err=ac_err; old_cd_err=cd_err; old_rel_err=rel_err;
      end
    endtask

    initial begin
      fs_v=0;fd_v=0;ac_v=0;cd_v=0;rel_v=0; fs_b=0;fd_b=0;ac_b=0;cd_b=0;rel_b=0;
      fs_e=0;fd_e=0;ac_e=0;cd_e=0;rel_e=0; fs_t=0;fd_t=0;ac_t=0;cd_t=0;rel_t=0; fs_x=0;fd_x=0;ac_x=0;cd_x=0;rel_x=0;
      fs_or=0;fd_or=0;ac_or=0;cd_or=0;rel_or=0; ms[0]=FREE;ms[1]=FREE;me[0]=0;me[1]=0;mt[0]=0;mt[1]=0;mx[0]=0;mx[1]=0;
      old_fs_ov=0;old_fd_ov=0;old_ac_ov=0;old_cd_ov=0;old_rel_ov=0;
      repeat(3) @(posedge clk); rst_n=1;
      for (cycle=0; cycle<900; cycle=cycle+1) begin
        @(negedge clk);
        /* Mostly issue the operation implied by the model, with frequent
         * stale/random descriptors to exercise all rejection paths. */
        fs_v=0;fd_v=0;ac_v=0;cd_v=0;rel_v=0;
        fs_or=($urandom_range(0,3)!=0); fd_or=($urandom_range(0,3)!=0); ac_or=($urandom_range(0,3)!=0); cd_or=($urandom_range(0,3)!=0); rel_or=($urandom_range(0,3)!=0);
        sel=$urandom_range(0,4); b=$urandom_range(0,1);
        if (sel==0) begin fs_v=1;fs_b=b;fs_e=$urandom;fs_t=$urandom;fs_x=$urandom_range(1,4095); if ($urandom_range(0,4)!=0 && ms[b]==FREE) begin fs_e=(cycle+b+1)&15;fs_t=(cycle*7+b)&255;fs_x=100+b; end end
        if (sel==1) begin fd_v=1;fd_b=b;fd_e=$urandom;fd_t=$urandom;fd_x=$urandom; if ($urandom_range(0,3)!=0 && ms[b]==FILL) begin fd_e=me[b];fd_t=mt[b];fd_x=mx[b]; end end
        if (sel==2) begin ac_v=1;ac_b=b;ac_e=$urandom;ac_t=$urandom;ac_x=$urandom; if ($urandom_range(0,3)!=0 && ms[b]==READY) begin ac_e=me[b];ac_t=mt[b];ac_x=mx[b]; end end
        if (sel==3) begin cd_v=1;cd_b=b;cd_e=$urandom;cd_t=$urandom;cd_x=$urandom; if ($urandom_range(0,3)!=0 && ms[b]==ACTIVE) begin cd_e=me[b];cd_t=mt[b];cd_x=mx[b]; end end
        if (sel==4) begin rel_v=1;rel_b=b;rel_e=$urandom;rel_t=$urandom;rel_x=$urandom; if ($urandom_range(0,3)!=0 && ms[b]==DONE) begin rel_e=me[b];rel_t=mt[b];rel_x=mx[b]; end end
        ffs=fs_v&&fs_r; ffd=fd_v&&fd_r; fac=ac_v&&ac_r; fcd=cd_v&&cd_r; frel=rel_v&&rel_r;
        @(posedge clk); #1; model_one();
      end
      if (!overlap_seen) errors=errors+1;
      if (accepted < 100) errors=errors+1;
      if (errors) $fatal(1,"feature_tile_pingpong_ctrl FAIL errors=%0d checks=%0d accepted=%0d overlap=%0d",errors,checks,accepted,overlap_seen);
      $display("feature_tile_pingpong_ctrl PASS checks=%0d accepted=%0d overlap=%0d",checks,accepted,overlap_seen); $finish;
    end
endmodule
`default_nettype wire
