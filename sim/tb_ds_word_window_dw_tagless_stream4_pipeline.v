`timescale 1ns/1ps
`default_nettype none

/* Exact storage proof for the tagless left-half path.  The source window is
 * all zero, while DW bias is 37 and the fixed-point multiplier is one; every
 * enabled output byte must therefore be 37.  The final group of the tail case
 * deliberately enables only five lanes, proving that invalid lanes are not
 * presented as valid stored bytes. */
module tb_ds_word_window_dw_tagless_stream4_pipeline;
    localparam integer AW=24, WW=16, EW=4, TW=8, FW=10, WORDS=400;
    localparam [23:0] BASE0=24'h100000, BASE1=24'h200000;
    reg clk=0, rst_n=0; always #1 clk=~clk;

    reg fsv=0, fsb=0; reg [3:0] fse=0; reg [23:0] fba=0; reg [15:0] fwc=WORDS;
    wire fsr, fdv, fdb; wire [3:0] fde; reg fdr=1;
    wire mrv; reg mrr=1; wire [23:0] mra; reg mspv=0; reg [31:0] msd=0;
    reg cv=0; wire cready; reg [3:0] cti=0; reg signed [127:0] cwv=0;
    reg signed [511:0] cbv=0, cmv=0; reg [95:0] csv=0;
    reg djv=0; wire djr; reg dsb=0; reg [3:0] dse=0; reg [23:0] dba=0;
    reg [15:0] dsm=16'hffff; reg [1:0] dss=1; reg [7:0] dfh=10,dfw=10,dfp=10;
    reg dtb=0; reg [3:0] dte=0; reg [7:0] dtt=0; reg [2:0] dcg=0;
    reg [3:0] dgc=1; reg [7:0] dpc=64; reg [31:0] dzp=0;
    reg [31:0] dmin=-2147483648, dmax=2147483647;
    wire ddv; reg ddr=1; wire ddb; wire [3:0] dde; wire [7:0] ddt; wire [2:0] ddg;
    reg rav=0; wire rar; reg rb=0; reg [3:0] re=0; reg [7:0] rt=0;
    reg rv=0; wire rr; reg [6:0] rci=0; reg [5:0] rpb=0;
    wire rov; reg ror=1; wire [63:0] rod; wire [7:0] rom;
    reg rrelv=0; wire rrelr;
    wire [1:0] s0,s1; wire [31:0] dwc,ovc,rc;

    ds_word_window_dw_tagless_stream4_pipeline #(
        .MAX_IN_H(17), .MAX_IN_W(17), .ADDR_WIDTH(AW),
        .WORD_COUNT_WIDTH(WW), .EPOCH_WIDTH(EW), .TILE_WIDTH(TW), .FIFO_DEPTH(8),
        .USE_LOCAL_REQUANT(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .fill_start_valid(fsv), .fill_start_ready(fsr),
        .fill_start_bank(fsb), .fill_start_epoch(fse), .fill_start_base_addr(fba),
        .fill_start_word_count(fwc), .fill_done_valid(fdv), .fill_done_ready(fdr),
        .fill_done_bank(fdb), .fill_done_epoch(fde), .mem_req_valid(mrv),
        .mem_req_ready(mrr), .mem_req_addr(mra), .mem_resp_valid(mspv),
        .mem_resp_data(msd), .cfg_valid(cv), .cfg_ready(cready), .cfg_tap_idx(cti),
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
        .dw_done_epoch(dde), .dw_done_tile(ddt), .dw_done_group(ddg),
        .read_acquire_valid(rav), .read_acquire_ready(rar), .read_bank(rb),
        .read_epoch(re), .read_tile(rt), .read_valid(rv), .read_ready(rr),
        .read_channel_idx(rci), .read_pixel_base(rpb), .read_out_valid(rov),
        .read_out_ready(ror), .read_out_data(rod), .read_out_lane_mask(rom),
        .read_release_valid(rrelv), .read_release_ready(rrelr),
        .scratch0_state(s0), .scratch1_state(s1), .dw_write_count(dwc),
        .overlap_cycles(ovc), .read_count(rc)
    );

    /* Three-cycle source-memory response with deterministic request stalls. */
    reg qv[0:2]; reg [31:0] qd[0:2]; integer qi;
    integer cycles=0, errors=0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (!rst_n) begin
            mspv<=0; msd<=0; mrr<=1;
            for (qi=0;qi<3;qi=qi+1) begin qv[qi]<=0; qd[qi]<=0; end
        end else begin
            mspv<=qv[0]; msd<=qd[0];
            for (qi=0;qi<2;qi=qi+1) begin qv[qi]<=qv[qi+1]; qd[qi]<=qd[qi+1]; end
            qv[2]<=0; qd[2]<=0; mrr<=((cycles%17)!=5);
            if (mrv && mrr) begin qv[2]<=1; qd[2]<=0; end
        end
    end

    task configure_dw; integer t,l; begin
        for (t=0;t<9;t=t+1) begin
            @(negedge clk); cti=t; cwv=0; cbv=0; cmv=0; csv=0;
            for (l=0;l<16;l=l+1) begin
                cbv[l*32 +: 32]=37;
                cmv[l*32 +: 32]=32'sh7fffffff;
            end
            cv=1; while(!cready) @(posedge clk); @(posedge clk); @(negedge clk); cv=0;
        end
    end endtask

    task fill_bank; input integer bank_arg, ep_arg; begin
        @(negedge clk); fsb=bank_arg; fse=ep_arg; fba=bank_arg?BASE1:BASE0;
        fwc=WORDS; fsv=1; while(!fsr) @(posedge clk); @(posedge clk); @(negedge clk); fsv=0;
        while(!fdv) @(posedge clk); @(negedge clk); fdr=1; @(posedge clk); @(negedge clk);
    end endtask

    task compute_case;
        input integer bank_arg, ep_arg, tile_arg, groups_arg, tail_arg, prefilled_arg;
        integer g,l,lane_count; begin
        for (g=0;g<groups_arg;g=g+1) begin
            /* The producer releases its source-window bank after every
             * group.  Refill that independent source bank before the next
             * K group; this keeps the proof faithful to the existing shell
             * ownership contract while the opposite scratch bank may stay
             * in PW ownership. */
            if ((g != 0) || (prefilled_arg == 0)) fill_bank(bank_arg, ep_arg);
            lane_count = ((tail_arg != 0) && (g == groups_arg-1)) ? 5 : 16;
            @(negedge clk); dsb=bank_arg; dse=ep_arg; dba=bank_arg?BASE1:BASE0;
            dsm=0; for (l=0;l<lane_count;l=l+1) dsm[l]=1;
            dss=1; dfh=10; dfw=10; dfp=10; dtb=bank_arg; dte=ep_arg;
            dtt=tile_arg; dcg=g; dgc=groups_arg; dpc=64; dzp=0;
            dmin=-2147483648; dmax=2147483647; djv=1;
            while(!djr) @(posedge clk); @(posedge clk); @(negedge clk); djv=0;
            if (g == groups_arg-1) begin
                while(!ddv) @(posedge clk);
                if (ddb!==bank_arg || dde!==ep_arg || ddt!==tile_arg) errors=errors+1;
                @(posedge clk);
            end else begin
                while(!djr) @(posedge clk);
            end
        end
    end endtask

    task read_case;
        input integer bank_arg, ep_arg, tile_arg, groups_arg, tail_arg;
        integer ch,row,p,valid_ch; reg [63:0] hold_data; reg [7:0] hold_mask;
        begin
            @(negedge clk); rb=bank_arg; re=ep_arg; rt=tile_arg; rav=1;
            while(!rar) @(posedge clk); @(posedge clk); @(negedge clk); rav=0;
            for (ch=0;ch<groups_arg*16;ch=ch+1) begin
                valid_ch = (tail_arg != 0 && ch >= (groups_arg-1)*16+5) ? 0 : 1;
                for (row=0;row<64;row=row+8) begin
                    @(negedge clk); rci=ch; rpb=row; rv=1;
                    while(!rr) @(posedge clk); @(posedge clk); @(negedge clk); rv=0;
                    while(!rov) @(negedge clk);
                    if ((cycles % 9)==0) begin
                        hold_data=rod; hold_mask=rom; ror=0; @(negedge clk);
                        if (rov && (rod!==hold_data || rom!==hold_mask)) errors=errors+1;
                        ror=1;
                    end
                    @(posedge clk);
                    for (p=0;p<8;p=p+1) begin
                        if (rom[p] !== 1'b1) errors=errors+1;
                        if (valid_ch && rod[p*8 +: 8] !== 8'd37) errors=errors+1;
                        if (!valid_ch && rod[p*8 +: 8] !== 8'd0) errors=errors+1;
                    end
                end
            end
            @(negedge clk); rrelv=1; while(!rrelr) @(posedge clk);
            @(posedge clk); @(negedge clk); rrelv=0;
        end
    endtask

    initial begin
        repeat(4) @(posedge clk); rst_n=1; configure_dw();
        compute_case(0,1,8'h10,1,0,0);
        /* Keep bank zero in PW ownership while bank one is produced. */
        fill_bank(1,2);
        fork
            read_case(0,1,8'h10,1,0);
            compute_case(1,2,8'h11,3,0,1);
        join
        read_case(1,2,8'h11,3,0);
        /* Reuse bank zero for an eight-group Cin=128 tail session. */
        compute_case(0,3,8'h12,8,1,0);
        read_case(0,3,8'h12,8,1);
        if (ovc == 0) errors=errors+1;
        if (errors==0)
            $display("PASS tb_ds_word_window_dw_tagless_stream4_pipeline cycles=%0d writes=%0d reads=%0d overlap=%0d",cycles,dwc,rc,ovc);
        else begin $display("FAIL tb_ds_word_window_dw_tagless_stream4_pipeline errors=%0d cycles=%0d overlap=%0d",errors,cycles,ovc); $fatal(1); end
        $finish;
    end
    initial begin
        repeat(700000) @(posedge clk);
        $display("WATCHDOG state=%0d bank=%0d group=%0d dwc=%0d target=%0d producer_state=%0d producer_busy=%b shell_ready=%b shell_banks=%0d/%0d adapter_busy=%b s0=%0d s1=%0d ddv=%b djr=%b rov=%b rr=%b", dut.state, dut.target_bank_reg, dut.group_reg, dwc, dut.write_target_count, dut.u_producer.state, dut.compute_busy, dut.u_producer.shell_read_start_ready, dut.u_producer.bank0_state, dut.u_producer.bank1_state, dut.adapter_busy, s0, s1, ddv, djr, rov, rr);
        $fatal(1,"WATCHDOG");
    end
endmodule
`default_nettype wire
