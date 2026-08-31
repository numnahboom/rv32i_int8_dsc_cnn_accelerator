`timescale 1ns/1ps
`default_nettype none

/*
 * Protocol/reference test for ds_persistent_feed_contract.
 * The source and parameter responders intentionally insert independent
 * request backpressure and one-cycle response latency.  Three real C10 PW
 * shapes are loaded, then multiple spatial/cout jobs consume the same local
 * source window to make reuse observable in the counters.
 */
module tb_ds_persistent_feed_contract;
    reg clk = 0;
    reg rst_n = 0;
    reg cfg_valid = 0;
    wire cfg_ready;
    reg [2:0] cfg_layer_id;
    reg cfg_mode;
    reg [3:0] cfg_epoch, cfg_session;
    wire [15:0] cfg_output_pixels, cfg_source_pixels, cfg_source_words, cfg_param_words;
    wire [7:0] cfg_cin;
    wire [8:0] cfg_cout;
    reg load_start_valid = 0;
    wire load_start_ready;
    reg [31:0] load_source_base_addr, load_param_base_addr;
    wire source_req_valid, source_req_ready;
    wire [31:0] source_req_addr;
    reg source_resp_valid = 0;
    wire source_resp_ready;
    reg [31:0] source_resp_data = 0;
    wire param_req_valid, param_req_ready;
    wire [31:0] param_req_addr;
    reg param_resp_valid = 0;
    wire param_resp_ready;
    reg [31:0] param_resp_data = 0;
    wire load_active, load_done;
    wire [15:0] source_external_word_count, param_external_word_count;
    wire [15:0] source_request_stall_count, param_request_stall_count;
    reg commit_valid = 0;
    wire commit_ready;
    wire commit_reject, committed_valid;
    wire [3:0] committed_epoch, committed_session;
    reg job_valid = 0;
    wire job_ready;
    reg [3:0] job_epoch, job_session;
    reg [9:0] job_pixel_base;
    reg [4:0] job_cout_tile;
    reg [7:0] job_pixel_mask, job_cout_mask;
    wire job_reject_stale;
    wire token_valid;
    reg token_ready = 1;
    wire token_first, token_last;
    wire [7:0] token_k_idx;
    wire [9:0] token_pixel_base;
    wire [8:0] token_cout_base;
    wire [7:0] token_pixel_mask, token_cout_mask;
    wire signed [63:0] token_act_vec, token_wgt_vec;
    wire job_done, busy;
    wire [15:0] local_source_word_read_count;
    wire [31:0] local_param_row_read_count, token_count;
    wire [15:0] window_reuse_count;

    ds_persistent_feed_contract #(.MAX_SOURCE_WORDS(4096), .MAX_PARAM_ROWS(4096)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_layer_id(cfg_layer_id),
        .cfg_mode(cfg_mode), .cfg_epoch(cfg_epoch), .cfg_session(cfg_session),
        .cfg_output_pixels(cfg_output_pixels), .cfg_cin(cfg_cin), .cfg_cout(cfg_cout),
        .cfg_source_pixels(cfg_source_pixels), .cfg_source_words(cfg_source_words),
        .cfg_param_words(cfg_param_words), .load_start_valid(load_start_valid),
        .load_start_ready(load_start_ready), .load_source_base_addr(load_source_base_addr),
        .load_param_base_addr(load_param_base_addr), .source_req_valid(source_req_valid),
        .source_req_ready(source_req_ready), .source_req_addr(source_req_addr),
        .source_resp_valid(source_resp_valid), .source_resp_ready(source_resp_ready),
        .source_resp_data(source_resp_data), .param_req_valid(param_req_valid),
        .param_req_ready(param_req_ready), .param_req_addr(param_req_addr),
        .param_resp_valid(param_resp_valid), .param_resp_ready(param_resp_ready),
        .param_resp_data(param_resp_data), .load_active(load_active), .load_done(load_done),
        .source_external_word_count(source_external_word_count),
        .param_external_word_count(param_external_word_count),
        .source_request_stall_count(source_request_stall_count),
        .param_request_stall_count(param_request_stall_count), .commit_valid(commit_valid),
        .commit_ready(commit_ready), .commit_reject(commit_reject),
        .committed_valid(committed_valid), .committed_epoch(committed_epoch),
        .committed_session(committed_session), .job_valid(job_valid), .job_ready(job_ready),
        .job_epoch(job_epoch), .job_session(job_session), .job_pixel_base(job_pixel_base),
        .job_cout_tile(job_cout_tile), .job_pixel_mask(job_pixel_mask),
        .job_cout_mask(job_cout_mask), .job_reject_stale(job_reject_stale),
        .token_valid(token_valid), .token_ready(token_ready), .token_first(token_first),
        .token_last(token_last), .token_k_idx(token_k_idx),
        .token_pixel_base(token_pixel_base), .token_cout_base(token_cout_base),
        .token_pixel_mask(token_pixel_mask), .token_cout_mask(token_cout_mask),
        .token_act_vec(token_act_vec), .token_wgt_vec(token_wgt_vec), .job_done(job_done),
        .busy(busy), .local_source_word_read_count(local_source_word_read_count),
        .local_param_row_read_count(local_param_row_read_count), .token_count(token_count),
        .window_reuse_count(window_reuse_count)
    );

    always #5 clk = ~clk;
    integer cyc = 0;
    integer errors = 0;
    integer check_enabled = 0;
    integer exp_cin, exp_cout, exp_pbase, exp_tile;
    reg [7:0] exp_pmask, exp_cmask;
    integer use_tail = 0;
    integer seen_tokens = 0;
    integer stale_seen = 0;
    integer held_valid = 0;
    reg signed [63:0] held_act, held_wgt;
    reg [7:0] held_k;
    reg [7:0] held_pmask, held_cmask;
    integer ledger_start, ledger_after_load, ledger_after_jobs;
    integer ledger_src0, ledger_param0, ledger_lsrc0, ledger_lparam0;

    /* Independent request backpressure. */
    assign source_req_ready = ((cyc % 7) != 2);
    assign param_req_ready = ((cyc % 11) != 5);

    always @(negedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            token_ready <= ((cyc % 13) != 3);
        end else
            token_ready <= 1'b1;
    end

    function automatic [31:0] source_pattern;
        input [31:0] a;
        integer wi, b;
        begin
            wi = (a - load_source_base_addr) >> 2;
            source_pattern = 0;
            for (b = 0; b < 4; b = b + 1)
                source_pattern[(b*8) +: 8] = (wi*4 + b + 1) & 255;
        end
    endfunction
    function automatic [31:0] param_pattern;
        input [31:0] a;
        integer wi, b;
        begin
            wi = (a - load_param_base_addr) >> 2;
            param_pattern = 0;
            for (b = 0; b < 4; b = b + 1)
                param_pattern[(b*8) +: 8] = (wi*4 + b) & 255;
        end
    endfunction

    /* The DUT samples responses on the following clock edge. */
    always @(posedge clk) begin
        if (!rst_n) begin
            source_resp_valid <= 0;
            param_resp_valid <= 0;
        end else begin
            if (source_req_valid && source_req_ready &&
                source_req_addr !== (load_source_base_addr + (source_external_word_count << 2))) begin
                $display("ERROR source address sequence got=%h exp=%h", source_req_addr,
                         load_source_base_addr + (source_external_word_count << 2));
                errors = errors + 1;
            end
            if (param_req_valid && param_req_ready &&
                param_req_addr !== (load_param_base_addr + (param_external_word_count << 2))) begin
                $display("ERROR parameter address sequence got=%h exp=%h", param_req_addr,
                         load_param_base_addr + (param_external_word_count << 2));
                errors = errors + 1;
            end
            source_resp_valid <= source_req_valid && source_req_ready;
            param_resp_valid <= param_req_valid && param_req_ready;
            if (source_req_valid && source_req_ready)
                source_resp_data <= source_pattern(source_req_addr);
            if (param_req_valid && param_req_ready)
                param_resp_data <= param_pattern(param_req_addr);
            if (job_reject_stale) stale_seen = stale_seen + 1;
            if (token_valid && !token_ready) begin
                if (held_valid && (token_act_vec !== held_act ||
                                   token_wgt_vec !== held_wgt || token_k_idx !== held_k ||
                                   token_pixel_mask !== held_pmask || token_cout_mask !== held_cmask)) begin
                    $display("ERROR token changed under backpressure at cycle %0d", cyc);
                    errors = errors + 1;
                end
                held_valid = 1;
                held_act = token_act_vec;
                held_wgt = token_wgt_vec;
                held_k = token_k_idx;
                held_pmask = token_pixel_mask;
                held_cmask = token_cout_mask;
            end else if (token_valid && token_ready) begin
                held_valid = 0;
                if (check_enabled) begin : token_check
                    integer p, row, lane, expb;
                    reg [7:0] gotb;
                    if (token_k_idx >= exp_cin || token_first !== (token_k_idx == 0) ||
                        token_last !== (token_k_idx == exp_cin-1) ||
                        token_pixel_base !== exp_pbase || token_cout_base !== exp_tile*8 ||
                        token_pixel_mask !== exp_pmask || token_cout_mask !== exp_cmask) begin
                        $display("ERROR token metadata k=%0d first=%b last=%b p=%0d c=%0d", token_k_idx,
                                 token_first, token_last, token_pixel_base, token_cout_base);
                        errors = errors + 1;
                    end
                    row = exp_tile*exp_cin + token_k_idx;
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        p = exp_pbase + lane;
                        expb = (p*exp_cin + token_k_idx + 1) & 255;
                        gotb = token_act_vec[(lane*8) +: 8];
                        if (gotb !== ((expb) & 255)) begin
                            if (errors < 8) $display("ERROR act k=%0d lane=%0d got=%0d exp=%0d", token_k_idx, lane,
                                                     gotb, expb);
                            errors = errors + 1;
                        end
                        expb = (row*8 + lane) & 255;
                        gotb = token_wgt_vec[(lane*8) +: 8];
                        if (gotb !== ((expb) & 255)) begin
                            if (errors < 8) $display("ERROR wgt k=%0d lane=%0d got=%0d exp=%0d", token_k_idx, lane,
                                                     gotb, expb);
                            errors = errors + 1;
                        end
                    end
                    seen_tokens = seen_tokens + 1;
                end
            end
        end
    end

    task automatic do_cfg_load;
        input integer lid, ep, sess;
        integer sw, pw, i;
        begin
            @(negedge clk);
            cfg_layer_id = lid; cfg_mode = 0; cfg_epoch = ep; cfg_session = sess;
            while (!cfg_ready) @(posedge clk);
            cfg_valid = 1;
            @(posedge clk); @(negedge clk); cfg_valid = 0;
            if (lid == 1) begin exp_cin=16; exp_cout=32; end
            else if (lid == 3) begin exp_cin=64; exp_cout=64; end
            else begin exp_cin=128; exp_cout=256; end
            sw = (cfg_output_pixels * exp_cin) / 4;
            pw = (exp_cin * exp_cout) / 4;
            if (cfg_source_words !== sw || cfg_param_words !== pw) begin
                $display("ERROR shape lid=%0d source=%0d/%0d param=%0d/%0d", lid, cfg_source_words, sw,
                         cfg_param_words, pw); errors=errors+1;
            end
            load_source_base_addr = 32'h00100000 + lid*32'h00100000;
            load_param_base_addr = 32'h10100000 + lid*32'h00100000;
            @(negedge clk); load_start_valid = 1;
            while (!load_start_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); load_start_valid = 0;
            while (!load_done) @(posedge clk);
            @(negedge clk); commit_valid = 1;
            while (!committed_valid) begin
                @(posedge clk);
                if (commit_reject) $display("commit rejected unexpectedly lid=%0d", lid);
            end
            @(negedge clk); commit_valid = 0;
            if (!committed_valid || committed_epoch !== ep || committed_session !== sess) begin
                $display("ERROR commit lid=%0d", lid); errors=errors+1;
            end
            if (source_external_word_count !== sw || param_external_word_count !== pw) begin
                $display("ERROR load count lid=%0d source=%0d/%0d param=%0d/%0d", lid,
                         source_external_word_count, sw, param_external_word_count, pw); errors=errors+1;
            end
        end
    endtask

    task automatic do_job;
        input integer ep, sess, pbase, tile;
        begin
            exp_pbase = pbase; exp_tile = tile; seen_tokens = 0; check_enabled = 0;
            if (use_tail) begin exp_pmask = 8'h1f; exp_cmask = 8'h3f; end
            else begin exp_pmask = 8'hff; exp_cmask = 8'hff; end
            @(negedge clk);
            job_epoch=ep; job_session=sess; job_pixel_base=pbase; job_cout_tile=tile;
            job_pixel_mask=exp_pmask; job_cout_mask=exp_cmask; job_valid=1;
            while (!job_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); job_valid=0;
            check_enabled = 1;
            while (!job_done) @(posedge clk);
            check_enabled = 0;
            if (seen_tokens !== exp_cin) begin
                $display("ERROR token count tile=%0d got=%0d exp=%0d", tile, seen_tokens, exp_cin);
                errors=errors+1;
            end
        end
    endtask

    initial begin
        cfg_layer_id=0; cfg_mode=0; cfg_epoch=0; cfg_session=0;
        load_source_base_addr=0; load_param_base_addr=0;
        job_epoch=0; job_session=0; job_pixel_base=0; job_cout_tile=0;
        job_pixel_mask=0; job_cout_mask=0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        ledger_start = cyc; ledger_src0 = source_external_word_count;
        ledger_param0 = param_external_word_count; ledger_lsrc0 = local_source_word_read_count;
        ledger_lparam0 = local_param_row_read_count;
        do_cfg_load(1, 1, 2);
        ledger_after_load = cyc;
        use_tail = 1;
        do_job(1, 2, 0, 0);
        use_tail = 0;
        do_job(1, 2, 0, 1); // same window: no source-bank gather
        do_job(1, 2, 8, 0); // new window
        ledger_after_jobs = cyc;
        $display("LEDGER DS1_PW cycles cfg_load=%0d jobs=%0d ext_source=%0d ext_param=%0d local_source=%0d local_param=%0d reuse=%0d",
                 ledger_after_load-ledger_start, ledger_after_jobs-ledger_after_load,
                 source_external_word_count, param_external_word_count,
                 local_source_word_read_count-ledger_lsrc0, local_param_row_read_count-ledger_lparam0,
                 window_reuse_count);
        if (window_reuse_count !== 16'd1) begin $display("ERROR reuse DS1=%0d", window_reuse_count); errors=errors+1; end
        ledger_start = cyc; ledger_src0 = source_external_word_count;
        ledger_param0 = param_external_word_count; ledger_lsrc0 = local_source_word_read_count;
        ledger_lparam0 = local_param_row_read_count;
        do_cfg_load(3, 2, 3);
        ledger_after_load = cyc;
        do_job(2, 3, 0, 0);
        do_job(2, 3, 0, 1);
        ledger_after_jobs = cyc;
        $display("LEDGER DS3_PW cycles cfg_load=%0d jobs=%0d ext_source=%0d ext_param=%0d local_source=%0d local_param=%0d reuse=%0d",
                 ledger_after_load-ledger_start, ledger_after_jobs-ledger_after_load,
                 source_external_word_count, param_external_word_count,
                 local_source_word_read_count-ledger_lsrc0, local_param_row_read_count-ledger_lparam0,
                 window_reuse_count);
        if (window_reuse_count < 16'd2) begin $display("ERROR reuse DS3=%0d", window_reuse_count); errors=errors+1; end
        ledger_start = cyc; ledger_src0 = source_external_word_count;
        ledger_param0 = param_external_word_count; ledger_lsrc0 = local_source_word_read_count;
        ledger_lparam0 = local_param_row_read_count;
        do_cfg_load(6, 3, 4);
        ledger_after_load = cyc;
        do_job(3, 4, 0, 0);
        do_job(3, 4, 0, 31);
        ledger_after_jobs = cyc;
        $display("LEDGER DS6_PW cycles cfg_load=%0d jobs=%0d ext_source=%0d ext_param=%0d local_source=%0d local_param=%0d reuse=%0d",
                 ledger_after_load-ledger_start, ledger_after_jobs-ledger_after_load,
                 source_external_word_count, param_external_word_count,
                 local_source_word_read_count-ledger_lsrc0, local_param_row_read_count-ledger_lparam0,
                 window_reuse_count);
        if (source_request_stall_count == 0 || param_request_stall_count == 0) begin
            $display("ERROR request backpressure not observed src=%0d param=%0d", source_request_stall_count,
                     param_request_stall_count); errors=errors+1;
        end
        /* Epoch/session rejection is observable and does not alter state. */
        @(negedge clk); job_epoch=4; job_session=4; job_pixel_base=0; job_cout_tile=0; job_valid=1;
        @(posedge clk); @(negedge clk); job_valid=0;
        repeat (2) @(posedge clk);
        if (stale_seen == 0) begin $display("ERROR stale rejection missing"); errors=errors+1; end
        if (errors == 0)
            $display("PASS ds_persistent_feed_contract DS1/DS3/DS6 tokens=%0d source_words=%0d param_words=%0d local_source_reads=%0d local_param_rows=%0d reuse=%0d stalls=%0d/%0d",
                     token_count, source_external_word_count, param_external_word_count,
                     local_source_word_read_count, local_param_row_read_count, window_reuse_count,
                     source_request_stall_count, param_request_stall_count);
        else $display("FAIL ds_persistent_feed_contract errors=%0d", errors);
        $finish;
    end
endmodule

`default_nettype wire
