`timescale 1ns/1ps
`default_nettype none

/*
 * Deterministic timing probe for one real 4x8 producer command.
 *
 * This is deliberately independent of the production runner.  It fills the
 * source through the real request/response FIFO, configures all nine taps,
 * admits one real DW command, and waits for the real scratch write fence.
 * Data is zero, but all source requests, DW tokens, four-beat requant writes,
 * and ownership handshakes are active.  The probe exists to calibrate the
 * cycle-budget model; it is not a functional replacement for the existing
 * randomized regressions.
 */
module tb_ds_word_window_dw_tagless_stream4_4x8_timing #(
    parameter integer TB_STRIDE = 1
);
    localparam integer AW=24, WW=16, EW=4, TW=8;
    localparam integer FH = (TB_STRIDE == 2) ? 9 : 6;
    localparam integer FW = (TB_STRIDE == 2) ? 17 : 10;
    localparam integer WORDS = FH*FW*4;
    localparam integer BASE = 24'h100000;

    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;
    reg fsv=0, fsb=0; reg [EW-1:0] fse=0;
    reg [AW-1:0] fba=0; reg [WW-1:0] fwc=WORDS;
    wire fsr, fdv, fdb; wire [EW-1:0] fde; reg fdr=1;
    wire mrv; reg mrr=1; wire [AW-1:0] mra;
    reg mspv=0; reg [31:0] msd=0;
    reg cv=0; wire cr; reg [3:0] cti=0;
    reg signed [127:0] cwv=0; reg signed [511:0] cbv=0, cmv=0;
    reg [95:0] csv=0;
    reg djv=0; wire djr; reg dsb=0; reg [EW-1:0] dse=0;
    reg [AW-1:0] dba=BASE; reg [15:0] dsm=16'hffff;
    reg [1:0] dss=TB_STRIDE; reg [7:0] dfh=FH,dfw=FW,dfp=FW;
    reg dtb=0; reg [EW-1:0] dte=0; reg [TW-1:0] dtt=0;
    reg [2:0] dcg=0; reg [3:0] dgc=1; reg [7:0] dpc=32;
    reg [31:0] dzp=0, dmin=0, dmax=255;
    wire ddv; reg ddr=1; wire ddb; wire [EW-1:0] dde;
    wire [TW-1:0] ddt; wire [2:0] ddg;
    reg rav=0; wire rar; reg rb=0; reg [EW-1:0] re=0;
    reg [TW-1:0] rt=0; reg rv=0; wire rr; reg [6:0] rci=0;
    reg [5:0] rpb=0; wire rov; reg ror=1; wire [63:0] rod; wire [7:0] rom;
    reg rrelv=0; wire rrelr; wire [1:0] s0,s1;
    wire [31:0] dwc,ovc,rc;

    ds_word_window_dw_tagless_stream4_4x8 #(
        .MAX_IN_H(17), .MAX_IN_W(17), .ADDR_WIDTH(AW),
        .WORD_COUNT_WIDTH(WW), .EPOCH_WIDTH(EW), .TILE_WIDTH(TW),
        .FIFO_DEPTH(8), .USE_QUADLOCAL_CORE(1), .USE_LOCAL_REQUANT(1)
    ) dut (
        .clk(clk),.rst_n(rst_n),.fill_start_valid(fsv),.fill_start_ready(fsr),
        .fill_start_bank(fsb),.fill_start_epoch(fse),.fill_start_base_addr(fba),
        .fill_start_word_count(fwc),.fill_done_valid(fdv),.fill_done_ready(fdr),
        .fill_done_bank(fdb),.fill_done_epoch(fde),.mem_req_valid(mrv),
        .mem_req_ready(mrr),.mem_req_addr(mra),.mem_resp_valid(mspv),
        .mem_resp_data(msd),.cfg_valid(cv),.cfg_ready(cr),.cfg_tap_idx(cti),
        .cfg_weight_vec(cwv),.cfg_bias_vec(cbv),.cfg_multiplier_vec(cmv),
        .cfg_shift_vec(csv),.dw_job_valid(djv),.dw_job_ready(djr),
        .dw_source_bank(dsb),.dw_source_epoch(dse),.dw_source_base_addr(dba),
        .dw_source_lane_mask(dsm),.dw_source_stride(dss),
        .dw_footprint_height(dfh),.dw_footprint_width(dfw),
        .dw_footprint_pitch(dfp),.dw_target_bank(dtb),.dw_target_epoch(dte),
        .dw_target_tile(dtt),.dw_channel_group(dcg),.dw_group_count(dgc),
        .dw_pixel_count(dpc),.dw_output_zero_point(dzp),
        .dw_activation_min(dmin),.dw_activation_max(dmax),
        .dw_done_valid(ddv),.dw_done_ready(ddr),.dw_done_bank(ddb),
        .dw_done_epoch(dde),.dw_done_tile(ddt),.dw_done_group(ddg),
        .read_acquire_valid(rav),.read_acquire_ready(rar),.read_bank(rb),
        .read_epoch(re),.read_tile(rt),.read_valid(rv),.read_ready(rr),
        .read_channel_idx(rci),.read_pixel_base(rpb),.read_out_valid(rov),
        .read_out_ready(ror),.read_out_data(rod),.read_out_lane_mask(rom),
        .read_release_valid(rrelv),.read_release_ready(rrelr),
        .scratch0_state(s0),.scratch1_state(s1),.dw_write_count(dwc),
        .overlap_cycles(ovc),.read_count(rc)
    );

    /* Three-cycle registered source response, no request bubbles. */
    reg qv[0:2]; reg [31:0] qd[0:2]; integer qi;
    always @(posedge clk) begin
        if (!rst_n) begin
            mspv <= 0; msd <= 0;
            for (qi=0; qi<3; qi=qi+1) begin qv[qi] <= 0; qd[qi] <= 0; end
        end else begin
            mspv <= qv[0]; msd <= qd[0];
            for (qi=0; qi<2; qi=qi+1) begin qv[qi] <= qv[qi+1]; qd[qi] <= qd[qi+1]; end
            qv[2] <= 0;
            qd[2] <= 0;
            /* Nonzero deterministic source data: exercise the real source
             * response path rather than a zero-only timing smoke. */
            if (mrv && mrr) begin
                qv[2] <= 1;
                qd[2] <= 32'h0102_0304 ^ {8'h00,mra};
            end
        end
    end

    integer cycles=0, fill_start_cycle, fill_done_cycle;
    integer job_start_cycle, done_cycle, errors=0;
    integer t,l;
    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        for (t=0; t<9; t=t+1) begin
            @(negedge clk); cti=t; cwv=0; cbv=0; cmv=0; csv=0;
            for (l=0; l<16; l=l+1) begin
                cwv[l*8 +: 8]=l+1;
                cbv[l*32 +: 32]=0;
                cmv[l*32 +: 32]=1;
            end
            cv=1; while (!cr) @(posedge clk);
            @(posedge clk); @(negedge clk); cv=0;
        end
        @(negedge clk); fill_start_cycle=cycles; fse=1; fba=BASE;
        fsv=1; while (!fsr) @(posedge clk);
        @(posedge clk); @(negedge clk); fsv=0;
        while (!fdv) @(posedge clk);
        fill_done_cycle=cycles; @(negedge clk);
        @(negedge clk); job_start_cycle=cycles; dse=1; dte=1; dtt=0;
        dss=TB_STRIDE; dfh=FH; dfw=FW; dfp=FW; dpc=32; djv=1;
        while (!djr) @(posedge clk);
        @(posedge clk); @(negedge clk); djv=0;
        while (!ddv) @(posedge clk);
        done_cycle=cycles;
        if (dwc != 128 || dut.u_4x8.u_producer.token_count != 288)
            errors=errors+1;
        if (errors==0)
            $display("PASS producer timing nonzero_source=1 stride=%0d words=%0d fill_cycles=%0d job_cycles=%0d total_cycles=%0d dw_writes=%0d tokens=%0d",
                     TB_STRIDE, WORDS, fill_done_cycle-fill_start_cycle,
                     done_cycle-job_start_cycle, cycles, dwc,
                     dut.u_4x8.u_producer.token_count);
        else begin
            $display("FAIL producer timing stride=%0d errors=%0d words=%0d fill_cycles=%0d job_cycles=%0d writes=%0d tokens=%0d",
                     TB_STRIDE, errors, WORDS,
                     fill_done_cycle-fill_start_cycle, done_cycle-job_start_cycle,
                     dwc, dut.u_4x8.u_producer.token_count);
            $fatal(1);
        end
        $finish;
    end
    always @(posedge clk) cycles <= cycles + 1;
    initial begin
        repeat(1000000) @(posedge clk);
        $fatal(1,"WATCHDOG state=%0d producer=%0d",dut.u_4x8.state,
               dut.u_4x8.u_producer.state);
    end
endmodule
`default_nettype wire
