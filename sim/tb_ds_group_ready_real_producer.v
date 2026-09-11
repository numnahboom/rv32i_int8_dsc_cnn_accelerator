`timescale 1ns/1ps
`default_nettype none

/* Producer-to-partial-K integration proof.  All source words and all DW
 * weights are nonzero; the reference checks the resulting nonzero PW psum,
 * masks and exactly one 8-pixel output group. */
module tb_ds_group_ready_real_producer;
    localparam integer AW=24, WW=16, EW=4, TW=8;
    localparam integer FH=4, FW=10, WORDS=FH*FW*4;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;

    reg start_valid=0; wire start_ready; reg [7:0] start_cin=16;
    reg [7:0] start_pixels=8; reg [7:0] start_cout=8; reg start_bank=0;
    reg [1:0] start_session=1; reg [3:0] start_epoch=1;
    reg wv=0; wire wr; reg [7:0] wk=0; reg [63:0] wvec=0;
    wire ov; reg or_ready=1; wire signed [2047:0] opsum;
    wire [7:0] opmask, ocmask; wire [63:0] olmask; wire [3:0] ogcount;
    wire done, error; wire [31:0] total_cycles, half_writes, descriptors,
        tokens, output_groups, first_output_cycle;

    reg fsv=0; wire fsr; reg fsb=0; reg [3:0] fse=1; reg [23:0] fba=24'h100000;
    reg [15:0] fwc=WORDS; wire fdv; reg fdr=1; wire fdb; wire [3:0] fde;
    /* m* is the external source port.  DS1_ADDRESS_ADAPTER optionally
     * interposes the global pixel-major/halo translator under test. */
    wire mrv; reg mrr=1; wire [23:0] mra; reg mspv=0; reg [31:0] msd=0;
    wire producer_mrv, producer_mrr; wire [23:0] producer_mra;
    wire producer_mspv; wire [31:0] producer_msd;
`ifdef DS1_ADDRESS_ADAPTER
    reg adapter_context_valid=0;
    wire adapter_context_ready;
    wire adapter_context_complete = fdv && fdr;
    wire adapter_error;
    ds1_group_fill_address_adapter #(.ADDR_WIDTH(24), .FIFO_DEPTH(8)) u_ds1_adapter (
        .clk(clk), .rst_n(rst_n), .context_valid(adapter_context_valid),
        .context_ready(adapter_context_ready), .context_linear_base(fba),
        .context_input_base(fba), .context_global_y(6'd1), .context_global_x(6'd1),
        .context_input_zero_point(8'd0), .context_complete(adapter_context_complete),
        .producer_req_valid(producer_mrv), .producer_req_ready(producer_mrr),
        .producer_req_addr(producer_mra), .producer_resp_valid(producer_mspv),
        .producer_resp_data(producer_msd), .mem_req_valid(mrv), .mem_req_ready(mrr),
        .mem_req_addr(mra), .mem_resp_valid(mspv), .mem_resp_data(msd),
        .error(adapter_error)
    );
`else
    assign mrv = producer_mrv;
    assign mra = producer_mra;
    assign producer_mrr = mrr;
    assign producer_mspv = mspv;
    assign producer_msd = msd;
