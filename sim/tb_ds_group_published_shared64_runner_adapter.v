`timescale 1ns/1ps
`default_nettype none

/* End-to-end real-producer ledger for all six C10 DS shapes.  The bridge is
 * driven through the scalar runner configuration ABI; source words come from
 * a delayed response queue (with deterministic pseudo-random latency), and
 * output writes see repeatable bubbles.  This is a protocol/traffic ledger,
 * not a claim of exact logits: output data is deliberately audited only for
 * valid byte lanes while independent shape/count/address checks cover the
 * transaction boundary. */
module tb_ds_group_published_shared64_runner_adapter #(
    parameter integer TB_RANDOM_BP = 1
);
    localparam integer MAX_CIN=128, MAX_COUT=256;
    localparam integer RANDOM_BP=TB_RANDOM_BP;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0;
    reg start_valid=0;
    wire start_ready;
    reg [31:0] input_base=32'h02000, output_base=32'h00000;
    reg [15:0] in_h=32, in_w=32, in_c=16, out_c=32;
    reg [7:0] stride=1, input_zp=3;
    reg signed [31:0] dw_zp=0, dw_min=-128, dw_max=127;
    reg signed [31:0] pw_zp=0, pw_min=-128, pw_max=127;
    reg cfg_valid=0; reg [3:0] cfg_target=0; reg [15:0] cfg_index=0;
    reg [31:0] cfg_data=0;
    wire [6:0] cfg_dw_channel = cfg_index / 9;
    wire [3:0] cfg_dw_tap = cfg_index % 9;
    wire source_word_en; wire [14:0] source_word_addr;
    reg source_word_ready=1;
    reg source_word_valid=0; reg [31:0] source_word_data=32'h01010101;
    wire output_word_en; wire [15:0] output_word_addr; wire [31:0] output_word_data;
    wire [3:0] output_word_be; wire busy,done,error;
    reg output_word_ready=1;
    wire [31:0] perf_cycles,perf_dw,perf_desc,perf_tokens,perf_out,perf_jobs,perf_beats;
    wire [31:0] cfg_accept_count, cfg_phase_count;

    ds_group_published_shared64_runner_adapter dut (
        .clk(clk),.rst_n(rst_n),.start_valid(start_valid),.start_ready(start_ready),
        .input_base_addr(input_base),.output_base_addr(output_base),
        .input_height(in_h),.input_width(in_w),.input_channels(in_c),.output_channels(out_c),
        .stride(stride),.input_zero_point(input_zp),.dw_output_zero_point(dw_zp),
        .dw_activation_min(dw_min),.dw_activation_max(dw_max),.pw_output_zero_point(pw_zp),
        .pw_activation_min(pw_min),.pw_activation_max(pw_max),.config_write_en(cfg_valid),
        .config_target(cfg_target),.config_index(cfg_index),.config_data(cfg_data),
        .config_dw_channel(cfg_dw_channel),.config_dw_tap(cfg_dw_tap),
        .config_word_write_en(1'b0),.config_word_target(4'd0),
        .config_word_index(16'd0),.config_word_data(32'd0),.config_word_be(4'd0),
        .source_word_en(source_word_en),.source_word_addr(source_word_addr),
        .source_word_ready(source_word_ready),.source_word_valid(source_word_valid),.source_word_data(source_word_data),
        .output_word_en(output_word_en),.output_word_addr(output_word_addr),
        .output_word_data(output_word_data),.output_word_be(output_word_be),.busy(busy),
        .output_word_ready(output_word_ready),.done(done),.error(error),
        .perf_cycles(perf_cycles),.perf_dw_writes(perf_dw),.perf_descriptors(perf_desc),
        .perf_pw_tokens(perf_tokens),.perf_output_writes(perf_out),.perf_jobs(perf_jobs),
        .perf_stream_beats(perf_beats),.config_accept_count(cfg_accept_count),
        .config_phase_count(cfg_phase_count),.config_word_accept_count(),
        .config_scalar_write_count());

    /* A synchronous SRAM response is returned one cycle after each accepted
     * request.  Request acceptance is pseudo-randomly bubbled below and the
     * returned word is pseudo-random, so the producer is not accidentally
     * proven only with a constant-zero data path; the real response
     * ordering/FIFO and halo behavior are still exercised. */
    reg pending_valid=0; reg [31:0] pending_data=0; integer lfsr=7;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending_valid <= 1'b0; pending_data <= 0;
            source_word_valid <= 1'b0; source_word_data <= 0; lfsr <= 7;
        end else begin
            source_word_valid <= pending_valid;
            source_word_data <= pending_data;
            pending_valid <= source_word_en && source_word_ready;
            pending_data <= {4{lfsr[7:0]}};
            lfsr <= ((lfsr * 5) + 1) % 251;
        end
    end
    integer errors=0, source_checks=0, output_checks=0, output_edge_checks=0, output_stalls=0;
    integer param_load_total=0, weight_load_total=0, dw_service_cycles=0;
    integer active_pixels=0, active_cin=0, active_cout=0, active_outh=0, active_outw=0;
    integer active_stride=1, active_shape=0, progress_idle=0, previous_state=0;
    integer cfg_tap, cfg_ch, cfg_o, cfg_k;
    integer cfg_expected;
    integer pw_cfg_value;
    integer weight_lane;
    integer active_cout_tiles;
    integer expected_param_loads, expected_weight_loads;
    integer last_param_slot, last_weight_slot;
    /* Simulation-only cycle taxonomy.  These counters are deliberately
     * outside the adapter ABI: they classify the same start->done window
     * without changing functional traffic or performance accounting. */
    integer class_source_fill=0, class_dw_fetch_cfg=0, class_producer_wait_sweep=0;
    integer class_sweep_publication=0, class_core_tokens=0, class_result_drain=0;
    integer class_source_stall=0, class_output_stall=0;
    integer class_sweep_wait_publication=0, class_sweep_wait_core=0;
    integer class_dw_prefetch_reads=0;
    integer bp_lfsr=32'h1a2b3c4d;

    function integer dw_weight_value;
        input integer ch; input integer tap;
        begin dw_weight_value = (ch % 7) + tap + 1; end
    endfunction
    function integer dw_bias_value;
        input integer ch;
        begin dw_bias_value = (ch % 5) - 2; end
    endfunction
    function integer pw_weight_value;
        input integer ch; input integer k;
        begin pw_weight_value = ((ch * 3 + k * 5 + 1) % 101) - 50; end
    endfunction

    /* Independent address/byte-enable and configuration-load audit. */
    always @(posedge clk) begin
        if (rst_n) begin
            if (source_word_en && source_word_ready) begin
                source_checks=source_checks+1;
                if (dut.u_source_adapter.mem_req_addr[1:0] != 0 ||
                    dut.u_source_adapter.mem_req_addr < input_base ||
                    dut.u_source_adapter.mem_req_addr >=
                      (input_base + in_h*in_w*active_cin)) begin
                    $display("BAD_SOURCE_ADDR shape=%0d addr=%h base=%h",active_shape,
                             dut.u_source_adapter.mem_req_addr,input_base);
                    errors=errors+1;
                end
            end
            if (output_word_en && output_word_ready) begin
                output_checks=output_checks+1;
                if (dut.sweep_result_pixel >= active_pixels ||
                    dut.sweep_result_channel >= active_cout) begin
                    $display("BAD_RESULT_SLOT shape=%0d pixel=%0d channel=%0d",
                             active_shape,dut.sweep_result_pixel,dut.sweep_result_channel);
                    errors=errors+1;
                end
                if (output_word_addr[1:0] != 0 || output_word_be !== 4'hf ||
                    output_word_addr >= (output_base + active_pixels*active_cout)) begin
                    $display("BAD_OUTPUT shape=%0d addr=%0d be=%h",active_shape,
                             output_word_addr,output_word_be);
                    errors=errors+1;
                end
            end
            if (output_word_en && !output_word_ready)
                output_stalls=output_stalls+1;
            if (dut.state == 4'd9)
                dw_service_cycles=dw_service_cycles+1;
            if (dut.u_producer.u_4x8.u_producer.u_window_shell.fill_engine_busy)
                class_source_fill=class_source_fill+1;
            if ((dut.state == 4'd2) || (dut.state == 4'd3) ||
                (dut.state == 4'd4))
                class_dw_fetch_cfg=class_dw_fetch_cfg+1;
            if (dut.cfg_prefetch_active_q && dut.cfg_prefetch_read_valid_q)
                class_dw_prefetch_reads=class_dw_prefetch_reads+1;
            if (dut.state == 4'd9 && dut.producer_stream_valid &&
                !dut.producer_stream_ready)
                class_producer_wait_sweep=class_producer_wait_sweep+1;
            if (dut.sweep_dw_valid && dut.sweep_dw_ready)
                class_sweep_publication=class_sweep_publication+1;
            if (dut.u_sweep.pw_token_fire)
                class_core_tokens=class_core_tokens+1;
            if (dut.u_sweep.state == 2'd1 && !dut.u_sweep.schedule_done_q &&
                !dut.u_sweep.pw_published)
                class_sweep_wait_publication=class_sweep_wait_publication+1;
            if (dut.u_sweep.state == 2'd1 && !dut.u_sweep.schedule_done_q &&
                dut.u_sweep.pw_published && !dut.u_sweep.pw_token_valid)
                class_sweep_wait_core=class_sweep_wait_core+1;
            if (dut.sweep_result_valid)
                class_result_drain=class_result_drain+1;
            if (source_word_en && !source_word_ready)
                class_source_stall=class_source_stall+1;
            if (output_word_en && !output_word_ready)
                class_output_stall=class_output_stall+1;

            /* A published token and the look-ahead BRAM address must both
             * remain inside the active shape.  This proves that reducing the
             * preload does not merely leave stale inactive rows available to
             * the schedule. */
            if (dut.u_sweep.state == 2'd1 && dut.u_sweep.pw_published) begin
                if (dut.u_sweep.pw_tile_q >= active_cout_tiles ||
                    ((dut.u_sweep.pw_group_q * 8) + dut.u_sweep.pw_k_q) >= active_cin) begin
                    $display("BAD_ACTIVE_TOKEN shape=%0d tile=%0d group=%0d k=%0d",
                             active_shape,dut.u_sweep.pw_tile_q,dut.u_sweep.pw_group_q,
                             dut.u_sweep.pw_k_q);
                    errors=errors+1;
                end
            end
            if (dut.u_sweep.state == 2'd1 &&
                (dut.u_sweep.rd_issue_tile >= active_cout_tiles ||
                 ((dut.u_sweep.rd_issue_group * 8) + dut.u_sweep.rd_issue_k) >= active_cin)) begin
                $display("BAD_ACTIVE_READ shape=%0d tile=%0d group=%0d k=%0d",
                         active_shape,dut.u_sweep.rd_issue_tile,dut.u_sweep.rd_issue_group,
                         dut.u_sweep.rd_issue_k);
                errors=errors+1;
            end

            /* Check the bridge's DW repack against the channel-major runner
             * ABI while each per-group configuration row is presented. */
            if (dut.state == 4'd4 && dut.producer_job_ready) begin
                cfg_expected=dw_weight_value((dut.channel_group_q*16),dut.cfg_tap_q);
                if ($signed(dut.producer_cfg_weight[7:0]) !== cfg_expected) begin
                    $display("BAD_DW_REPACK shape=%0d group=%0d tap=%0d got=%0d exp=%0d",
                             active_shape,dut.channel_group_q,dut.cfg_tap_q,
                             $signed(dut.producer_cfg_weight[7:0]),cfg_expected);
                    errors=errors+1;
                end
            end
        end
    end
    /* The bridge result is a registered interface.  Sample the visible
     * handshake on the opposite edge so the checker observes the value held
     * for the complete cycle (the perf counter remains an independent fence). */
    always @(negedge clk) begin
        /* One-cycle BRAM response audit.  The request address itself is the
         * physical tile/Cin row; every returned byte must match the scalar
         * ABI lane mapping, and parameter tags must remain on the requested
         * Cout tile. */
        if (rst_n && dut.pw_weight_resp_valid) begin
            for (weight_lane=0; weight_lane<8; weight_lane=weight_lane+1) begin
                pw_cfg_value=pw_weight_value((dut.pw_weight_resp_addr[11:7]*8)+weight_lane,
                                             dut.pw_weight_resp_addr[6:0]);
                if ($signed(dut.pw_weight_resp_data[weight_lane*8 +: 8]) !== pw_cfg_value) begin
                    $display("BAD_PW_READ row=%0d lane=%0d got=%0d exp=%0d",
                             dut.pw_weight_resp_addr[11:0],weight_lane,
                             $signed(dut.pw_weight_resp_data[weight_lane*8 +: 8]),pw_cfg_value);
                    errors=errors+1;
                end
            end
        end
        if (rst_n && dut.pw_param_resp_valid) begin
            if ($signed(dut.pw_param_resp_data[31:0]) !== ((dut.pw_param_resp_addr%5)-2) ||
                dut.pw_param_resp_data[63:32] !== 32'h7fff_ffff ||
                dut.pw_param_resp_data[64 +: 6] !== 0) begin
                $display("BAD_PW_PARAM_READ addr=%0d",dut.pw_param_resp_addr);
                errors=errors+1;
            end
        end
        if (rst_n && output_word_en) begin
            if (output_word_ready) begin
                output_edge_checks=output_edge_checks+1;
                if (output_word_addr[1:0] != 0 || output_word_be !== 4'hf ||
                    output_word_addr >= (output_base + active_pixels*active_cout)) begin
                    $display("BAD_OUTPUT_EDGE shape=%0d addr=%0d be=%h",active_shape,
                             output_word_addr,output_word_be);
                    errors=errors+1;
                end
            end else output_stalls=output_stalls+1;
        end
    end

    task cfg;
        input [3:0] t; input [15:0] i; input [31:0] d;
        begin @(negedge clk); cfg_target=t; cfg_index=i; cfg_data=d; cfg_valid=1;
              @(posedge clk); @(negedge clk); cfg_valid=0; end
    endtask

    task run_shape;
        input integer sid, ih, iw, pixels, cin, cout, st;
        integer expect_dw, expect_desc, expect_tokens, expect_out, expect_jobs;
            integer out_start, src_start, param_start, weight_start, stall_start, dw_start, wait_cycles;
            integer class_fill_start, class_cfg_start, class_wait_start;
            integer class_pub_start, class_token_start, class_drain_start;
            integer class_src_stall_start, class_out_stall_start;
            integer class_pub_wait_start, class_core_wait_start;
            integer class_dw_prefetch_start;
        integer tile_cols, macro_count, group_count;
        begin
            in_h=ih; in_w=iw; in_c=cin; out_c=cout; stride=st;
            active_shape=sid; active_pixels=pixels; active_cin=cin; active_cout=cout;
            active_stride=st; active_outh=(st==2)?((ih+1)/2):ih;
            active_outw=(st==2)?((iw+1)/2):iw;
            out_start=output_edge_checks; src_start=source_checks;
            param_start=param_load_total; weight_start=weight_load_total;
            stall_start=output_stalls;
            dw_start=dw_service_cycles;
            class_fill_start=class_source_fill;
            class_cfg_start=class_dw_fetch_cfg;
            class_wait_start=class_producer_wait_sweep;
            class_pub_start=class_sweep_publication;
            class_token_start=class_core_tokens;
            class_drain_start=class_result_drain;
            class_src_stall_start=class_source_stall;
            class_out_stall_start=class_output_stall;
            class_pub_wait_start=class_sweep_wait_publication;
            class_core_wait_start=class_sweep_wait_core;
            class_dw_prefetch_start=class_dw_prefetch_reads;
            tile_cols=(active_outw+7)/8; macro_count=((active_outh+3)/4)*tile_cols;
            group_count=(cin+15)/16;
            active_cout_tiles=(cout+7)/8;
            expected_param_loads=cout;
            expected_weight_loads=active_cout_tiles*cin;
            /* The reused 4x8 producer always emits one complete 32-pixel
             * macro, including masked tail pixels.  For DS6 P=16 this is
             * deliberately 2x semantic traffic; retain the physical beat
             * ledger instead of silently crediting only useful bytes. */
            expect_dw=macro_count*32*cin/4;
            expect_desc=macro_count*4*(cin/8);
            /* perf_pw_tokens counts accepted physical 64-product tokens.  A
             * fixed 4x8 producer macro still traverses all four row slots
             * when the final spatial tile is narrow; masked DS6 pixels are
             * therefore present in the physical ledger. */
            expect_tokens=macro_count*4*cin*active_cout_tiles;
            expect_out=pixels*cout/4;
            expect_jobs=macro_count*group_count;
            $display("BEGIN_SHAPE id=%0d HxW=%0dx%0d P=%0d Cin=%0d Cout=%0d stride=%0d",
                     sid,ih,iw,pixels,cin,cout,st);
            @(posedge clk); @(negedge clk); start_valid=1;
            begin : accept_start
                while (1) begin @(posedge clk); if (start_ready) begin
                    @(negedge clk); start_valid=0; disable accept_start;
                end end
            end
            wait_cycles=0; progress_idle=0; previous_state=dut.state;
            while (!done) begin
                @(posedge clk); wait_cycles=wait_cycles+1;
                /* A live transaction must advance through one of its
                 * handshake/state edges.  This catches a FIFO/order deadlock
                 * independently of the final watchdog. */
                if ((dut.state != previous_state) ||
                    (dut.state==4'd4 && dut.producer_job_ready) ||
                    (dut.state==4'd5 && dut.source_context_ready) ||
                    (dut.state==4'd6 && dut.fill_start_ready) ||
                    (dut.state==4'd7 && dut.fill_done_valid) ||
                    (dut.state==4'd8 && dut.producer_job_ready) ||
                    (dut.state==4'd9 && dut.producer_stream_valid && dut.producer_stream_ready) ||
                    (output_word_en && output_word_ready)) progress_idle=0;
                else progress_idle=progress_idle+1;
                previous_state=dut.state;
                if (progress_idle > 10000)
                    begin
                        $display("FORWARD_DIAG src_en=%b src_valid=%b req=%0d state=%0d done=%b",source_word_en,source_word_valid,dut.producer_reads,dut.u_sweep.state,dut.u_sweep.done);
                        $fatal(1,"FORWARD_PROGRESS shape=%0d state=%0d cycles=%0d",sid,dut.state,perf_cycles);
                    end
                if (wait_cycles > 1200000)
                    $fatal(1,"SHAPE_WATCHDOG shape=%0d state=%0d cycles=%0d",sid,dut.state,perf_cycles);
            end
            if (error) begin $display("SHAPE_ERROR id=%0d",sid); errors=errors+1; end
            if (perf_out !== expect_out)
                begin $display("BAD_OUT_COUNT id=%0d got=%0d perf=%0d exp=%0d",sid,
                               output_edge_checks-out_start,perf_out,expect_out); errors=errors+1; end
            if (perf_dw !== expect_dw || perf_beats !== expect_dw)
                begin $display("BAD_DW_COUNT id=%0d dw=%0d beats=%0d exp=%0d",sid,perf_dw,perf_beats,expect_dw); errors=errors+1; end
            if (perf_desc !== expect_desc || perf_tokens !== expect_tokens || perf_jobs !== expect_jobs)
                begin $display("BAD_LEDGER id=%0d desc=%0d/%0d tokens=%0d/%0d jobs=%0d/%0d",sid,
                               perf_desc,expect_desc,perf_tokens,expect_tokens,perf_jobs,expect_jobs); errors=errors+1; end
            if ((param_load_total-param_start) !== 0 ||
                (weight_load_total-weight_start) !== 0)
                begin $display("BAD_PRELOAD id=%0d params=%0d weights=%0d",sid,
                               param_load_total-param_start,weight_load_total-weight_start); errors=errors+1; end
            if (source_checks-src_start == 0)
                begin $display("BAD_SOURCE_PROGRESS id=%0d source=%0d",sid,
                               source_checks-src_start); errors=errors+1; end
            if (dut.pw_param_mem[0][cout-1][63:32] !== 32'h7fff_ffff ||
                dut.pw_param_mem[0][cout-1][64 +: 6] !== 0)
                begin $display("BAD_PARAM_LOAD id=%0d last_cout=%0d",sid,cout); errors=errors+1; end
            $display("SHAPE id=%0d perf_cycles=%0d dw_service_cycles=%0d dw_beats=%0d jobs=%0d desc=%0d pw_tokens=%0d output_words=%0d source_words=%0d output_stalls=%0d param_loads=%0d weight_loads=%0d active_tiles=%0d",
                     sid,perf_cycles,dw_service_cycles-dw_start,perf_dw,perf_jobs,perf_desc,perf_tokens,perf_out,
                     source_checks-src_start,output_stalls-stall_start,
                     param_load_total-param_start,weight_load_total-weight_start,active_cout_tiles);
            $display("CLASS id=%0d source_fill=%0d dw_fetch_cfg=%0d dw_prefetch_reads=%0d producer_wait_sweep=%0d sweep_wait_publication=%0d sweep_wait_core=%0d sweep_publication=%0d core_tokens=%0d result_drain=%0d source_stall=%0d output_stall=%0d",
                     sid,class_source_fill-class_fill_start,class_dw_fetch_cfg-class_cfg_start,
                     class_dw_prefetch_reads-class_dw_prefetch_start,
                     class_producer_wait_sweep-class_wait_start,
                     class_sweep_wait_publication-class_pub_wait_start,
                     class_sweep_wait_core-class_core_wait_start,
                     class_sweep_publication-class_pub_start,class_core_tokens-class_token_start,
                      class_result_drain-class_drain_start,class_source_stall-class_src_stall_start,
                      class_output_stall-class_out_stall_start);
            @(posedge clk); /* consume one-cycle done fence before next start */
        end
    endtask

    /* Output ready bubbles are enabled for every shape, not only a directed
     * unit test, so at least one real producer layer sees sink backpressure. */
    integer sink_cycle;
    integer source_cycle;
    always @(negedge clk) begin
        if (!rst_n) begin
            sink_cycle=0; source_cycle=0; output_word_ready <= 1'b1; source_word_ready <= 1'b1;
            bp_lfsr <= 32'h1a2b3c4d;
        end
        else begin
            sink_cycle=sink_cycle+1;
            /* Reproducible independent pseudo-random backpressure on both
             * external interfaces.  The low-density masks keep the run
             * practical while exercising held request/result contracts. */
            output_word_ready <= !RANDOM_BP || !((bp_lfsr[3:0] == 4'h3) ||
                                                 (bp_lfsr[8:5] == 4'h9));
            source_cycle=source_cycle+1;
            source_word_ready <= !RANDOM_BP || !((bp_lfsr[13:10] == 4'h5) ||
                                                 (bp_lfsr[18:15] == 4'ha));
            bp_lfsr <= {bp_lfsr[30:0],bp_lfsr[31]^bp_lfsr[21]^bp_lfsr[1]^bp_lfsr[0]};
        end
    end

    initial begin
        repeat(5) @(posedge clk); rst_n=1;
        /* DW parameter ABI: channel-major, nine taps per channel. */
        for (cfg_ch=0; cfg_ch<MAX_CIN; cfg_ch=cfg_ch+1)
            for (cfg_tap=0; cfg_tap<9; cfg_tap=cfg_tap+1)
                cfg(1,cfg_ch*9+cfg_tap,dw_weight_value(cfg_ch,cfg_tap));
        for (cfg_ch=0; cfg_ch<MAX_CIN; cfg_ch=cfg_ch+1) begin
            cfg(2,cfg_ch,dw_bias_value(cfg_ch));
            cfg(3,cfg_ch,32'h7fff_ffff);
            cfg(4,cfg_ch,0);
        end
        /* MAX_CIN-strided PW ABI.  Values are intentionally non-uniform so
         * the active physical row/tile address audit cannot pass on zeros or
         * all-ones data; inactive slots are configured but never preloaded. */
        for (cfg_o=0; cfg_o<MAX_COUT; cfg_o=cfg_o+1)
            for (cfg_k=0; cfg_k<MAX_CIN; cfg_k=cfg_k+1)
                cfg(5,cfg_o*MAX_CIN+cfg_k,pw_weight_value(cfg_o,cfg_k));
        for (cfg_o=0; cfg_o<MAX_COUT; cfg_o=cfg_o+1) begin
            cfg(6,cfg_o,(cfg_o%5)-2);
            cfg(7,cfg_o,32'h7fff_ffff);
            cfg(8,cfg_o,0);
        end
        if (cfg_accept_count !== (MAX_CIN*9 + MAX_CIN*3 + MAX_COUT*MAX_CIN + MAX_COUT*3)) begin
            $display("BAD_CONFIG_COUNT got=%0d exp=%0d phase=%0d",cfg_accept_count,
                     (MAX_CIN*9 + MAX_CIN*3 + MAX_COUT*MAX_CIN + MAX_COUT*3),cfg_phase_count);
            errors=errors+1;
        end
        /* Physical storage audit: scalar ABI writes must land in the packed
         * row/byte-enable layout, before any layer is allowed to start. */
        for (cfg_ch=0; cfg_ch<MAX_CIN; cfg_ch=cfg_ch+1) begin
            for (cfg_tap=0; cfg_tap<9; cfg_tap=cfg_tap+1)
                if ($signed(dut.dw_weight_mem[0][cfg_ch][cfg_tap*8 +: 8]) !==
                    dw_weight_value(cfg_ch,cfg_tap)) begin
                    $display("BAD_DW_RAM ch=%0d tap=%0d",cfg_ch,cfg_tap); errors=errors+1;
                end
            if ($signed(dut.dw_param_mem[0][cfg_ch][31:0]) !== dw_bias_value(cfg_ch) ||
                dut.dw_param_mem[0][cfg_ch][63:32] !== 32'h7fff_ffff ||
                dut.dw_param_mem[0][cfg_ch][64 +: 6] !== 0) begin
                $display("BAD_DW_PARAM_RAM ch=%0d",cfg_ch); errors=errors+1;
            end
        end
        for (cfg_o=0; cfg_o<MAX_COUT; cfg_o=cfg_o+1) begin
            if ($signed(dut.pw_param_mem[0][cfg_o][31:0]) !== ((cfg_o%5)-2) ||
                dut.pw_param_mem[0][cfg_o][63:32] !== 32'h7fff_ffff ||
                dut.pw_param_mem[0][cfg_o][64 +: 6] !== 0) begin
                $display("BAD_PW_PARAM_RAM cout=%0d",cfg_o); errors=errors+1;
            end
            for (cfg_k=0; cfg_k<MAX_CIN; cfg_k=cfg_k+1) begin
                if ($signed(dut.pw_weight_mem[0][(cfg_o/8)*MAX_CIN+cfg_k][(cfg_o%8)*8 +: 8]) !==
                    pw_weight_value(cfg_o,cfg_k)) begin
                    $display("BAD_PW_RAM cout=%0d cin=%0d",cfg_o,cfg_k); errors=errors+1;
                end
            end
        end

        run_shape(1,32,32,1024,16,32,1);
        run_shape(2,32,32,256,32,64,2);
        run_shape(3,16,16,256,64,64,1);
        run_shape(4,16,16,64,64,128,2);
        run_shape(5,8,8,64,128,128,1);
        run_shape(6,8,8,16,128,256,2);
        if (errors==0)
            $display("PASS six-shape real-producer ledger source_words=%0d output_words=%0d",source_checks,output_checks);
        else begin $display("FAIL six-shape ledger errors=%0d",errors); $fatal(1); end
        $finish;
    end
    initial begin repeat(12000000) @(posedge clk); $fatal(1,"GLOBAL WATCHDOG"); end
endmodule
`default_nettype wire
