`timescale 1ns/1ps
`default_nettype none

/* Six actual C10 DS shapes.  DW beats are deterministic non-zero signed
 * values (zero only for spatial/channel tails); the scoreboard accumulates
 * the same values through every published group and checks all 4-byte PW
 * outputs.  A periodic ready pattern exercises descriptor and output stalls. */
module tb_ds_group_published_shared64_sweep;
    reg clk = 0; always #1 clk = ~clk;
    reg rst_n = 0;
    reg start_valid = 0; wire start_ready;
    reg [10:0] start_pixels; reg [7:0] start_cin; reg [8:0] start_cout;
    reg start_bank = 0; reg [1:0] start_session = 0; reg [3:0] start_epoch = 0;
    reg dw_valid = 0; wire dw_ready; reg [7:0] dw_macro;
    reg [1:0] dw_row; reg [4:0] dw_group; reg dw_channel_half;
    reg [2:0] dw_pixel; reg [31:0] dw_data; reg [3:0] dw_mask; reg dw_last;
    reg wv = 0; wire wr; reg [4:0] wt; reg [7:0] wk; reg signed [63:0] wvec;
    wire rv; reg rr = 1; wire [10:0] rp; wire [8:0] rc; wire [3:0] rm;
    wire signed [31:0] rd; wire done, error;
    wire [31:0] total_cyc, dw_writes, descs, pw_tokens, out_writes, out_groups, preload;

    ds_group_published_shared64_sweep dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
         .start_pixels(start_pixels), .start_output_height(11'd0), .start_output_width(11'd8),
         .start_cin(start_cin), .start_cout(start_cout),
        .start_bank(start_bank), .start_session(start_session), .start_epoch(start_epoch),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_macro(dw_macro),
        .dw_row(dw_row), .dw_group(dw_group), .dw_channel_half(dw_channel_half),
        .dw_pixel(dw_pixel), .dw_data(dw_data), .dw_mask(dw_mask), .dw_last(dw_last),
        .weight_load_valid(wv), .weight_load_ready(wr), .weight_load_tile(wt),
        .weight_load_k(wk), .weight_load_vec(wvec), .result_valid(rv),
        .pw_param_load_valid(1'b0), .pw_param_load_ready(),
        .pw_param_load_channel(9'd0), .pw_param_load_bias(32'sd0),
        .pw_param_load_multiplier(32'sh4000_0000), .pw_param_load_shift(6'd0),
        .pw_output_zero_point_int32(32'sd0),
        .pw_activation_min_int32(-32'sd128), .pw_activation_max_int32(32'sd127),
        .result_ready(rr), .result_pixel_idx(rp), .result_channel_base(rc),
        .result_lane_mask(rm), .result_data(rd), .done(done), .error(error),
        .perf_total_cycles(total_cyc), .perf_dw_writes(dw_writes),
        .perf_group_descriptors(descs), .perf_pw_tokens(pw_tokens),
        .perf_output_writes(out_writes), .perf_output_groups(out_groups),
        .perf_preload_rows(preload)
    );

    integer errors = 0, layer_idx, b, r, g, h, p, c, t, k;
    integer exp_sum [0:127][0:31][0:7][0:7];
    integer sink_cycles = 0;
    integer result_checks = 0;
    integer dw_stall_total = 0, output_stall_total = 0;
    integer metrics_fd;
    /* Per-layer protocol audit.  These are simulation-only counters: they
     * make the partial-K contract observable without adding RTL state. */
    integer audit_tokens, audit_first_k, audit_last_k, audit_rq_groups;
    integer audit_intermediate_rq, audit_overlap_cycles, audit_preload_base;
    integer audit_final_tokens_available;
    reg audit_active = 0;
    function integer dw_byte;
        input integer li, bi, ri, gi, hi, pi, ci;
        integer x;
        begin
            if ((bi*8 + ri*2 + pi) >= 1000000) x = 0;
            else begin
                x = ((li*17 + bi*7 + ri*5 + gi*3 + hi*2 + pi + ci) % 5) - 2;
                if (x == 0) x = 1;
            end
            dw_byte = x;
        end
    endfunction
    function integer quant_half;
        input integer x;
        begin
            if (x < 0) quant_half = -(((-x)+1)/2);
            else quant_half = (x+1)/2;
            if (quant_half > 127) quant_half = 127;
            if (quant_half < -128) quant_half = -128;
        end
    endfunction
    function integer expected_byte;
        input integer li, bi, ti, pi, lane;
        begin expected_byte = quant_half(exp_sum[bi][ti][pi][lane]); end
    endfunction

    always @(posedge clk) begin
        integer oi, lane_idx, row_idx, tile_idx, got_byte, want_byte;
        if (rst_n && audit_active) begin
            if (dut.u_shared_ds.input_fire) begin
                audit_tokens = audit_tokens + 1;
                if (dut.u_shared_ds.first_k) begin
                    audit_first_k = audit_first_k + 1;
                    if (!((dut.pw_group_q == 0) && (dut.pw_k_q == 0))) begin
                        $display("BAD_FIRST_K row=%0d tile=%0d group=%0d k=%0d",
                                 dut.pw_row_block_q, dut.pw_tile_q,
                                 dut.pw_group_q, dut.pw_k_q);
                        errors = errors + 1;
                    end
                end else if ((dut.pw_group_q == 0) && (dut.pw_k_q == 0)) begin
                    $display("MISSING_FIRST_K row=%0d tile=%0d",
                             dut.pw_row_block_q, dut.pw_tile_q);
                    errors = errors + 1;
                end
                if (dut.u_shared_ds.last_k) begin
                    audit_last_k = audit_last_k + 1;
                    audit_final_tokens_available = audit_final_tokens_available + 1;
                    if (!(dut.pw_final_group && dut.pw_final_k)) begin
                        $display("BAD_LAST_K row=%0d tile=%0d group=%0d k=%0d",
                                 dut.pw_row_block_q, dut.pw_tile_q,
                                 dut.pw_group_q, dut.pw_k_q);
                        errors = errors + 1;
                    end
                end else if (dut.pw_final_group && dut.pw_final_k) begin
                    $display("MISSING_LAST_K row=%0d tile=%0d",
                             dut.pw_row_block_q, dut.pw_tile_q);
                    errors = errors + 1;
                end
            end
            if (dut.dw_fire && dut.u_shared_ds.input_fire)
                audit_overlap_cycles = audit_overlap_cycles + 1;
            if (dut.u_shared_ds.drain_start) begin
                audit_rq_groups = audit_rq_groups + 1;
                if (audit_final_tokens_available == 0) begin
                    audit_intermediate_rq = audit_intermediate_rq + 1;
                    $display("INTERMEDIATE_RQ row=%0d tile=%0d",
                             dut.pw_row_block_q, dut.pw_tile_q);
                    errors = errors + 1;
                end
                else
                    audit_final_tokens_available = audit_final_tokens_available - 1;
            end
        end
        if (rst_n && dw_valid && !dw_ready) dw_stall_total=dw_stall_total+1;
        if (rst_n && rv && !rr) output_stall_total=output_stall_total+1;
        if (rst_n && rv && rr) begin
            row_idx = rp >> 3;
            tile_idx = rc >> 3;
            if (rm != 4'hf && start_cout >= rc + 4)
                $display("MASK_GAP rp=%0d rc=%0d mask=%h start_cout=%0d",rp,rc,rm,start_cout);
            for (oi=0; oi<4; oi=oi+1) begin
                lane_idx = (rc & 7) + oi;
                if (rm[oi]) begin
                    got_byte = $signed(rd[oi*8 +: 8]);
                    want_byte = expected_byte(0,row_idx,tile_idx,rp & 7,lane_idx);
                    if (got_byte != want_byte) begin
                        if (errors < 8)
                            $display("RESULT_MISMATCH row=%0d tile=%0d p=%0d lane=%0d got=%0d exp=%0d acc=%0d",row_idx,tile_idx,rp&7,lane_idx,got_byte,want_byte,exp_sum[row_idx][tile_idx][rp&7][lane_idx]);
                        errors=errors+1;
                    end
                    result_checks=result_checks+1;
                end
            end
        end
    end

    task load_weights;
        input integer li; input integer cin; input integer cout;
        integer tile, kk, cc, val;
        begin
            for (tile=0; tile<(cout+7)/8; tile=tile+1)
                for (kk=0; kk<cin; kk=kk+1) begin
                    wvec = 0;
                    for (cc=0; cc<8; cc=cc+1) begin
                        /* Unit PW weights keep the requant reference compact;
                         * DW values remain signed, varying, and non-zero. */
                        val = 1;
                        wvec[cc*8 +: 8] = val[7:0];
                    end
                    @(negedge clk); wt=tile; wk=kk; wv=1;
                    while (!wr) @(posedge clk);
                    @(posedge clk); @(negedge clk); wv=0;
                end
        end
    endtask

    task run_layer;
        input integer li; input integer pixels; input integer cin; input integer cout;
        integer macros, rows, groups, tiles, val, lane, out_count, expect_out;
        integer mb, rrw, gg, hh, pp, cc, pix_abs, ch_abs, block_row, wait_beats, rows_in_macro;
        integer dw_stall_start, output_stall_start, result_check_start;
        begin
            $display("BEGIN_LAYER li=%0d P=%0d Cin=%0d Cout=%0d",li,pixels,cin,cout);
            rows=(pixels+7)/8; macros=(pixels+31)/32; groups=(cin+7)/8;
            tiles=(cout+7)/8; expect_out=rows*tiles*16; out_count=0;
            dw_stall_start=dw_stall_total; output_stall_start=output_stall_total;
            result_check_start=result_checks;
            audit_preload_base = preload;
            for (b=0;b<128;b=b+1) for(t=0;t<32;t=t+1)
                for(p=0;p<8;p=p+1) for(c=0;c<8;c=c+1) exp_sum[b][t][p][c]=0;
            load_weights(li,cin,cout);
            $display("WEIGHTS_DONE li=%0d preload=%0d",li,preload);
            /* Allow the previous layer's one-cycle done indication to
             * retire before presenting a new start transaction. */
            @(posedge clk);
            @(negedge clk); start_pixels=pixels; start_cin=cin; start_cout=cout;
            start_session=li[1:0]; start_epoch=(li+1); start_valid=1;
            audit_tokens = 0; audit_first_k = 0; audit_last_k = 0;
            audit_rq_groups = 0; audit_intermediate_rq = 0;
            audit_overlap_cycles = 0; audit_final_tokens_available = 0;
            audit_active = 1'b1;
            begin : wait_start_accept
                while (1) begin
                    @(posedge clk);
                    if (start_ready) begin
                        @(negedge clk); start_valid=0; disable wait_start_accept;
                    end
                end
            end

            /* A 4x8 macro is four 8-pixel rows.  Each group has two
             * four-channel 32-bit beats per pixel. */
            for (mb=0;mb<macros;mb=mb+1) begin
                rows_in_macro=(pixels-mb*32+7)/8;
                if (rows_in_macro > 4) rows_in_macro=4;
                for (rrw=0;rrw<rows_in_macro;rrw=rrw+1)
                    for (gg=0;gg<groups;gg=gg+1)
                        for (hh=0;hh<2;hh=hh+1)
                            for (pp=0;pp<8;pp=pp+1) begin
                                dw_data=0; dw_mask=0;
                                pix_abs=mb*32+rrw*8+pp;
                                for (cc=0;cc<4;cc=cc+1) begin
                                    ch_abs=gg*8+hh*4+cc;
                                    val=(pix_abs<pixels && ch_abs<cin) ?
                                        dw_byte(li,mb,rrw,gg,hh,pp,cc+hh*4) : 0;
                                    dw_data[cc*8 +: 8]=val[7:0];
                                    if (pix_abs<pixels && ch_abs<cin) dw_mask[cc]=1;
                                    if (pix_abs<pixels && ch_abs<cin)
                                        for (t=0;t<tiles;t=t+1)
                                            for (lane=0;lane<8;lane=lane+1)
                                                exp_sum[mb*4+rrw][t][pp][lane] =
                                                    exp_sum[mb*4+rrw][t][pp][lane] + val;
                                end
                                @(negedge clk); dw_macro=mb; dw_row=rrw; dw_group=gg;
                                dw_channel_half=hh; dw_pixel=pp;
                                dw_last=(mb==macros-1 && rrw+1==rows_in_macro &&
                                         gg==groups-1 && hh==1 && pp==7);
                                dw_valid=1;
                                begin : wait_dw_accept
                                    wait_beats=0;
                                    while (1) begin
                                        @(posedge clk); wait_beats=wait_beats+1;
                                        if (dw_ready) begin
                                            @(negedge clk); dw_valid=0; dw_last=0;
                                            disable wait_dw_accept;
                                        end
                                        if (wait_beats==10000) begin
                                            $display("DW_STALL li=%0d macro=%0d row=%0d group=%0d half=%0d pixel=%0d state=%0d published=%0d pwrow=%0d pwtile=%0d pwgroup=%0d pub=%b busy0=%b busy1=%b core=%b out=%0d",li,mb,rrw,gg,hh,pp,dut.state,dut.perf_group_descriptors,dut.pw_row_block_q,dut.pw_tile_q,dut.pw_group_q,dut.pw_published,dut.bank_busy0,dut.bank_busy1,dut.core_busy,out_writes);
                                            errors=errors+1; $fatal(1,"DW stall");
                                        end
                                    end
                                end
                            end
            end
            while (!done) begin
                @(posedge clk);
                if (total_cyc > 200000) begin
                    $display("LAYER_WATCHDOG li=%0d state=%0d total=%0d dw=%0d desc=%0d pw=%0d out=%0d core_busy=%b pw_row=%0d pw_tile=%0d pw_group=%0d published=%b",li,dut.state,total_cyc,dw_writes,descs,pw_tokens,out_writes,dut.core_busy,dut.pw_row_block_q,dut.pw_tile_q,dut.pw_group_q,dut.pw_published);
                    errors=errors+1; $fatal(1,"WATCHDOG");
                end
            end
            if (error) errors=errors+1;
            if (dw_writes !== pixels*((cin+7)/8)*2) begin
                $display("DW_COUNT li=%0d got=%0d exp=%0d",li,dw_writes,pixels*groups*2); errors=errors+1;
            end
            if (descs !== rows*groups) begin
                $display("DESC_COUNT li=%0d got=%0d exp=%0d",li,descs,rows*groups); errors=errors+1;
            end
            if (pw_tokens !== pixels*cin*tiles/8) begin
                $display("PW_COUNT li=%0d got=%0d exp=%0d",li,pw_tokens,pixels*cin*tiles/8); errors=errors+1;
            end
            if (out_writes !== expect_out) begin
                $display("OUT_COUNT li=%0d got=%0d exp=%0d",li,out_writes,expect_out); errors=errors+1;
            end
            if (audit_tokens !== pixels*cin*tiles/8) begin
                $display("AUDIT_TOKEN_COUNT li=%0d got=%0d exp=%0d",li,audit_tokens,pixels*cin*tiles/8);
                errors = errors + 1;
            end
            if (audit_first_k !== rows*tiles || audit_last_k !== rows*tiles) begin
                $display("AUDIT_FIRST_LAST li=%0d first=%0d last=%0d exp=%0d",li,audit_first_k,audit_last_k,rows*tiles);
                errors = errors + 1;
            end
            if (audit_rq_groups !== rows*tiles || audit_intermediate_rq !== 0 ||
                audit_final_tokens_available !== 0) begin
                $display("AUDIT_RQ li=%0d groups=%0d intermediate=%0d pending=%0d exp=%0d",li,audit_rq_groups,audit_intermediate_rq,audit_final_tokens_available,rows*tiles);
                errors = errors + 1;
            end
            audit_active = 1'b0;
            $display("LAYER li=%0d P=%0d Cin=%0d Cout=%0d cycles=%0d dw=%0d desc=%0d pw=%0d rq=%0d groups=%0d preload=%0d overlap=%0d first=%0d last=%0d intermediate_rq=%0d macs=%0d ops=%0d",li,pixels,cin,cout,total_cyc,dw_writes,descs,pw_tokens,out_writes,out_groups,preload-audit_preload_base,audit_overlap_cycles,audit_first_k,audit_last_k,audit_intermediate_rq,pixels*cin*cout,2*pixels*cin*cout);
            if (metrics_fd != 0)
                $fwrite(metrics_fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",li,pixels,cin,cout,total_cyc,dw_writes,descs,pw_tokens,out_writes,out_groups,preload-audit_preload_base,audit_overlap_cycles,audit_tokens,audit_first_k,audit_last_k,audit_rq_groups,audit_intermediate_rq,pixels*cin*cout,2*pixels*cin*cout,dw_stall_total-dw_stall_start,output_stall_total-output_stall_start,result_checks-result_check_start);
        end
    endtask

    /* Output sink: it deliberately inserts deterministic bubbles while
     * keeping ready stable for each cycle. */
    always @(negedge clk) begin
        if (rst_n) begin sink_cycles=sink_cycles+1; rr <= ((sink_cycles%29)!=7 && (sink_cycles%31)!=13); end
        else rr <= 1;
    end

    initial begin
        metrics_fd=$fopen("build/reports/ds_group_published_shared64_sweep_metrics.csv","w");
        if (metrics_fd != 0)
            $fwrite(metrics_fd,"layer,pixels,cin,cout,cycles,dw_writes,descriptors,pw_tokens,rq_writes,output_groups,preload_rows,overlap_cycles,audit_tokens,first_k,last_k,rq_groups,intermediate_rq,macs,ops,dw_stalls,output_stalls,result_checks\n");
        repeat(5) @(posedge clk); rst_n=1;
        run_layer(0,1024,16,32);
        run_layer(1,256,32,64);
        run_layer(2,256,64,64);
        run_layer(3,64,64,128);
        run_layer(4,64,128,128);
        run_layer(5,16,128,256);
        if (errors==0)
            $display("PASS ds_group_published_shared64_sweep total_dw=%0d total_pw=%0d total_rq=%0d",dw_writes,pw_tokens,out_writes);
        else begin $display("FAIL sweep errors=%0d",errors); $fatal(1); end
        if (metrics_fd != 0) $fclose(metrics_fd);
        $finish;
    end
    initial begin repeat(4000000) @(posedge clk); $fatal(1,"GLOBAL WATCHDOG"); end
endmodule
`default_nettype wire
