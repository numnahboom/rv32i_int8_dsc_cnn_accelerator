`timescale 1ns/1ps
`default_nettype none

/*
 * Non-zero integration regression for ds_rowlocal_4lane_feed_macro.
 * The external responders use the same deterministic byte patterns as the
 * persistent-feed contract test.  Every emitted feed token is checked
 * independently, while the rowlocal output is intentionally configured with
 * multiplier zero so the output reference is unambiguous (all result bytes
 * are zero); masks and all output metadata are still checked exactly.
 */
module tb_ds_rowlocal_4lane_feed_macro;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg cfg_valid = 0; wire cfg_ready;
    reg [2:0] cfg_layer_id = 0; reg cfg_mode = 0; reg [3:0] cfg_epoch = 0, cfg_session = 0;
    wire [15:0] cfg_output_pixels, cfg_source_pixels, cfg_source_words, cfg_param_words;
    wire [7:0] cfg_cin; wire [8:0] cfg_cout;
    reg load_start_valid = 0; wire load_start_ready;
    reg [31:0] load_source_base_addr = 0, load_param_base_addr = 0;
    wire source_req_valid, source_req_ready; wire [31:0] source_req_addr;
    reg source_resp_valid = 0; wire source_resp_ready; reg [31:0] source_resp_data = 0;
    wire param_req_valid, param_req_ready; wire [31:0] param_req_addr;
    reg param_resp_valid = 0; wire param_resp_ready; reg [31:0] param_resp_data = 0;
    wire load_active, load_done;
    wire [15:0] source_external_word_count, param_external_word_count;
    wire [15:0] source_request_stall_count, param_request_stall_count;
    reg commit_valid = 0; wire commit_ready, commit_reject, committed_valid;
    wire [3:0] committed_epoch, committed_session;
    reg job_valid = 0; wire job_ready;
    reg [3:0] job_epoch = 0, job_session = 0; reg [9:0] job_pixel_base = 0;
    reg [4:0] job_cout_tile = 0; reg [7:0] job_pixel_mask = 0, job_cout_mask = 0;
    wire job_reject_stale, job_done;
    reg cfgq_valid = 0; wire cfgq_ready; reg cfgq_island = 0; reg [5:0] cfgq_lane = 0;
    reg signed [31:0] cfgq_bias = 0, cfgq_multiplier = 0; reg [5:0] cfgq_shift = 0;
    reg signed [31:0] output_zero_point = 0, activation_min = -128, activation_max = 127;
    wire out_valid; reg out_ready = 1; wire [31:0] out_word; wire [3:0] out_word_mask;
    wire [9:0] out_pixel_base; wire [8:0] out_channel_base; wire [2:0] out_group;
    wire [7:0] out_tag; wire [3:0] out_epoch, out_session; wire [1:0] out_mode; wire busy;

    ds_rowlocal_4lane_feed_macro #(.MAX_SOURCE_WORDS(4096), .MAX_PARAM_ROWS(4096)) dut (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_layer_id(cfg_layer_id), .cfg_mode(cfg_mode), .cfg_epoch(cfg_epoch), .cfg_session(cfg_session),
        .cfg_output_pixels(cfg_output_pixels), .cfg_cin(cfg_cin), .cfg_cout(cfg_cout),
        .cfg_source_pixels(cfg_source_pixels), .cfg_source_words(cfg_source_words), .cfg_param_words(cfg_param_words),
        .load_start_valid(load_start_valid), .load_start_ready(load_start_ready),
        .load_source_base_addr(load_source_base_addr), .load_param_base_addr(load_param_base_addr),
        .source_req_valid(source_req_valid), .source_req_ready(source_req_ready), .source_req_addr(source_req_addr),
        .source_resp_valid(source_resp_valid), .source_resp_ready(source_resp_ready), .source_resp_data(source_resp_data),
        .param_req_valid(param_req_valid), .param_req_ready(param_req_ready), .param_req_addr(param_req_addr),
        .param_resp_valid(param_resp_valid), .param_resp_ready(param_resp_ready), .param_resp_data(param_resp_data),
        .load_active(load_active), .load_done(load_done), .source_external_word_count(source_external_word_count),
        .param_external_word_count(param_external_word_count), .source_request_stall_count(source_request_stall_count),
        .param_request_stall_count(param_request_stall_count), .commit_valid(commit_valid), .commit_ready(commit_ready),
        .commit_reject(commit_reject), .committed_valid(committed_valid), .committed_epoch(committed_epoch),
        .committed_session(committed_session), .job_valid(job_valid), .job_ready(job_ready),
        .job_epoch(job_epoch), .job_session(job_session), .job_pixel_base(job_pixel_base),
        .job_cout_tile(job_cout_tile), .job_pixel_mask(job_pixel_mask), .job_cout_mask(job_cout_mask),
        .job_reject_stale(job_reject_stale), .job_done(job_done),
        .cfgq_valid(cfgq_valid), .cfgq_ready(cfgq_ready), .cfgq_island(cfgq_island), .cfgq_lane(cfgq_lane),
        .cfgq_bias(cfgq_bias), .cfgq_multiplier(cfgq_multiplier), .cfgq_shift(cfgq_shift),
        .output_zero_point(output_zero_point), .activation_min(activation_min), .activation_max(activation_max),
        .out_valid(out_valid), .out_ready(out_ready), .out_word(out_word), .out_word_mask(out_word_mask),
        .out_pixel_base(out_pixel_base), .out_channel_base(out_channel_base), .out_group(out_group),
        .out_tag(out_tag), .out_epoch(out_epoch), .out_session(out_session), .out_mode(out_mode), .busy(busy));

    integer cyc = 0, errors = 0, layer_now = 0, cin_now = 0, tile_now = 0;
    integer check_tokens = 0, token_seen = 0, token_expected = 0;
    integer output_seen = 0, output_target = 0, nonzero_act = 0, nonzero_wgt = 0;
    integer last_token_cycle = -1, min_token_ii = 999999, max_token_ii = 0;
    integer last_output_cycle = -1, min_output_ii = 999999, max_output_ii = 0;
    integer max_feed_occupancy = 0;
    integer p, lane, row, expb;
    reg signed [7:0] gotb;

    assign source_req_ready = ((cyc % 7) != 2);
    assign param_req_ready = ((cyc % 11) != 5);

    always @(negedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            out_ready <= ((cyc % 11) != 3) && ((cyc % 17) != 5);
            if ((cyc % 100000) == 0)
                $display("HEARTBEAT cyc=%0d lid=%0d cfg=%b load=%b done=%b job=%b tok=%b out=%b errors=%0d",
                         cyc,layer_now,cfg_valid,load_active,load_done,job_valid,
                         dut.u_feed.token_valid,out_valid,errors);
            if (cyc > 1000000) $fatal(1,"timeout cyc=%0d lid=%0d load=%b done=%b",cyc,layer_now,load_active,load_done);
        end else out_ready <= 1;
    end

    function automatic [31:0] source_pattern(input [31:0] a);
        integer wi, b;
        begin
            wi = (a - load_source_base_addr) >> 2; source_pattern = 0;
            for (b=0; b<4; b=b+1) source_pattern[(b*8)+:8] = (wi*4+b+1) & 255;
        end
    endfunction
    function automatic [31:0] param_pattern(input [31:0] a);
        integer wi, b;
        begin
            wi = (a - load_param_base_addr) >> 2; param_pattern = 0;
            for (b=0; b<4; b=b+1) param_pattern[(b*8)+:8] = (wi*4+b) & 255;
        end
    endfunction

    /* One-cycle response latency plus independent request backpressure. */
    always @(posedge clk) begin
        if (!rst_n) begin
            source_resp_valid <= 0; param_resp_valid <= 0;
        end else begin
            source_resp_valid <= source_req_valid && source_req_ready;
            param_resp_valid <= param_req_valid && param_req_ready;
            if (source_req_valid && source_req_ready) source_resp_data <= source_pattern(source_req_addr);
            if (param_req_valid && param_req_ready) param_resp_data <= param_pattern(param_req_addr);
            if (dut.u_feed.token_valid && dut.u_feed.token_ready && check_tokens) begin
                token_seen = token_seen + 1;
                if (last_token_cycle >= 0) begin
                    if ((cyc-last_token_cycle) < min_token_ii) min_token_ii = cyc-last_token_cycle;
                    if ((cyc-last_token_cycle) > max_token_ii) max_token_ii = cyc-last_token_cycle;
                end
                last_token_cycle = cyc;
                if (dut.u_feed.token_k_idx >= cin_now ||
                    dut.u_feed.token_first !== (dut.u_feed.token_k_idx == 0) ||
                    dut.u_feed.token_last !== (dut.u_feed.token_k_idx == cin_now-1) ||
                    dut.u_feed.token_pixel_base !== 0 ||
                    dut.u_feed.token_cout_base !== tile_now*8) begin
                    $display("ERROR token metadata lid=%0d k=%0d first=%b last=%b p=%0d c=%0d",
                             layer_now,dut.u_feed.token_k_idx,dut.u_feed.token_first,dut.u_feed.token_last,
                             dut.u_feed.token_pixel_base,dut.u_feed.token_cout_base); errors=errors+1;
                end
                row = tile_now*cin_now + dut.u_feed.token_k_idx;
                for (lane=0; lane<8; lane=lane+1) begin
                    p = dut.u_feed.token_pixel_base + lane;
                    expb = (p*cin_now + dut.u_feed.token_k_idx + 1) & 255;
                    gotb = dut.u_feed.token_act_vec[(lane*8)+:8];
                    if (gotb !== expb[7:0]) begin
                        if (errors < 10) $display("ERROR act lid=%0d k=%0d lane=%0d got=%0d exp=%0d",layer_now,dut.u_feed.token_k_idx,lane,gotb,expb);
                        errors=errors+1;
                    end
                    if (gotb != 0) nonzero_act = nonzero_act + 1;
                    expb = (row*8 + lane) & 255;
                    gotb = dut.u_feed.token_wgt_vec[(lane*8)+:8];
                    if (gotb !== expb[7:0]) begin
                        if (errors < 10) $display("ERROR wgt lid=%0d k=%0d lane=%0d got=%0d exp=%0d",layer_now,dut.u_feed.token_k_idx,lane,gotb,expb);
                        errors=errors+1;
                    end
                    if (gotb != 0) nonzero_wgt = nonzero_wgt + 1;
                end
            end
            if (out_valid && out_ready) begin
                if (last_output_cycle >= 0) begin
                    if ((cyc-last_output_cycle) < min_output_ii) min_output_ii = cyc-last_output_cycle;
                    if ((cyc-last_output_cycle) > max_output_ii) max_output_ii = cyc-last_output_cycle;
                end
                last_output_cycle = cyc;
                if (output_seen >= output_target || out_word !== 0 || out_word_mask !== 4'hf ||
                    out_pixel_base !== (output_seen % 8) || out_channel_base !== tile_now*8 + ((output_seen/8)*4) ||
                    out_group !== (output_seen % 8) || out_tag !== tile_now[7:0] ||
                    out_epoch !== cfg_epoch || out_session !== cfg_session || out_mode !== 0) begin
                    if (errors < 12) $display("ERROR output n=%0d lid=%0d word=%h mask=%h p=%0d c=%0d g=%0d tag=%0d",
                        output_seen,layer_now,out_word,out_word_mask,out_pixel_base,out_channel_base,out_group,out_tag);
                    errors=errors+1;
                end
                output_seen = output_seen + 1;
            end
            if (dut.u_compute.row_occupancy > max_feed_occupancy)
                max_feed_occupancy = dut.u_compute.row_occupancy;
        end
    end

    task automatic configure_compute;
        integer ii, ll;
        begin
            for (ii=0; ii<2; ii=ii+1) for (ll=0; ll<32; ll=ll+1) begin
                @(negedge clk); cfgq_island=ii; cfgq_lane=ll; cfgq_valid=1;
                cfgq_bias=0; cfgq_multiplier=0; cfgq_shift=0;
                while (1) begin @(posedge clk); #1; if (cfgq_ready) break; end
            end
            @(negedge clk); cfgq_valid=0;
        end
    endtask

    task automatic configure_load;
        input integer lid, ep, ss;
        integer sw, pw;
        begin
            layer_now=lid; cfg_layer_id=lid; cfg_mode=0; cfg_epoch=ep; cfg_session=ss;
            @(negedge clk);
            while (!cfg_ready) @(posedge clk);
            cfg_valid=1;
            @(posedge clk); @(negedge clk); cfg_valid=0;
            sw = (cfg_output_pixels * cfg_cin) / 4; pw = (cfg_cin * cfg_cout) / 4;
            if (cfg_source_words !== sw || cfg_param_words !== pw) begin
                $display("ERROR shape lid=%0d source=%0d/%0d param=%0d/%0d",lid,cfg_source_words,sw,cfg_param_words,pw); errors=errors+1;
            end
            load_source_base_addr=32'h00100000 + lid*32'h00100000;
            load_param_base_addr=32'h10100000 + lid*32'h00100000;
            @(negedge clk); load_start_valid=1;
            while (!load_start_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); load_start_valid=0;
            while (!load_done) @(posedge clk);
            @(negedge clk); commit_valid=1;
            while (!committed_valid) @(posedge clk);
            @(negedge clk); commit_valid=0;
            if (source_request_stall_count == 0 || param_request_stall_count == 0) begin
                $display("ERROR no load backpressure lid=%0d stalls=%0d/%0d",lid,source_request_stall_count,param_request_stall_count); errors=errors+1;
            end
        end
    endtask

    task automatic run_job;
        input integer lid, ep, ss;
        begin
            layer_now=lid; tile_now=0; cin_now=cfg_cin; token_seen=0; check_tokens=0;
            output_seen=0; output_target=16; last_token_cycle=-1; min_token_ii=999999; max_token_ii=0;
            last_output_cycle=-1; min_output_ii=999999; max_output_ii=0;
            @(negedge clk); job_epoch=ep; job_session=ss; job_pixel_base=0; job_cout_tile=0;
            job_pixel_mask=8'hff; job_cout_mask=8'hff; job_valid=1;
            while (!job_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); job_valid=0; check_tokens=1;
            while (!job_done) @(posedge clk);
            while (output_seen < output_target) @(posedge clk);
            check_tokens=0;
            if (token_seen !== cin_now) begin
                $display("ERROR token count lid=%0d got=%0d exp=%0d",lid,token_seen,cin_now); errors=errors+1;
            end
            if (nonzero_act == 0 || nonzero_wgt == 0) begin
                $display("ERROR zero feed data lid=%0d nonzero=%0d/%0d",lid,nonzero_act,nonzero_wgt); errors=errors+1;
            end
            $display("LEDGER DS%0d rowlocal tokens=%0d outputs=%0d token_ii=%0d..%0d out_ii=%0d..%0d row_occ_max=%0d nonzero_act/wgt=%0d/%0d",
                     lid,token_seen,output_seen,min_token_ii,max_token_ii,min_output_ii,max_output_ii,
                     max_feed_occupancy,nonzero_act,nonzero_wgt);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n=1;
        configure_compute();
        configure_load(1,1,2); run_job(1,1,2);
        configure_load(3,2,3); run_job(3,2,3);
        configure_load(6,3,4); run_job(6,3,4);
        if (source_request_stall_count == 0 || param_request_stall_count == 0) errors=errors+1;
        if (errors == 0)
            $display("PASS ds_rowlocal_4lane_feed_macro DS1/DS3/DS6 total_outputs=48 max_row_occupancy=%0d load_stalls=%0d/%0d",
                     max_feed_occupancy,source_request_stall_count,param_request_stall_count);
        else $display("FAIL ds_rowlocal_4lane_feed_macro errors=%0d",errors);
        if (errors != 0) $fatal(1,"feed macro regression failed");
        $finish;
    end
endmodule
`default_nettype wire