`endif
    reg cv=0; wire cr; reg [3:0] cti=0; reg signed [127:0] cwv=0;
    reg signed [511:0] cbv=0, cmv=0; reg [95:0] csv=0;
    reg djv=0; wire djr; reg dsb=0; reg [3:0] dse=1; reg [23:0] dba=24'h100000;
    reg [15:0] dsm=16'hffff; reg [1:0] dss=1; reg [7:0] dfh=FH, dfw=FW, dfp=FW;
    reg dtb=0; reg [3:0] dte=1; reg [7:0] dtt=0; reg [2:0] dcg=0;
    reg [3:0] dgc=1; reg [7:0] dpc=8; reg [31:0] dzp=0;
    reg [31:0] dmin=-2147483648, dmax=2147483647;
    wire ddv; reg ddr=1; wire ddb; wire [3:0] dde; wire [7:0] ddt; wire [2:0] ddg;

    ds_group_ready_real_producer #(.FIFO_DEPTH(2), .OUTPUT_HEIGHT(1),
        .OUTPUT_WIDTH(8), .USE_QUADLOCAL_CORE(1), .USE_LOCAL_REQUANT(1)) dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
        .start_cin(start_cin), .start_pixels(start_pixels), .start_cout(start_cout),
        .start_bank(start_bank), .start_session(start_session), .start_epoch(start_epoch),
        .weight_load_valid(wv), .weight_load_ready(wr), .weight_load_k(wk),
        .weight_load_vec(wvec), .out_valid(ov), .out_ready(or_ready), .out_psum(opsum),
        .out_pixel_mask(opmask), .out_cout_mask(ocmask), .out_lane_mask(olmask),
        .out_group_count(ogcount), .done(done), .error(error),
        .perf_total_cycles(total_cycles), .perf_half_writes(half_writes),
        .perf_group_descriptors(descriptors), .perf_pw_tokens(tokens),
        .perf_output_groups(output_groups), .perf_first_output_cycle(first_output_cycle),
        .fill_start_valid(fsv), .fill_start_ready(fsr), .fill_start_bank(fsb),
        .fill_start_epoch(fse), .fill_start_base_addr(fba),
        .fill_start_word_count(fwc), .fill_done_valid(fdv), .fill_done_ready(fdr),
        .fill_done_bank(fdb), .fill_done_epoch(fde), .mem_req_valid(producer_mrv),
        .mem_req_ready(producer_mrr), .mem_req_addr(producer_mra), .mem_resp_valid(producer_mspv),
        .mem_resp_data(producer_msd), .cfg_valid(cv), .cfg_ready(cr), .cfg_tap_idx(cti),
        .cfg_weight_vec(cwv), .cfg_bias_vec(cbv), .cfg_multiplier_vec(cmv),
        .cfg_shift_vec(csv), .dw_job_valid(djv), .dw_job_ready(djr),
        .dw_source_bank(dsb), .dw_source_epoch(dse), .dw_source_base_addr(dba),
        .dw_source_lane_mask(dsm), .dw_source_stride(dss),
        .dw_footprint_height(dfh), .dw_footprint_width(dfw),
        .dw_footprint_pitch(dfp), .dw_target_bank(dtb), .dw_target_epoch(dte),
        .dw_target_tile(dtt), .dw_channel_group(dcg), .dw_group_count(dgc),
        .dw_pixel_count(dpc), .dw_output_zero_point(dzp),
        .dw_activation_min(dmin), .dw_activation_max(dmax),
        .dw_done_valid(ddv), .dw_done_ready(ddr), .dw_done_bank(ddb),
        .dw_done_epoch(dde), .dw_done_tile(ddt), .dw_done_group(ddg)
    );

    /* Three-cycle source response, with periodic request bubbles. */
    reg qv[0:2]; reg [31:0] qd[0:2]; integer qi; integer cycles=0;
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (!rst_n) begin
            mspv<=0; msd<=0; mrr<=1;
            for(qi=0;qi<3;qi=qi+1) begin qv[qi]<=0; qd[qi]<=0; end
        end else begin
            mspv<=qv[0]; msd<=qd[0];
            for(qi=0;qi<2;qi=qi+1) begin qv[qi]<=qv[qi+1]; qd[qi]<=qd[qi+1]; end
            qv[2]<=0; qd[2]<=32'h01010101; mrr<=((cycles%17)!=5);
            if(mrv&&mrr) qv[2]<=1;
        end
    end

    integer errors=0, outputs=0, producer_beats=0, p, c, k, actual, expected;
    always @(posedge clk) begin
        if (rst_n && dut.stream4_valid && dut.stream4_ready) begin
            producer_beats=producer_beats+1;
            if (dut.stream4_data === 32'd0 || dut.stream4_lane_mask !== 4'hf) begin
                errors=errors+1;
                $display("PRODUCER_STREAM_ASSERT beat=%0d data=%h mask=%h",producer_beats,dut.stream4_data,dut.stream4_lane_mask);
            end
        end
        if (rst_n && ov && or_ready) begin
            if (outputs != 0) errors=errors+1;
            for (p=0;p<8;p=p+1) for(c=0;c<8;c=c+1) begin
                if (!olmask[p*8+c]) errors=errors+1;
                actual=$signed(opsum[((p*8+c)*32) +: 32]);
                /* 3x3 source=1, DW weight=1, then PW Cin=16 weights=1. */
                expected=16*9;
                if (actual !== expected) begin
                    if (errors < 4) $display("NONZERO_REF_MISMATCH p=%0d c=%0d got=%0d exp=%0d",p,c,actual,expected);
                    errors=errors+1;
                end
            end
            outputs=outputs+1;
        end
    end

    task load_cfg; integer t,l; begin
        for(t=0;t<9;t=t+1) begin
            @(negedge clk); cti=t; cwv=0; cbv=0; cmv=0; csv=0;
            for(l=0;l<16;l=l+1) begin
                cwv[l*8 +: 8]=8'sd1;
                cmv[l*32 +: 32]=32'sh7fffffff;
            end
            cv=1; while(!cr) @(posedge clk); @(posedge clk); @(negedge clk); cv=0;
        end
    end endtask

    task load_pw_weights; integer kk,cc; begin
        for (kk=0;kk<16;kk=kk+1) begin
            @(negedge clk); wk=kk; wvec=64'h0101010101010101; wv=1;
            while(!wr) @(posedge clk); @(posedge clk); @(negedge clk); wv=0;
        end
    end endtask

    task fill; begin
        @(negedge clk); fsv=1; while(!fsr) @(posedge clk);
        @(posedge clk); @(negedge clk); fsv=0; while(!fdv) @(posedge clk);
        if (fdb!==0 || fde!==1) errors=errors+1;
        @(posedge clk);
    end endtask

    initial begin
        repeat(5) @(posedge clk); rst_n=1;
`ifdef DS1_ADDRESS_ADAPTER
        @(negedge clk); adapter_context_valid=1;
        while(!adapter_context_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); adapter_context_valid=0;
