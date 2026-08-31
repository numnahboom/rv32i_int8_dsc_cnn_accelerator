`timescale 1ns/1ps
`default_nettype none

/*
 * Real-producer integration regression for the single-producer DS/PW shell.
 * Unlike the original row-image seeded smoke, this test fills the producer's
 * source BRAM with a three-cycle response stream, configures all nine DW taps,
 * runs both 4x8 halves, and checks the resulting row-image transfer fence.
 *
 * After the first pair has been transferred to the PW scratch bank, a second
 * source fill and DW job are launched in the same window as the PW job.  The
 * test therefore observes actual producer/PW overlap rather than an overlap
 * counter driven by seeded image data.  All source data and weights are zero,
 * so every enabled PW result must be zero while masks, counts, handshakes and
 * output stability remain independently checked.
 */
module tb_ds_word_window_dw_pw_single_producer_pipeline_overlap;
    localparam integer AW=24, WW=16, EW=4, SW=2, GW=5;
    localparam integer FH=6, FW=10, WORDS=FH*FW*4;
    localparam integer BASE0=24'h100000, BASE1=24'h200000;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;

    reg f0v=0, f0b=0; reg [EW-1:0] f0e=0;
    reg [AW-1:0] f0a=0; reg [WW-1:0] f0n=WORDS;
    wire f0r, f0dv, f0db; wire [EW-1:0] f0de;
    wire f0mr; reg f0mrr=1; wire [AW-1:0] f0ma;
    reg f0mv=0; reg [31:0] f0md=0;
    /* The single-producer shell intentionally leaves the compatibility
     * fill1/compute1 ports inactive. */
    reg f1v=0, f1b=1; reg [EW-1:0] f1e=0;
    reg [AW-1:0] f1a=0; reg [WW-1:0] f1n=0;
    wire f1r, f1dv, f1db; wire [EW-1:0] f1de;
    wire f1mr; reg f1mrr=1; wire [AW-1:0] f1ma;
    reg f1mv=0; reg [31:0] f1md=0;

    reg cv=0; wire cr; reg [3:0] cti=0;
    reg signed [127:0] cwv=0;
    reg signed [511:0] cbv=0, cmv=0;
    reg [95:0] csv=0;

    reg d0v=0, d1v=0; wire d0r, d1r;
    reg d0sb=0, d1sb=0; reg [EW-1:0] d0se=0, d1se=0;
    reg [AW-1:0] d0sa=0, d1sa=0; reg [15:0] d0m=16'hffff, d1m=16'hffff;
    reg [1:0] d0st=1, d1st=1;
    reg [7:0] d0fh=FH,d1fh=FH,d0fw=FW,d1fw=FW,d0fp=FW,d1fp=FW;
    reg [2:0] d0g=0,d1g=0; reg [3:0] d0gc=1,d1gc=1;
    reg [31:0] d0zp=0,d1zp=0,d0min=0,d1min=0,d0max=255,d1max=255;
    wire ddv; reg ddr=1; wire ddh; wire [2:0] ddg;

    reg tv=0; wire tr; reg tb=0; reg [SW-1:0] ts=0;
    reg [EW-1:0] te=1; reg [2:0] trow=0; reg [GW-1:0] tgroups=1;
    wire tdv; reg tdr=1;

    reg lbv=0; wire lbr; reg [1:0] le=0; reg [7:0] lcin=8, lcout=8;
    reg lwv=0; wire lwr; reg [31:0] lwd=0; reg lcv=0;
    wire lcr,lcrej,lextra,lactive,lvalid; wire [1:0] lepoch;
    wire [13:0] ewc,lwc; wire [15:0] plc;

    reg pjv=0; wire pjr; reg [4:0] pct=0; reg pjb=0;
    reg [SW-1:0] pjs=0; reg [EW-1:0] pje=0; reg [GW-1:0] pjgc=1;
    reg pjrev=0; reg [5:0] pjp=0; reg [8:0] pjc=0;
    reg [7:0] pjpixels=8; reg [8:0] pjchannels=8;
    reg signed [255:0] pjbias=0,pjmul=0; reg [47:0] pjshift=0;
    reg signed [31:0] pjzp=0,pjmin=-128,pjmax=127;
    wire ov; reg orr=0; wire [2:0] ori; wire [1:0] obi,olm;
    wire [5:0] op; wire [8:0] oc; wire signed [15:0] od;
    wire pdone,busy; wire [31:0] dov,dsrc,dtok,dhw,pr;

    ds_word_window_dw_pw_single_producer_pipeline #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CIN(8), .MAX_COUT(8),
        .MAX_GROUPS(1), .REQUIRE_BOTH_HALVES(1)
    ) dut (
      .clk(clk),.rst_n(rst_n),
      .fill0_start_valid(f0v),.fill0_start_ready(f0r),.fill0_start_bank(f0b),
      .fill0_start_epoch(f0e),.fill0_start_base_addr(f0a),
      .fill0_start_word_count(f0n),.fill0_done_valid(f0dv),
      .fill0_done_ready(1'b1),.fill0_done_bank(f0db),.fill0_done_epoch(f0de),
      .fill0_mem_req_valid(f0mr),.fill0_mem_req_ready(f0mrr),
      .fill0_mem_req_addr(f0ma),.fill0_mem_resp_valid(f0mv),
      .fill0_mem_resp_data(f0md),
      .fill1_start_valid(f1v),.fill1_start_ready(f1r),.fill1_start_bank(f1b),
      .fill1_start_epoch(f1e),.fill1_start_base_addr(f1a),
      .fill1_start_word_count(f1n),.fill1_done_valid(f1dv),
      .fill1_done_ready(1'b1),.fill1_done_bank(f1db),.fill1_done_epoch(f1de),
      .fill1_mem_req_valid(f1mr),.fill1_mem_req_ready(f1mrr),
      .fill1_mem_req_addr(f1ma),.fill1_mem_resp_valid(f1mv),
      .fill1_mem_resp_data(f1md),
      .cfg_valid(cv),.cfg_ready(cr),.cfg_tap_idx(cti),.cfg_weight_vec(cwv),
      .cfg_bias_vec(cbv),.cfg_multiplier_vec(cmv),.cfg_shift_vec(csv),
      .dw0_job_valid(d0v),.dw0_job_ready(d0r),.dw0_source_bank(d0sb),
      .dw0_source_epoch(d0se),.dw0_source_base_addr(d0sa),
      .dw0_source_lane_mask(d0m),.dw0_source_stride(d0st),
      .dw0_footprint_height(d0fh),.dw0_footprint_width(d0fw),
      .dw0_footprint_pitch(d0fp),.dw0_group(d0g),.dw0_group_count(d0gc),
      .dw0_zp(d0zp),.dw0_min(d0min),.dw0_max(d0max),
      .dw1_job_valid(d1v),.dw1_job_ready(d1r),.dw1_source_bank(d1sb),
      .dw1_source_epoch(d1se),.dw1_source_base_addr(d1sa),
      .dw1_source_lane_mask(d1m),.dw1_source_stride(d1st),
      .dw1_footprint_height(d1fh),.dw1_footprint_width(d1fw),
      .dw1_footprint_pitch(d1fp),.dw1_group(d1g),.dw1_group_count(d1gc),
      .dw1_zp(d1zp),.dw1_min(d1min),.dw1_max(d1max),
      .dw_done_valid(ddv),.dw_done_ready(ddr),.dw_done_half(ddh),
      .dw_done_group(ddg),
      .transfer_start_valid(tv),.transfer_start_ready(tr),.transfer_bank(tb),
      .transfer_session(ts),.transfer_epoch(te),.transfer_row(trow),
      .transfer_groups(tgroups),.transfer_done_valid(tdv),
      .transfer_done_ready(tdr),
      .pw_load_begin_valid(lbv),.pw_load_begin_ready(lbr),
      .pw_load_epoch(le),.pw_load_cin(lcin),.pw_load_cout(lcout),
      .pw_load_word_valid(lwv),.pw_load_word_ready(lwr),
      .pw_load_word_data(lwd),.pw_load_commit_valid(lcv),
      .pw_load_commit_ready(lcr),.pw_load_commit_reject(lcrej),
      .pw_load_extra_error(lextra),.pw_load_active(lactive),
      .pw_committed_valid(lvalid),.pw_committed_epoch(lepoch),
      .pw_expected_word_count(ewc),.pw_load_word_count(lwc),
      .pw_packed_load_count(plc),.pw_job_valid(pjv),.pw_job_ready(pjr),
      .pw_job_cout_tile(pct),.pw_job_bank(pjb),.pw_job_session(pjs),
      .pw_job_epoch(pje),.pw_job_group_count(pjgc),
      .pw_job_reverse_groups(pjrev),.pw_job_pixel_base(pjp),
      .pw_job_cout_base(pjc),.pw_job_output_pixels(pjpixels),
      .pw_job_output_channels(pjchannels),.pw_job_bias_vec(pjbias),
      .pw_job_multiplier_vec(pjmul),.pw_job_shift_vec(pjshift),
      .pw_job_zp(pjzp),.pw_job_min(pjmin),.pw_job_max(pjmax),
      .out_valid(ov),.out_ready(orr),.out_row_idx(ori),
      .out_beat_idx(obi),.out_pixel_idx(op),.out_channel_base(oc),
      .out_lane_mask(olm),.out_data(od),.pw_job_done(pdone),.busy(busy),
      .dw_overlap_cycles(dov),.dw_source_words(dsrc),.dw_tokens(dtok),
      .dw_half_writes(dhw),.pw_row_reads(pr)
    );

    integer cycles=0, outputs=0, errors=0, i, qi;
    integer overlap_obs=0, held_valid=0;
    reg [2:0] held_row; reg [1:0] held_beat, held_mask;
    reg [5:0] held_pixel; reg [8:0] held_cout; reg signed [15:0] held_data;
    reg qv[0:2]; reg [31:0] qd[0:2];
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (!rst_n) begin
            f0mv <= 0; f0md <= 0; f0mrr <= 1;
            for (qi=0; qi<3; qi=qi+1) begin qv[qi] <= 0; qd[qi] <= 0; end
        end else begin
            f0mv <= qv[0]; f0md <= qd[0];
            for (qi=0; qi<2; qi=qi+1) begin qv[qi] <= qv[qi+1]; qd[qi] <= qd[qi+1]; end
            qv[2] <= 0; qd[2] <= 0;
            f0mrr <= ((cycles % 13) != 4);
            if (f0mr && f0mrr) begin qv[2] <= 1; qd[2] <= 0; end
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            orr <= ((cycles % 7) != 0);
            if (dut.active && dut.u_pw.feeder_busy)
                overlap_obs <= overlap_obs + 1;
            if (ov && !orr) begin
                if (held_valid && (ori!==held_row || obi!==held_beat ||
                    op!==held_pixel || oc!==held_cout || olm!==held_mask ||
                    od!==held_data)) errors <= errors + 1;
                held_valid <= 1; held_row <= ori; held_beat <= obi;
                held_pixel <= op; held_cout <= oc; held_mask <= olm; held_data <= od;
            end else held_valid <= 0;
            if (ov && orr) begin
                outputs <= outputs + 1;
                if (od !== 0 || olm !== 2'b11) errors <= errors + 1;
            end
        end
    end

    task configure_dw; integer t,l; begin
        for (t=0; t<9; t=t+1) begin
            @(negedge clk); cti=t; cwv=0; cbv=0; cmv=0; csv=0;
            for (l=0; l<16; l=l+1) begin
                cbv[l*32 +: 32]=0; cmv[l*32 +: 32]=32'sh7fffffff;
            end
            cv=1; while(!cr) @(posedge clk); @(posedge clk); @(negedge clk); cv=0;
        end
    end endtask

    task fill_bank; input integer b_arg, ep_arg; begin
        @(negedge clk); f0b=b_arg; f0e=ep_arg; f0a=b_arg?BASE1:BASE0;
        f0n=WORDS; f0v=1; while(!f0r) @(posedge clk);
        @(posedge clk); @(negedge clk); f0v=0;
        while(!f0dv) @(posedge clk);
        if (f0db!==b_arg || f0de!==ep_arg) errors=errors+1;
        @(negedge clk); /* fill_done_ready is tied high at the shell */
    end endtask

    task send_job0; input integer b_arg, ep_arg; begin
        @(negedge clk); d0sb=b_arg; d0se=ep_arg; d0sa=b_arg?BASE1:BASE0;
        d0m=16'hffff; d0st=1; d0fh=FH; d0fw=FW; d0fp=FW; d0g=0; d0gc=1;
        d0zp=0; d0min=0; d0max=255; d0v=1; while(!d0r) @(posedge clk);
        @(posedge clk); @(negedge clk); d0v=0;
    end endtask

    task send_job1; input integer b_arg, ep_arg; begin
        @(negedge clk); d1sb=b_arg; d1se=ep_arg; d1sa=b_arg?BASE1:BASE0;
        d1m=16'hffff; d1st=1; d1fh=FH; d1fw=FW; d1fp=FW; d1g=0; d1gc=1;
        d1zp=0; d1min=0; d1max=255; d1v=1; while(!d1r) @(posedge clk);
        @(posedge clk); @(negedge clk); d1v=0;
    end endtask

    task wait_dw_done; input integer b_arg; input integer ep_arg; begin
        while(!ddv) @(posedge clk);
        if (ddh!==b_arg || ddg!==0) errors=errors+1;
        @(posedge clk);
    end endtask

    task load_pw; begin
        @(negedge clk); lbv=1; while(!lbr) @(posedge clk);
        @(posedge clk); @(negedge clk); lbv=0;
        for(i=0; i<16; i=i+1) begin
            @(negedge clk); lwd=0; lwv=1; while(!lwr) @(posedge clk);
            @(posedge clk); @(negedge clk); lwv=0;
        end
        @(negedge clk); lcv=1; while(!lcr) @(posedge clk);
        @(posedge clk); @(negedge clk); lcv=0;
        if (lcrej || lextra) errors=errors+1;
    end endtask

    task transfer_row0; begin
        @(negedge clk); tb=0; ts=0; te=0; trow=0; tgroups=1; tv=1;
        while(!tr) @(posedge clk); @(posedge clk); @(negedge clk); tv=0;
        while(!tdv) @(posedge clk);
        @(posedge clk);
    end endtask

    task launch_overlap; begin
        /* Both jobs are admitted on the same edge.  PW consumes the already
         * committed scratch bank while the producer computes a fresh tile
         * from the separately refilled source bank. */
        @(negedge clk);
        pjb=0; pjs=0; pje=0; pjgc=1; pjrev=0; pjp=0; pjc=0;
        pjpixels=8; pjchannels=8; pjbias=0; pjmul=0; pjshift=0;
        pjzp=0; pjmin=-128; pjmax=127; pjv=1;
        d0sb=0; d0se=3; d0sa=BASE0; d0m=16'hffff; d0st=1;
        d0fh=FH; d0fw=FW; d0fp=FW; d0g=0; d0gc=1;
        d0zp=0; d0min=0; d0max=255; d0v=1;
        while(!pjr || !d0r) @(posedge clk);
        @(posedge clk); @(negedge clk); pjv=0; d0v=0;
    end endtask

    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        $display("phase reset_done f0r=%b cr=%b", f0r, cr);
        configure_dw();
        $display("phase cfg_done f0r=%b", f0r);
        fill_bank(0,1); fill_bank(1,2);
        $display("phase fills_done f0r=%b", f0r);
        send_job0(0,1); wait_dw_done(0,1);
        $display("phase job0_done dsrc=%0d dtok=%0d d1r=%b ddv=%b state=%0d", dsrc,dtok,d1r,ddv,dut.u_dw0.state);
        send_job1(1,2); wait_dw_done(1,2);
        $display("phase job1_done dsrc=%0d dtok=%0d", dsrc,dtok);
        if (!dut.half0_done || !dut.half1_done) errors=errors+1;
        transfer_row0();
        $display("phase transfer_done");
        load_pw();
        $display("phase pw_loaded");
        /* Source bank 0 was released by the first job; refill it before the
         * simultaneous PW/DW admission so the second computation is real. */
        fill_bank(0,3);
        $display("phase refill_done");
        launch_overlap();
        while(!pdone) @(posedge clk);
        wait_dw_done(0,3);
        if (outputs != 32) errors=errors+1;
        if (overlap_obs == 0) errors=errors+1;
        if (dsrc == 0 || dtok != 288 || dhw == 0 || pr == 0) errors=errors+1;
        if (errors==0)
            $display("PASS real producer overlap outputs=%0d cycles=%0d overlap=%0d source_words=%0d tokens=%0d half_writes=%0d pw_reads=%0d", outputs,cycles,overlap_obs,dsrc,dtok,dhw,pr);
        else begin
            $display("FAIL real producer overlap errors=%0d outputs=%0d cycles=%0d overlap=%0d source_words=%0d tokens=%0d half_writes=%0d pw_reads=%0d", errors,outputs,cycles,overlap_obs,dsrc,dtok,dhw,pr);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat(1000000) @(posedge clk);
        $fatal(1,"WATCHDOG state=%0d producer=%0d pw_busy=%b overlap=%0d",dut.tr_state,dut.u_dw0.state,dut.u_pw.feeder_busy,overlap_obs);
    end
endmodule
`default_nettype wire
