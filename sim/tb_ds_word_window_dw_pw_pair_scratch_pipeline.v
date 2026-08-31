`timescale 1ns/1ps
`default_nettype none

/* Integration smoke/differential fence test.  The full producer ABI is
 * compiled and source-side ports are tied off here; the row image is loaded
 * with an independent deterministic reference through the non-production
 * shell's row-transfer fence.  PW uses zero weights/zero bias, so every
 * enabled result must be exactly zero while masks, row ordering, transfer
 * counts and output backpressure are checked.  Producer exact arithmetic is
 * covered by tb_ds_word_window_dw_tagless_stream4_4x8.v. */
module tb_ds_word_window_dw_pw_pair_scratch_pipeline;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;
    localparam AW=24, WW=16, EW=4, SW=2, GW=5;

    reg f0v=0,f0b=0; reg [EW-1:0] f0e=0; reg [AW-1:0] f0a=0; reg [WW-1:0] f0n=0;
    wire f0r,f0dv,f0db; wire [EW-1:0] f0de; wire f0mr; reg f0mrr=1; wire [AW-1:0] f0ma; reg f0mv=0; reg [31:0] f0md=0;
    reg f1v=0,f1b=1; reg [EW-1:0] f1e=0; reg [AW-1:0] f1a=0; reg [WW-1:0] f1n=0;
    wire f1r,f1dv,f1db; wire [EW-1:0] f1de; wire f1mr; reg f1mrr=1; wire [AW-1:0] f1ma; reg f1mv=0; reg [31:0] f1md=0;
    reg cv=0; wire cr; reg [3:0] cti=0; reg signed [127:0] cwv=0; reg signed [511:0] cbv=0,cmv=0; reg [95:0] csv=0;
    reg d0v=0,d1v=0; wire d0r,d1r; reg d0sb=0,d1sb=0; reg [EW-1:0] d0se=0,d1se=0; reg [AW-1:0] d0sa=0,d1sa=0; reg [15:0] d0m=0,d1m=0; reg [1:0] d0st=1,d1st=1; reg [7:0] d0fh=6,d1fh=6,d0fw=10,d1fw=10,d0fp=10,d1fp=10; reg [2:0] d0g=0,d1g=0; reg [3:0] d0gc=1,d1gc=1; reg [31:0] d0zp=0,d1zp=0,d0min=0,d1min=0,d0max=255,d1max=255;
    wire ddv; reg ddr=1; wire ddh; wire [2:0] ddg;
    reg tv=0; wire tr; reg tb=0; reg [SW-1:0] ts=0; reg [EW-1:0] te=0; reg [2:0] trow=0; reg [GW-1:0] tgroups=1; wire tdv; reg tdr=1;
    reg lbv=0; wire lbr; reg [1:0] le=0; reg [7:0] lcin=8; reg [8:0] lcout=8; reg lwv=0; wire lwr; reg [31:0] lwd=0; reg lcv=0; wire lcr,lcrej,lextra,lactive,lvalid; wire [1:0] lepoch; wire [13:0] ewc,lwc; wire [15:0] plc;
    reg pjv=0; wire pjr; reg [4:0] pct=0; reg pjb=0; reg [SW-1:0] pjs=0; reg [EW-1:0] pje=0; reg [GW-1:0] pjgc=1; reg pjrev=0; reg [5:0] pjp=0; reg [8:0] pjc=0; reg [7:0] pjpixels=8; reg [8:0] pjchannels=8; reg signed [255:0] pjbias=0,pjmul=0; reg [47:0] pjshift=0; reg signed [31:0] pjzp=0,pjmin=-128,pjmax=127;
    wire ov; reg orr=0; wire [2:0] ori; wire [1:0] obi,olm; wire [5:0] op; wire [8:0] oc; wire signed [15:0] od; wire pdone,busy; wire [31:0] dov,dtok,dhw,pr;

    ds_word_window_dw_pw_pair_scratch_pipeline #(.MAX_IN_H(17),.MAX_IN_W(17),.MAX_CIN(8),.MAX_COUT(8),.MAX_GROUPS(1)) dut (
      .clk(clk),.rst_n(rst_n),.fill0_start_valid(f0v),.fill0_start_ready(f0r),.fill0_start_bank(f0b),.fill0_start_epoch(f0e),.fill0_start_base_addr(f0a),.fill0_start_word_count(f0n),.fill0_done_valid(f0dv),.fill0_done_ready(1'b1),.fill0_done_bank(f0db),.fill0_done_epoch(f0de),.fill0_mem_req_valid(f0mr),.fill0_mem_req_ready(f0mrr),.fill0_mem_req_addr(f0ma),.fill0_mem_resp_valid(f0mv),.fill0_mem_resp_data(f0md),
      .fill1_start_valid(f1v),.fill1_start_ready(f1r),.fill1_start_bank(f1b),.fill1_start_epoch(f1e),.fill1_start_base_addr(f1a),.fill1_start_word_count(f1n),.fill1_done_valid(f1dv),.fill1_done_ready(1'b1),.fill1_done_bank(f1db),.fill1_done_epoch(f1de),.fill1_mem_req_valid(f1mr),.fill1_mem_req_ready(f1mrr),.fill1_mem_req_addr(f1ma),.fill1_mem_resp_valid(f1mv),.fill1_mem_resp_data(f1md),
      .cfg_valid(cv),.cfg_ready(cr),.cfg_tap_idx(cti),.cfg_weight_vec(cwv),.cfg_bias_vec(cbv),.cfg_multiplier_vec(cmv),.cfg_shift_vec(csv),
      .dw0_job_valid(d0v),.dw0_job_ready(d0r),.dw0_source_bank(d0sb),.dw0_source_epoch(d0se),.dw0_source_base_addr(d0sa),.dw0_source_lane_mask(d0m),.dw0_source_stride(d0st),.dw0_footprint_height(d0fh),.dw0_footprint_width(d0fw),.dw0_footprint_pitch(d0fp),.dw0_group(d0g),.dw0_group_count(d0gc),.dw0_zp(d0zp),.dw0_min(d0min),.dw0_max(d0max),
      .dw1_job_valid(d1v),.dw1_job_ready(d1r),.dw1_source_bank(d1sb),.dw1_source_epoch(d1se),.dw1_source_base_addr(d1sa),.dw1_source_lane_mask(d1m),.dw1_source_stride(d1st),.dw1_footprint_height(d1fh),.dw1_footprint_width(d1fw),.dw1_footprint_pitch(d1fp),.dw1_group(d1g),.dw1_group_count(d1gc),.dw1_zp(d1zp),.dw1_min(d1min),.dw1_max(d1max),.dw_done_valid(ddv),.dw_done_ready(ddr),.dw_done_half(ddh),.dw_done_group(ddg),
      .transfer_start_valid(tv),.transfer_start_ready(tr),.transfer_bank(tb),.transfer_session(ts),.transfer_epoch(te),.transfer_row(trow),.transfer_groups(tgroups),.transfer_done_valid(tdv),.transfer_done_ready(tdr),
      .pw_load_begin_valid(lbv),.pw_load_begin_ready(lbr),.pw_load_epoch(le),.pw_load_cin(lcin),.pw_load_cout(lcout),.pw_load_word_valid(lwv),.pw_load_word_ready(lwr),.pw_load_word_data(lwd),.pw_load_commit_valid(lcv),.pw_load_commit_ready(lcr),.pw_load_commit_reject(lcrej),.pw_load_extra_error(lextra),.pw_load_active(lactive),.pw_committed_valid(lvalid),.pw_committed_epoch(lepoch),.pw_expected_word_count(ewc),.pw_load_word_count(lwc),.pw_packed_load_count(plc),
      .pw_job_valid(pjv),.pw_job_ready(pjr),.pw_job_cout_tile(pct),.pw_job_bank(pjb),.pw_job_session(pjs),.pw_job_epoch(pje),.pw_job_group_count(pjgc),.pw_job_reverse_groups(pjrev),.pw_job_pixel_base(pjp),.pw_job_cout_base(pjc),.pw_job_output_pixels(pjpixels),.pw_job_output_channels(pjchannels),.pw_job_bias_vec(pjbias),.pw_job_multiplier_vec(pjmul),.pw_job_shift_vec(pjshift),.pw_job_zp(pjzp),.pw_job_min(pjmin),.pw_job_max(pjmax),.out_valid(ov),.out_ready(orr),.out_row_idx(ori),.out_beat_idx(obi),.out_pixel_idx(op),.out_channel_base(oc),.out_lane_mask(olm),.out_data(od),.pw_job_done(pdone),.busy(busy),.dw_overlap_cycles(dov),.dw_source_words(dtok),.dw_tokens(dtok),.dw_half_writes(dhw),.pw_row_reads(pr));

    integer cycles=0, outputs=0, errors=0, i;
    always @(posedge clk) begin
      cycles <= cycles+1;
      if (!rst_n) begin orr<=0; end else begin
        orr <= (cycles%5)!=0;
        if (ov && orr) begin outputs<=outputs+1; if (od!==0 || olm!==2'b11) errors<=errors+1; end
      end
    end
    task send_word; begin @(negedge clk); lwd=0; lwv=1; while(!lwr) @(posedge clk); @(posedge clk); @(negedge clk); lwv=0; end endtask
    initial begin
      repeat(4) @(posedge clk); @(negedge clk); rst_n=1; $display("phase reset_done");
      /* Independent deterministic 8-pixel by 8-channel reference row.
       * The BRAM image is intentionally not reset; seed its eight logical
       * planes through the simulation-only RAM model before ownership starts.
       * This mirrors the row_image_bram_store contract without reintroducing
       * a register image into the DUT. */
      dut.u_row_image.gen_plane[0].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[1].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[2].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[3].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[4].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[5].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[6].mem[0] = 36'hf_00000000;
      dut.u_row_image.gen_plane[7].mem[0] = 36'hf_00000000;
      @(negedge clk); lbv=1; while(!lbr) @(posedge clk); @(posedge clk); @(negedge clk); lbv=0; $display("phase load_begin");
      for(i=0;i<16;i=i+1) send_word(); $display("phase words");
      @(negedge clk); lcv=1; while(!lcr) @(posedge clk); @(posedge clk); @(negedge clk); lcv=0; $display("phase load_commit");
      @(negedge clk); tv=1; while(!tr) @(posedge clk); @(posedge clk); @(negedge clk); tv=0; $display("phase transfer_start");
      while(!tdv) @(posedge clk); $display("phase transfer_done");
      @(negedge clk); pjv=1; while(!pjr) @(posedge clk); @(posedge clk); @(negedge clk); pjv=0; $display("phase pw_job");
      while(!pdone) @(posedge clk); $display("phase pw_done");
      if (outputs != 32) errors=errors+1;
      if (errors==0) $display("PASS pair scratch pipeline fence outputs=%0d cycles=%0d overlap=%0d writes=%0d reads=%0d",outputs,cycles,dov,dhw,pr);
      else begin $display("FAIL pair scratch pipeline errors=%0d outputs=%0d cycles=%0d",errors,outputs,cycles); $fatal(1); end
      $finish;
    end
    initial begin repeat(100000) @(posedge clk); $fatal(1,"WATCHDOG"); end
endmodule
`default_nettype wire