`endif
        load_pw_weights(); load_cfg(); fill();
        @(negedge clk); start_valid=1; while(!start_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); start_valid=0;
        @(negedge clk); djv=1; while(!djr) @(posedge clk);
        @(posedge clk); @(negedge clk); djv=0;
        while(!done) @(posedge clk);
        if (error || outputs!=1 || producer_beats!=32 || half_writes!=4 || descriptors!=2 ||
            tokens!=16 || output_groups!=1 || ddv) errors=errors+1;
`ifdef DS1_ADDRESS_ADAPTER
        if (adapter_error) errors=errors+1;
`endif
        if(errors==0)
            $display("PASS real_producer cin=16 pixels=8 cout=8 cycles=%0d first_output=%0d halves=%0d descriptors=%0d tokens=%0d outputs=%0d",total_cycles,first_output_cycle,half_writes,descriptors,tokens,outputs);
        else begin
            $display("FAIL real_producer errors=%0d error_sig=%b cycles=%0d outputs=%0d halves=%0d descriptors=%0d tokens=%0d",errors,error,total_cycles,outputs,half_writes,descriptors,tokens);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat(800000) @(posedge clk);
        $display("REAL_PRODUCER_WATCHDOG fsv=%b fsr=%b fdv=%b mrv=%b mrr=%b mspv=%b djv=%b djr=%b ddv=%b done=%b pipe_state=%0d input_done=%b commit_done=%b final_out=%b token_active=%b waiting_out=%b cache=%0d producer_state=%0d fill_busy=%b asm_state=%0d asm_done=%b half_valid=%b half_pipe=%b bank_writes=%b bank_drain=%b",
            fsv, fsr, fdv, mrv, mrr, mspv, djv, djr, ddv, done,
            dut.u_group_ready.state, dut.u_group_ready.input_done_reg,
            dut.u_group_ready.commit_done_reg, dut.u_group_ready.final_output_done,
            dut.u_group_ready.token_active, dut.u_group_ready.waiting_output,
            dut.u_group_ready.cache_count, dut.u_real_producer.u_4x8.state,
            dut.u_real_producer.u_4x8.u_producer.u_window_shell.fill_busy,
            dut.u_group_ready.u_assembler.state, dut.u_group_ready.asm_done,
            dut.u_group_ready.asm_half_valid, dut.u_group_ready.half_pipe_valid,
            dut.u_group_ready.s0_all_writes, dut.u_group_ready.s0_all_drained);
`ifdef DS1_ADDRESS_ADAPTER
        $display("ADAPTER_WATCHDOG fsv=%b fsr=%b fdv=%b mrv=%b mrr=%b mspv=%b producer_req=%b producer_ready=%b producer_resp=%b fifo=%0d active=%b ctx_ready=%b fill_busy=%b pipe_state=%0d",
            fsv, fsr, fdv, mrv, mrr, mspv, producer_mrv, producer_mrr,
            producer_mspv, u_ds1_adapter.fifo_count, u_ds1_adapter.context_active,
            adapter_context_ready, dut.u_real_producer.u_4x8.u_producer.u_window_shell.fill_busy,
            dut.u_group_ready.state);
`endif
        $fatal(1,"WATCHDOG");
    end
endmodule
`default_nettype wire
