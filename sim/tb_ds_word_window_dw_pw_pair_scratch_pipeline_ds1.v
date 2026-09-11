`timescale 1ns/1ps
`default_nettype none

/*
 * DS1-shaped, real-producer proof for the paired-half scratch path.
 *
 * The producer is not stubbed: each 4x8 job issues all 240 source words for
 * its 6x10 stride-1 footprint, receives delayed words from the source port,
 * and emits four stream4 beats per output pixel.  The source model is a
 * pixel-major 32x32x16 feature map of ones with zero padding; the request
 * address is decoded to the corresponding tile/window word, so edge pixels
 * exercise the same clipped 3x3 oracle as DS1.  The pair shell is drained
 * one 8-pixel row at a time through a banked row image and paired scratch
 * ownership fence; the producer and consumer run concurrently across macros.
 * This is real overlap evidence, not a fictional DW beat or reduced MAC
 * shape.
 */
module tb_ds_word_window_dw_pw_pair_scratch_pipeline_ds1;
    localparam integer AW=24, WW=16, EW=4, SW=2, GW=5;
    localparam integer MACROS=32, ROWS=8, PW_JOBS=MACROS*ROWS*4;
    localparam [AW-1:0] BASE0=24'h100000, BASE1=24'h200000;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;

    reg f0v=0; wire f0r; reg f0b=0; reg [EW-1:0] f0e=0;
    reg [AW-1:0] f0a=0; reg [WW-1:0] f0n=240; wire f0dv; reg f0dr=0; wire f0db;
    wire [EW-1:0] f0de; wire f0mr; reg f0mrr=1; wire [AW-1:0] f0ma;
    reg f0mv=0; reg [31:0] f0md=0;
    reg f1v=0; wire f1r; reg f1b=1; reg [EW-1:0] f1e=0;
    reg [AW-1:0] f1a=0; reg [WW-1:0] f1n=240; wire f1dv; reg f1dr=0; wire f1db;
    wire [EW-1:0] f1de; wire f1mr; reg f1mrr=1; wire [AW-1:0] f1ma;
    reg f1mv=0; reg [31:0] f1md=0;

    reg cv=0; wire cr; reg [3:0] cti=0; reg signed [127:0] cwv=0;
    reg signed [511:0] cbv=0, cmv=0; reg [95:0] csv=0;

    reg d0v=0; wire d0r; reg d0sb=0; reg [EW-1:0] d0se=0;
    reg [AW-1:0] d0sa=0; reg [15:0] d0m=16'hffff; reg [1:0] d0st=1;
    reg [7:0] d0fh=6, d0fw=10, d0fp=10; reg [2:0] d0g=0; reg [3:0] d0gc=1;
    reg [31:0] d0zp=0,d0min=0,d0max=32'h7fffffff;
    reg d1v=0; wire d1r; reg d1sb=0; reg [EW-1:0] d1se=0;
    reg [AW-1:0] d1sa=0; reg [15:0] d1m=16'hffff; reg [1:0] d1st=1;
    reg [7:0] d1fh=6, d1fw=10, d1fp=10; reg [2:0] d1g=0; reg [3:0] d1gc=1;
    reg [31:0] d1zp=0,d1min=0,d1max=32'h7fffffff;
    wire ddv; reg ddr=1; wire ddh; wire [2:0] ddg;

    reg tv=0; wire tr; reg tb=0; reg [SW-1:0] ts=0; reg [EW-1:0] te=0;
    reg [2:0] trow=0; reg [GW-1:0] tgroups=2; wire tdv; reg tdr=1;

    reg lbv=0; wire lbr; reg [1:0] le=1; reg [7:0] lcin=16; reg [8:0] lcout=32;
    reg lwv=0; wire lwr; reg [31:0] lwd=32'h01010101; reg lcv=0;
    wire lcr,lcrej,lextra,lactive,lvalid; wire [1:0] lepoch;
    wire [13:0] ewc,lwc; wire [15:0] plc;
    reg pjv=0; wire pjr; reg [4:0] pct=0; reg pjb=0; reg [SW-1:0] pjs=0;
    reg [EW-1:0] pje=1; reg [GW-1:0] pjgc=2; reg pjrev=0; reg [5:0] pjp=0;
    reg [8:0] pjc=0; reg [7:0] pjpixels=8; reg [8:0] pjchannels=32;
    reg signed [255:0] pjbias=0,pjmul=0; reg [47:0] pjshift=0;
    reg signed [31:0] pjzp=0,pjmin=-32768,pjmax=32767;
    wire ov; reg orr=1; wire [2:0] ori; wire [1:0] obi,olm;
    wire [5:0] op; wire [8:0] oc; wire signed [15:0] od; wire pdone,busy;
    wire [31:0] overlap,source_words,dtok,dhw,pr;

    ds_word_window_dw_pw_pair_scratch_pipeline #(.MAX_IN_H(17),.MAX_IN_W(17),
        .MAX_CIN(16),.MAX_COUT(32),.MAX_GROUPS(2),.FIFO_DEPTH(8)) dut (
      .clk(clk),.rst_n(rst_n),
      .fill0_start_valid(f0v),.fill0_start_ready(f0r),.fill0_start_bank(f0b),.fill0_start_epoch(f0e),.fill0_start_base_addr(f0a),.fill0_start_word_count(f0n),.fill0_done_valid(f0dv),.fill0_done_ready(f0dr),.fill0_done_bank(f0db),.fill0_done_epoch(f0de),.fill0_mem_req_valid(f0mr),.fill0_mem_req_ready(f0mrr),.fill0_mem_req_addr(f0ma),.fill0_mem_resp_valid(f0mv),.fill0_mem_resp_data(f0md),
      .fill1_start_valid(f1v),.fill1_start_ready(f1r),.fill1_start_bank(f1b),.fill1_start_epoch(f1e),.fill1_start_base_addr(f1a),.fill1_start_word_count(f1n),.fill1_done_valid(f1dv),.fill1_done_ready(f1dr),.fill1_done_bank(f1db),.fill1_done_epoch(f1de),.fill1_mem_req_valid(f1mr),.fill1_mem_req_ready(f1mrr),.fill1_mem_req_addr(f1ma),.fill1_mem_resp_valid(f1mv),.fill1_mem_resp_data(f1md),
      .cfg_valid(cv),.cfg_ready(cr),.cfg_tap_idx(cti),.cfg_weight_vec(cwv),.cfg_bias_vec(cbv),.cfg_multiplier_vec(cmv),.cfg_shift_vec(csv),
      .dw0_job_valid(d0v),.dw0_job_ready(d0r),.dw0_source_bank(d0sb),.dw0_source_epoch(d0se),.dw0_source_base_addr(d0sa),.dw0_source_lane_mask(d0m),.dw0_source_stride(d0st),.dw0_footprint_height(d0fh),.dw0_footprint_width(d0fw),.dw0_footprint_pitch(d0fp),.dw0_group(d0g),.dw0_group_count(d0gc),.dw0_zp(d0zp),.dw0_min(d0min),.dw0_max(d0max),
      .dw1_job_valid(d1v),.dw1_job_ready(d1r),.dw1_source_bank(d1sb),.dw1_source_epoch(d1se),.dw1_source_base_addr(d1sa),.dw1_source_lane_mask(d1m),.dw1_source_stride(d1st),.dw1_footprint_height(d1fh),.dw1_footprint_width(d1fw),.dw1_footprint_pitch(d1fp),.dw1_group(d1g),.dw1_group_count(d1gc),.dw1_zp(d1zp),.dw1_min(d1min),.dw1_max(d1max),.dw_done_valid(ddv),.dw_done_ready(ddr),.dw_done_half(ddh),.dw_done_group(ddg),
      .transfer_start_valid(tv),.transfer_start_ready(tr),.transfer_bank(tb),.transfer_session(ts),.transfer_epoch(te),.transfer_row(trow),.transfer_groups(tgroups),.transfer_done_valid(tdv),.transfer_done_ready(tdr),
      .pw_load_begin_valid(lbv),.pw_load_begin_ready(lbr),.pw_load_epoch(le),.pw_load_cin(lcin),.pw_load_cout(lcout),.pw_load_word_valid(lwv),.pw_load_word_ready(lwr),.pw_load_word_data(lwd),.pw_load_commit_valid(lcv),.pw_load_commit_ready(lcr),.pw_load_commit_reject(lcrej),.pw_load_extra_error(lextra),.pw_load_active(lactive),.pw_committed_valid(lvalid),.pw_committed_epoch(lepoch),.pw_expected_word_count(ewc),.pw_load_word_count(lwc),.pw_packed_load_count(plc),
      .pw_job_valid(pjv),.pw_job_ready(pjr),.pw_job_cout_tile(pct),.pw_job_bank(pjb),.pw_job_session(pjs),.pw_job_epoch(pje),.pw_job_group_count(pjgc),.pw_job_reverse_groups(pjrev),.pw_job_pixel_base(pjp),.pw_job_cout_base(pjc),.pw_job_output_pixels(pjpixels),.pw_job_output_channels(pjchannels),.pw_job_bias_vec(pjbias),.pw_job_multiplier_vec(pjmul),.pw_job_shift_vec(pjshift),.pw_job_zp(pjzp),.pw_job_min(pjmin),.pw_job_max(pjmax),.out_valid(ov),.out_ready(orr),.out_row_idx(ori),.out_beat_idx(obi),.out_pixel_idx(op),.out_channel_base(oc),.out_lane_mask(olm),.out_data(od),.pw_job_done(pdone),.busy(busy),.dw_overlap_cycles(overlap),.dw_source_words(source_words),.dw_tokens(dtok),.dw_half_writes(dhw),.pw_row_reads(pr));

    /* Ordered three-cycle source response for each real fill port. */
    reg q0v[0:2],q1v[0:2]; reg [AW-1:0] q0a[0:2],q1a[0:2]; integer qi;
    function automatic [31:0] source_word(input [AW-1:0] addr);
        integer m, idx, ly, lx, gy, gx; reg half; reg [AW-1:0] rel; reg [31:0] b;
        begin
            half=1'b0; rel=addr-BASE0;
            if (addr >= BASE1) begin half=1'b1; rel=addr-BASE1; end
            m=rel>>12; idx=(rel & 12'hfff)>>2; ly=idx/40; lx=(idx%40)/4;
            gy=(m>>3)*8 + (m&7)*0 + (half?4:0) + ly - 1;
            gx=(m&7)*8 + lx - 1;
            b=0;
            if ((gy>=0)&&(gy<32)&&(gx>=0)&&(gx<32)) b=32'h01010101;
            source_word=b;
        end
    endfunction
    integer source_cycles=0;
    always @(posedge clk) begin
        source_cycles<=source_cycles+1;
        if(!rst_n) begin f0mv<=0;f1mv<=0;f0md<=0;f1md<=0; for(qi=0;qi<3;qi=qi+1) begin q0v[qi]<=0;q1v[qi]<=0;q0a[qi]<=0;q1a[qi]<=0; end end
        else begin
            f0mv<=q0v[0]; f1mv<=q1v[0]; f0md<=source_word(q0a[0]); f1md<=source_word(q1a[0]);
            for(qi=0;qi<2;qi=qi+1) begin q0v[qi]<=q0v[qi+1]; q1v[qi]<=q1v[qi+1]; q0a[qi]<=q0a[qi+1]; q1a[qi]<=q1a[qi+1]; end
            q0v[2]<=f0mr&&f0mrr; q1v[2]<=f1mr&&f1mrr; q0a[2]<=f0ma; q1a[2]<=f1ma;
            f0mrr<=((source_cycles%17)!=5); f1mrr<=((source_cycles%19)!=7);
        end
    end

    integer errors=0, dw_fires=0, dw_token_fires=0, pw_fires=0, pw_token_fires=0, bank_changes=0, out_checks=0;
    integer tile,row,chan,exp_n,got,got_hi,global_y,global_x,dy,dx;
    always @(posedge clk) begin
        if(rst_n) begin
            if(dut.pack_fire) dw_fires=dw_fires+1;

            if(dut.pack_in_v && dut.pack_in_r) dw_token_fires=dw_token_fires+1;
            if (dut.u_pw.feeder_act_valid && dut.u_pw.feeder_act_ready) pw_token_fires=pw_token_fires+1;
            if(dut.c_job_done) pw_fires=pw_fires+1;
            if(ov&&orr) begin
                got=$signed(od[7:0]); got_hi=$signed(od[15:8]);
                exp_n=0;
                for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1)
                    if((check_y+dy>=0)&&(check_y+dy<32)&&(check_x+op+dx>=0)&&(check_x+op+dx<32)) exp_n=exp_n+1;
                if(olm!==2'b11 || got!==(exp_n*8) || got_hi!==(exp_n*8)) begin
                    if(errors<8) $display("PAIR_DS1_MISMATCH y=%0d x=%0d c=%0d got=%0d,%0d exp=%0d mask=%b",check_y,check_x+op,oc,got,got_hi,exp_n*8,olm);
                    errors=errors+1;
                end
                out_checks=out_checks+1;
            end
        end
    end
    integer check_y=0,check_x=0,check_tile=0,check_row=0,check_ct=0;
    reg macro_ready [0:MACROS-1];
    reg macro_released [0:MACROS-1];
    reg producer_done_flag=1'b0, consumer_done_flag=1'b0;
    integer producer_tile, consumer_tile;

    task cfg_dw; integer t,l; begin for(t=0;t<9;t=t+1) begin @(negedge clk); cti=t;cwv=0;cbv=0;cmv=0;csv=0; for(l=0;l<16;l=l+1) begin cwv[l*8 +:8]=8'sd1;cmv[l*32 +:32]=32'sh7fffffff; end cv=1;while(!cr)@(posedge clk);@(posedge clk);@(negedge clk);cv=0; end end endtask
    task load_pw; integer k; begin @(negedge clk);lbv=1;while(!lbr)@(posedge clk);@(posedge clk);@(negedge clk);lbv=0; for(k=0;k<128;k=k+1) begin @(negedge clk);lwd=32'h01010101;lwv=1;while(!lwr)@(posedge clk);@(posedge clk);@(negedge clk);lwv=0; end @(negedge clk);lcv=1;while(!lcr)@(posedge clk);@(posedge clk);@(negedge clk);lcv=0; end endtask
    task fill_macro(input integer m); begin f0dr=0;f1dr=0;f0e=m+1;f1e=m+1;f0a=BASE0+(m<<12);f1a=BASE1+(m<<12);f0b=m&1;f1b=m&1;@(negedge clk);f0v=1;f1v=1;while(!f0r||!f1r)@(posedge clk);@(posedge clk);@(negedge clk);f0v=0;f1v=0;while(!f0dv||!f1dv)@(posedge clk);@(negedge clk);f0dr=1;f1dr=1;@(posedge clk);@(negedge clk);f0dr=0;f1dr=0; $display("FILL_DONE m=%0d cyc=%0d",m,source_cycles); end endtask
    task do_dw(input integer m,input integer which); begin if(which==0) begin d0sb=m&1;d0se=m+1;d0sa=BASE0+(m<<12);@(negedge clk);d0v=1;while(!d0r)@(posedge clk);@(posedge clk);@(negedge clk);d0v=0; end else begin d1sb=m&1;d1se=m+1;d1sa=BASE1+(m<<12);@(negedge clk);d1v=1;while(!d1r)@(posedge clk);@(posedge clk);@(negedge clk);d1v=0; end while(!ddv)@(posedge clk);@(posedge clk); $display("DW_DONE m=%0d h=%0d cyc=%0d",m,which,source_cycles); end endtask
    task transfer_row(input integer m,input integer r); begin tb=(m&1);ts=0;te=1;trow=r;@(negedge clk);tv=1;while(!tr)@(posedge clk);@(posedge clk);@(negedge clk);tv=0;while(!tdv)@(posedge clk);@(posedge clk); end endtask
    task pw_row(input integer m,input integer r,input integer ct); begin pjb=(m&1);pje=1;pct=ct;pjc=ct*8;check_y=(m>>3)*8+r;check_x=(m&7)*8;@(negedge clk);pjv=1;while(!pjr)@(posedge clk);@(posedge clk);@(negedge clk);pjv=0;while(!pdone)@(posedge clk);@(posedge clk); end endtask

    initial begin
        for (qi=0;qi<8;qi=qi+1) pjmul[qi*32 +: 32]=32'sh40000000;
        for (tile=0; tile<MACROS; tile=tile+1) begin
            macro_ready[tile]=1'b0;
            macro_released[tile]=1'b0;
        end
        repeat(5)@(posedge clk);rst_n=1;cfg_dw();load_pw();
        for (producer_tile=0; producer_tile<MACROS; producer_tile=producer_tile+1) begin
            if (producer_tile >= 2)
                while (!macro_released[producer_tile-2]) @(posedge clk);
            fill_macro(producer_tile);
            do_dw(producer_tile,0);
            do_dw(producer_tile,1);
            macro_ready[producer_tile]=1'b1;
        end
        producer_done_flag=1'b1;
    end

    initial begin
        wait(rst_n);
        for (consumer_tile=0; consumer_tile<MACROS; consumer_tile=consumer_tile+1) begin
            while (!macro_ready[consumer_tile]) @(posedge clk);
            for(row=0;row<ROWS;row=row+1)
                for(chan=0;chan<4;chan=chan+1) begin
                    transfer_row(consumer_tile,row);
                    pw_row(consumer_tile,row,chan);
                end
            macro_released[consumer_tile]=1'b1;
        end
        consumer_done_flag=1'b1;
    end

    initial begin
        wait(producer_done_flag && consumer_done_flag);
        if(source_words != MACROS*2*240) errors=errors+1;
        if(dw_fires!=MACROS*2*128) errors=errors+1;
        if(out_checks!=PW_JOBS*32) errors=errors+1;
        if(errors==0 && source_cycles<=45000 && overlap!=0) $display("PASS pair_ds1 cycles=%0d dw_fire=%0d dw_tokens=%0d pw_done=%0d pw_tokens=%0d out_beats=%0d overlap=%0d source_words=%0d tokens=%0d half_writes=%0d pw_reads=%0d",source_cycles,dw_fires,dw_token_fires,pw_fires,pw_token_fires,out_checks,overlap,source_words,dtok,dhw,pr);
        else $display("NEGATIVE_RESULT pair_ds1 errors=%0d cycles=%0d dw_fire=%0d dw_tokens=%0d pw_done=%0d pw_tokens=%0d out_beats=%0d overlap=%0d source_words=%0d tokens=%0d half_writes=%0d pw_reads=%0d barrier=cycle_budget_or_functional_error",errors,source_cycles,dw_fires,dw_token_fires,pw_fires,pw_token_fires,out_checks,overlap,source_words,dtok,dhw,pr);
        $finish;
    end
    initial begin repeat(8000000)@(posedge clk);$display("PAIR_DS1_WATCHDOG cycles=%0d active=%b tr=%0d pstate=%0d pjr=%b pjv=%b pdone=%b s0=%0d s1=%0d",source_cycles,dut.active,dut.tr_state,dut.u_pw.state,pjr,pjv,pdone,dut.c_s0,dut.c_s1);$fatal(1,"PAIR_DS1_WATCHDOG");end
endmodule
`default_nettype wire
