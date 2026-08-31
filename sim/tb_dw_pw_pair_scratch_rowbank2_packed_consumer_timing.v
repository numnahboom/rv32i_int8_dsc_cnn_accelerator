`timescale 1ns/1ps
`default_nettype none

/* Ideal-service timing probe for the real paired scratch + packed PW
 * consumer.  It keeps the source/scratch/weight interfaces active and uses
 * non-zero deterministic bytes, but leaves arithmetic checking to the full
 * differential consumer regression. */
module tb_dw_pw_pair_scratch_rowbank2_packed_consumer_timing #(
    parameter integer TB_CIN=16
);
    localparam integer G=(TB_CIN+7)/8;
    localparam integer WORDS=2*TB_CIN; /* one 8-cout tile */
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;
    reg av=0, ab=0; reg [1:0] as=0, ae=0; reg [4:0] ag=G; wire ar;
    reg wv=0, wb=0, wh=0; reg [4:0] wg=0; reg [255:0] wd=0; reg [31:0] wm=0; wire wr;
    reg cv=0, cb=0; reg [1:0] cs=0, ce=0; wire cr;
    reg lbv=0; wire lbr; reg [1:0] le=1; reg [7:0] lcin=TB_CIN; reg [8:0] lcout=8;
    reg lwv=0; wire lwr; reg [31:0] lwd=0; reg lcv=0; wire lcr;
    wire lrej, lextra, lactive, pvalid; wire [1:0] pe;
    wire [13:0] ewc,lwc; wire [15:0] plc;
    reg jv=0,jb=0,jrev=0; reg [4:0] jt=0,jg=G; reg [1:0] js=0,je=1;
    reg [5:0] jp=0; reg [8:0] jc=0; reg [7:0] jpix=8; reg [8:0] jchan=8;
    reg signed [255:0] jbias=0,jmul=0; reg [47:0] jshift=0;
    reg signed [31:0] jzp=0,jmin=-128,jmax=127;
    wire jr, ov; reg orr=1; wire [2:0] ori; wire [1:0] obi,olm;
    wire [5:0] op; wire [8:0] oc; wire signed [15:0] od; wire done,busy;
    wire [1:0] s0,s1; wire [15:0] pr,aa,asr;
    dw_pw_pair_scratch_rowbank2_packed_consumer #(
        .MAX_CIN(128),.MAX_COUT(8),.MAX_GROUPS(16)
    ) dut (
        .clk(clk),.rst_n(rst_n),.dw_acquire_valid(av),.dw_acquire_ready(ar),
        .dw_acquire_bank(ab),.dw_acquire_session(as),.dw_acquire_epoch(ae),
        .dw_acquire_group_count(ag),.dw_write_valid(wv),.dw_write_ready(wr),
        .dw_write_bank(wb),.dw_write_group(wg),.dw_write_half(wh),
        .dw_write_data(wd),.dw_write_lane_mask(wm),.dw_commit_valid(cv),
        .dw_commit_ready(cr),.dw_commit_bank(cb),.dw_commit_session(cs),
        .dw_commit_epoch(ce),.pw_load_begin_valid(lbv),
        .pw_load_begin_ready(lbr),.pw_load_epoch(le),.pw_load_cin(lcin),
        .pw_load_cout(lcout),.pw_load_word_valid(lwv),.pw_load_word_ready(lwr),
        .pw_load_word_data(lwd),.pw_load_commit_valid(lcv),
        .pw_load_commit_ready(lcr),.pw_load_commit_reject(lrej),
        .pw_load_extra_error(lextra),.pw_load_active(lactive),
        .pw_committed_valid(pvalid),.pw_committed_epoch(pe),
        .pw_expected_word_count(ewc),.pw_load_word_count(lwc),
        .pw_packed_load_count(plc),.job_valid(jv),.job_ready(jr),
        .job_cout_tile(jt),.job_bank(jb),.job_session(js),.job_epoch(je),
        .job_group_count(jg),.job_reverse_groups(jrev),.job_pixel_base(jp),
        .job_cout_base(jc),.job_output_pixels(jpix),
        .job_output_channels(jchan),.job_bias_vec(jbias),
        .job_multiplier_vec(jmul),.job_shift_vec(jshift),
        .job_output_zero_point_int32(jzp),.job_activation_min_int32(jmin),
        .job_activation_max_int32(jmax),.out_valid(ov),.out_ready(orr),
        .out_row_idx(ori),.out_beat_idx(obi),.out_pixel_idx(op),
        .out_channel_base(oc),.out_lane_mask(olm),.out_data(od),
        .job_done(done),.busy(busy),.scratch_bank0_state(s0),
        .scratch_bank1_state(s1),.packed_read_count(pr),
        .activation_accept_count(aa),.activation_stall_count(asr)
    );
    integer cycles=0,start_cycle,end_cycle,outputs=0,errors=0,i,g;
    task automatic send_word; begin
        @(negedge clk); lwd=32'h01020304+i; lwv=1;
        while(!lwr) @(posedge clk); @(posedge clk); @(negedge clk); lwv=0;
    end endtask
    task automatic write_half; input integer gg,hh; begin
        @(negedge clk); wb=0;wg=gg;wh=hh;wd={32{8'h11+gg+hh}};wm=32'hffff_ffff;wv=1;
        while(!wr) @(posedge clk); @(posedge clk); @(negedge clk); wv=0;
    end endtask
    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        @(negedge clk); lbv=1; while(!lbr) @(posedge clk); @(posedge clk);
        @(negedge clk); lbv=0;
        for(i=0;i<WORDS;i=i+1) send_word();
        @(negedge clk); lcv=1; while(!lcr) @(posedge clk); @(posedge clk);
        @(negedge clk); lcv=0;
        @(negedge clk); ae=1; as=0; av=1; while(!ar) @(posedge clk); @(posedge clk);
        @(negedge clk); av=0;
        for(g=0;g<G;g=g+1) begin write_half(g,0); write_half(g,1); end
        @(negedge clk); cb=0;cs=0;ce=1;cv=1; while(!cr) @(posedge clk); @(posedge clk);
        @(negedge clk); cv=0;
        @(negedge clk); jv=1; while(!jr) @(posedge clk); @(posedge clk); start_cycle=cycles;
        @(negedge clk); jv=0;
        while(!done) @(posedge clk);
        end_cycle=cycles;
        if (outputs != 32 || pr != G*8 || aa != G*8) errors=errors+1;
        if (errors==0)
            $display("PASS packed consumer timing cin=%0d groups=%0d words=%0d job_cycles=%0d total_cycles=%0d outputs=%0d packed_reads=%0d activations=%0d",
                     TB_CIN,G,WORDS,end_cycle-start_cycle,cycles,outputs,pr,aa);
        else begin
            $display("FAIL packed consumer timing cin=%0d errors=%0d outputs=%0d reads=%0d activations=%0d",
                     TB_CIN,errors,outputs,pr,aa); $fatal(1);
        end
        $finish;
    end
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (rst_n && ov && orr) outputs <= outputs+1;
    end
    initial begin repeat(300000) @(posedge clk);
        $display("WATCHDOG cin=%0d state=%0d job_active=%b group_active=%b resp=%b scratch=%0d/%0d out=%b done=%b reads=%0d act=%0d",
                 TB_CIN,dut.state,dut.u_packed_feeder.job_active_reg,
                 dut.u_packed_feeder.group_active_reg,dut.u_packed_feeder.response_valid,
                 s0,s1,ov,done,pr,aa);
        $fatal(1,"WATCHDOG cin=%0d",TB_CIN);
    end
endmodule
`default_nettype wire
