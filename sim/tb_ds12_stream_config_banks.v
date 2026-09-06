`timescale 1ns/1ps
`default_nettype none

// Contract TB for ds12_stream_config_banks.  The source words are generated
// from the real C0 export by python/ds12_stream_reference.py; no synthetic
// payloads are substituted here.
module tb_ds12_stream_config_banks;
    localparam integer DS1_WORDS = 308;
    localparam integer DS2_WORDS = 872;
    localparam integer TOTAL_WORDS = DS1_WORDS + DS2_WORDS;
    localparam integer QDEPTH = 2048;
    localparam integer MAX_CYCLES = 30000;
    localparam [31:0] DS1_BASE = 32'h0000_3000;
    localparam [31:0] DS2_BASE = 32'h0000_4000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg start;
    reg [1:0] start_layer;
    reg [31:0] start_base_addr;
    reg [15:0] start_word_count;
    reg [31:0] start_epoch;
    wire start_ready;
    wire mem_req_valid;
    reg mem_req_ready;
    wire [31:0] mem_req_addr;
    wire [3:0] mem_req_strb;
    wire [15:0] mem_req_word_index;
    wire mem_resp_valid;
    wire mem_resp_ready;
    reg [31:0] mem_resp_rdata;
    reg commit_req;
    reg clear_error;
    reg cfg_rd_en;
    reg cfg_rd_bank;
    reg [15:0] cfg_rd_addr;
    wire [31:0] cfg_rd_data;
    wire cfg_rd_valid;
    wire busy;
    wire active_bank;
    wire [1:0] active_layer;
    wire [31:0] active_epoch;
    wire active_valid;
    wire [1:0] bank_valid;
    wire [15:0] expected_count;
    wire [15:0] issued_count;
    wire [15:0] received_count;
    wire [31:0] load_crc32;
    wire load_done;
    wire error;
    wire [3:0] error_code;

    ds12_stream_config_banks #(.BANK_WORDS(DS2_WORDS), .REQUEST_FIFO_WORDS(1024)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .start_layer(start_layer), .start_base_addr(start_base_addr),
        .start_word_count(start_word_count), .start_epoch(start_epoch), .start_ready(start_ready),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_req_strb(mem_req_strb), .mem_req_word_index(mem_req_word_index),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(mem_resp_ready), .mem_resp_rdata(mem_resp_rdata),
        .commit_req(commit_req), .clear_error(clear_error),
        .cfg_rd_en(cfg_rd_en), .cfg_rd_bank(cfg_rd_bank), .cfg_rd_addr(cfg_rd_addr),
        .cfg_rd_data(cfg_rd_data), .cfg_rd_valid(cfg_rd_valid),
        .busy(busy), .active_bank(active_bank), .active_layer(active_layer), .active_epoch(active_epoch),
        .active_valid(active_valid), .bank_valid(bank_valid), .expected_count(expected_count),
        .issued_count(issued_count), .received_count(received_count), .load_crc32(load_crc32),
        .load_done(load_done), .error(error), .error_code(error_code)
    );

    reg [31:0] expected [0:1][0:DS2_WORDS-1];
    reg [7:0] ds1_dw_bytes [0:143];
    reg [7:0] ds1_pw_bytes [0:511];
    reg [7:0] ds2_dw_bytes [0:287];
    reg [7:0] ds2_pw_bytes [0:2047];
    integer cfg_idx [0:1];
    integer fd, rc, layer, kind, index, be;
    integer addr, data;
    integer errors;
    integer cycle_counter;
    integer request_transactions;
    integer response_transactions;
    integer first_done_cycle [0:1];
    integer last_done_cycle [0:1];
    integer last_request_cycle;
    integer no_bp_gap_errors;
    reg no_backpressure;
    reg [15:0] lfsr;

    reg [31:0] resp_data_q [0:QDEPTH-1];
    integer resp_due_q [0:QDEPTH-1];
    integer q_head, q_tail, q_count;
    reg [1:0] memory_layer;

    assign mem_resp_valid = (q_count != 0) && (resp_due_q[q_head] <= cycle_counter);

    always @* begin
        if (no_backpressure)
            mem_req_ready = 1'b1;
        else
            mem_req_ready = (lfsr[2:0] != 3'b000);
        if (mem_resp_valid)
            mem_resp_rdata = resp_data_q[q_head];
        else
            mem_resp_rdata = 32'd0;
    end

    function [31:0] expected_word;
        input integer l;
        input integer wi;
        begin expected_word = expected[l-1][wi]; end
    endfunction

    function [31:0] crc32_word;
        input [31:0] crc_in;
        input [31:0] value;
        integer b;
        reg [31:0] c;
        begin
            c = crc_in ^ value;
            for (b = 0; b < 32; b = b + 1)
                c = c[0] ? ((c >> 1) ^ 32'hedb88320) : (c >> 1);
            crc32_word = c;
        end
    endfunction

    task clear_error_pulse;
        begin
            @(negedge clk); clear_error = 1'b1;
            @(posedge clk); #1 clear_error = 1'b0;
        end
    endtask

    task pulse_start;
        input [1:0] l;
        input [31:0] b;
        input [15:0] n;
        input [31:0] e;
        begin
            @(negedge clk);
            start_layer = l; start_base_addr = b; start_word_count = n; start_epoch = e; start = 1'b1;
            @(posedge clk); #1 start = 1'b0;
        end
    endtask

    task wait_done;
        input integer l;
        integer guard;
        begin
            guard = 0;
            while (!load_done && guard < MAX_CYCLES) begin @(posedge clk); #1 guard = guard + 1; end
            if (!load_done) begin $display("FAIL timeout waiting DS%0d", l); errors = errors + 1; end
            else begin
                first_done_cycle[l-1] = cycle_counter;
                last_done_cycle[l-1] = cycle_counter;
            end
        end
    endtask

    task read_bank;
        input integer b;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                @(negedge clk); cfg_rd_bank = b[0]; cfg_rd_addr = j; cfg_rd_en = 1'b1;
                @(posedge clk); #1;
                if (!cfg_rd_valid || cfg_rd_data !== expected_word((b == 1) ? 1 : 2, j)) begin
                    $display("FAIL bank read bank=%0d index=%0d got=%08x exp=%08x valid=%b", b, j, cfg_rd_data, expected_word((b == 1) ? 1 : 2, j), cfg_rd_valid);
                    errors = errors + 1;
                end
                @(negedge clk); cfg_rd_en = 1'b0;
            end
        end
    endtask

    integer j;
    integer lane;
    integer expected_byte;
    integer cfg_fd;
    integer cfg_counts_ok;
    reg [31:0] crc_expected;

    // Memory model: ordered response queue, one-cycle minimum latency and a
    // deterministic pseudo-random additional delay.  The queue is much larger
    // than either load, so random delay does not alter the source transaction.
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_counter <= 0;
            lfsr <= 16'h1;
            q_head <= 0; q_tail <= 0; q_count <= 0;
            request_transactions <= 0; response_transactions <= 0;
            last_request_cycle <= -2;
        end else begin
            cycle_counter <= cycle_counter + 1;
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_strb !== 4'b1111)
                    errors <= errors + 1;
                if (mem_req_addr !== ((memory_layer == 1) ? DS1_BASE : DS2_BASE) + (mem_req_word_index * 4)) begin
                    $display("FAIL request address layer=%0d index=%0d addr=%08x", memory_layer, mem_req_word_index, mem_req_addr);
                    errors <= errors + 1;
                end
                resp_data_q[q_tail] <= expected_word(memory_layer, mem_req_word_index);
                resp_due_q[q_tail] <= cycle_counter + (no_backpressure ? 1 : 1 + (lfsr % 5));
                if (q_tail == QDEPTH-1) q_tail <= 0; else q_tail <= q_tail + 1;
                request_transactions <= request_transactions + 1;
                if (no_backpressure && (last_request_cycle >= 0) && cycle_counter-last_request_cycle != 1)
                    no_bp_gap_errors <= no_bp_gap_errors + 1;
                last_request_cycle <= cycle_counter;
            end
            if (mem_resp_valid && mem_resp_ready) begin
                response_transactions <= response_transactions + 1;
                if (q_head == QDEPTH-1) q_head <= 0; else q_head <= q_head + 1;
            end
            case ({mem_req_valid && mem_req_ready, mem_resp_valid && mem_resp_ready})
                2'b10: q_count <= q_count + 1;
                2'b01: q_count <= q_count - 1;
                default: q_count <= q_count;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst_n && load_done) begin
            if (active_layer == 1) first_done_cycle[0] = cycle_counter;
            if (active_layer == 2) first_done_cycle[1] = cycle_counter;
        end
    end

    initial begin
        errors = 0; no_bp_gap_errors = 0; no_backpressure = 1'b1;
        start = 0; start_layer = 0; start_base_addr = 0; start_word_count = 0; start_epoch = 0;
        commit_req = 0; clear_error = 0; cfg_rd_en = 0; cfg_rd_bank = 0; cfg_rd_addr = 0;
        memory_layer = 1;
        cfg_idx[0] = 0; cfg_idx[1] = 0;
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_dw_weight_i8.hex", ds1_dw_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_pw_weight_i8.hex", ds1_pw_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds2_dw_weight_i8.hex", ds2_dw_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds2_pw_weight_i8.hex", ds2_pw_bytes);
        cfg_fd = $fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex", "r");
        if (cfg_fd == 0) begin $display("FAIL missing generated packed config file"); $fatal(1); end
        while (!$feof(cfg_fd)) begin
            rc = $fscanf(cfg_fd, "%d %d %d %h %h %h\n", layer, kind, index, addr, be, data);
            if (rc == 6 && (layer == 1 || layer == 2)) begin
                expected[layer-1][cfg_idx[layer-1]] = data[31:0];
                cfg_idx[layer-1] = cfg_idx[layer-1] + 1;
            end
        end
        $fclose(cfg_fd);
        if (cfg_idx[0] != DS1_WORDS || cfg_idx[1] != DS2_WORDS) begin
            $display("FAIL config counts %0d/%0d", cfg_idx[0], cfg_idx[1]); $fatal(1);
        end
        // Verify every packed weight lane against the source byte files.
        for (j = 0; j < 36; j = j + 1) for (lane = 0; lane < 4; lane = lane + 1)
            if (expected[0][j][lane*8 +: 8] !== ds1_dw_bytes[j*4+lane]) errors = errors + 1;
        for (j = 0; j < 128; j = j + 1) for (lane = 0; lane < 4; lane = lane + 1)
            if (expected[0][84+j][lane*8 +: 8] !== ds1_pw_bytes[j*4+lane]) errors = errors + 1;
        for (j = 0; j < 72; j = j + 1) for (lane = 0; lane < 4; lane = lane + 1)
            if (expected[1][j][lane*8 +: 8] !== ds2_dw_bytes[j*4+lane]) errors = errors + 1;
        for (j = 0; j < 512; j = j + 1) for (lane = 0; lane < 4; lane = lane + 1)
            if (expected[1][168+j][lane*8 +: 8] !== ds2_pw_bytes[j*4+lane]) errors = errors + 1;
        if (errors != 0) $fatal(1, "FAIL packed source lane checks errors=%0d", errors);

        repeat (2) @(posedge clk); rst_n = 1'b1;
        // DS1 uses ideal ready/delay to prove one accepted word per cycle.
        memory_layer = 1; no_backpressure = 1'b1;
        pulse_start(2'd1, DS1_BASE, DS1_WORDS, 32'd1);
        wait_done(1);
        if (!active_valid || active_layer != 1 || active_epoch != 1 || active_bank != 1 || !bank_valid[1]) begin
            $display("FAIL DS1 atomic commit metadata"); errors = errors + 1;
        end
        if (received_count != DS1_WORDS || request_transactions != DS1_WORDS || response_transactions != DS1_WORDS)
            begin $display("FAIL DS1 transactions req=%0d resp=%0d recv=%0d", request_transactions, response_transactions, received_count); errors = errors + 1; end
        crc_expected = 32'hffff_ffff;
        for (j = 0; j < DS1_WORDS; j = j + 1) crc_expected = crc32_word(crc_expected, expected[0][j]);
        if (load_crc32 !== (crc_expected ^ 32'hffff_ffff)) begin
            $display("FAIL DS1 CRC got=%08x exp=%08x", load_crc32, crc_expected ^ 32'hffff_ffff); errors = errors + 1;
        end
        if (no_bp_gap_errors != 0) begin $display("FAIL no-backpressure request gaps=%0d", no_bp_gap_errors); errors = errors + 1; end
        read_bank(1, DS1_WORDS);

        // Invalid/read fence cases are checked while DS1 remains active.
        @(negedge clk); cfg_rd_bank = 0; cfg_rd_addr = 0; cfg_rd_en = 1;
        @(posedge clk); #1 cfg_rd_en = 0;
        if (!error || error_code != 4'd4) begin $display("FAIL invalid-bank read was not reported"); errors = errors + 1; end
        clear_error_pulse;
        pulse_start(2'd1, DS1_BASE, DS1_WORDS, 32'd1);
        if (!error || error_code != 4'd1 || busy) begin $display("FAIL stale epoch case"); errors = errors + 1; end
        clear_error_pulse;
        pulse_start(2'd2, DS2_BASE, 16'd871, 32'd2);
        if (!error || error_code != 4'd2 || busy) begin $display("FAIL overrun/count case"); errors = errors + 1; end
        clear_error_pulse;

        // DS2 prefetch overlaps the (modeled) DS1 runtime window.  Random
        // ready/delay preserves one source transaction per accepted request.
        memory_layer = 2; no_backpressure = 1'b0;
        pulse_start(2'd2, DS2_BASE, DS2_WORDS, 32'd2);
        @(negedge clk); commit_req = 1'b1;
        @(posedge clk); #1 commit_req = 1'b0;
        if (!error || error_code != 4'd3) begin $display("FAIL early commit case"); errors = errors + 1; end
        clear_error_pulse;
        wait_done(2);
        if (!active_valid || active_layer != 2 || active_epoch != 2 || active_bank != 0 || !bank_valid[0]) begin
            $display("FAIL DS2 atomic commit metadata"); errors = errors + 1;
        end
        if (request_transactions != TOTAL_WORDS || response_transactions != TOTAL_WORDS || received_count != DS2_WORDS) begin
            $display("FAIL total transactions req=%0d resp=%0d received=%0d", request_transactions, response_transactions, received_count); errors = errors + 1;
        end
        crc_expected = 32'hffff_ffff;
        for (j = 0; j < DS2_WORDS; j = j + 1) crc_expected = crc32_word(crc_expected, expected[1][j]);
        if (load_crc32 !== (crc_expected ^ 32'hffff_ffff)) begin
            $display("FAIL DS2 CRC got=%08x exp=%08x", load_crc32, crc_expected ^ 32'hffff_ffff); errors = errors + 1;
        end
        if (last_done_cycle[1] - first_done_cycle[0] > 4000) begin
            $display("FAIL DS2 prefetch missed DS1 runtime window delta=%0d", last_done_cycle[1] - first_done_cycle[0]); errors = errors + 1;
        end
        read_bank(0, DS2_WORDS);
        if (errors != 0) begin $display("FAIL ds12_stream_config_banks errors=%0d", errors); $fatal(1); end
        $display("PASS ds12_stream_config_banks transactions=%0d earliest_done=%0d latest_done=%0d no_backpressure=1word/cycle DS1=%0d DS2=%0d", request_transactions, first_done_cycle[0], last_done_cycle[1], first_done_cycle[0], last_done_cycle[1]);
        $finish(0);
    end
endmodule

`default_nettype wire
