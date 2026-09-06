`timescale 1ns/1ps
`default_nettype none

// Byte-exact DS1 PW consumer test.  The DW vectors are the real endpoint
// export, but are presented in a coprime permutation with valid gaps.  The
// configuration memory inserts a variable response delay and the output sink
// applies independent ready backpressure.
module tb_ds12_stream_ds1_pw_consumer;
    localparam integer PIXELS = 1024;
    localparam integer CFG_WORDS = 224;
    localparam integer DW_BYTES = PIXELS * 16;
    localparam integer OUT_BYTES = PIXELS * 32;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg start;
    wire ready;
    wire cfg_req_valid;
    reg cfg_req_ready;
    wire [31:0] cfg_req_addr;
    wire [7:0] cfg_req_index;
    wire [1:0] cfg_req_kind;
    wire cfg_req_last;
    reg cfg_resp_valid;
    wire cfg_resp_ready;
    reg [31:0] cfg_resp_data;

    reg dw_valid;
    wire dw_ready;
    reg [127:0] dw_data;
    reg [5:0] dw_row;
    reg [9:0] dw_pixel;
    reg [1:0] dw_context;
    reg dw_owner;
    reg [31:0] dw_epoch;
    reg dw_last;

    wire sink_valid;
    reg sink_ready;
    wire [31:0] sink_addr;
    wire [31:0] sink_data;
    wire [3:0] sink_strb;
    wire [5:0] sink_row;
    wire [9:0] sink_pixel;
    wire [2:0] sink_word_in_pixel;
    wire [1:0] sink_context;
    wire sink_owner;
    wire [31:0] sink_epoch;
    wire sink_last;
    wire busy, done, error;
    wire [31:0] cfg_read_count, cfg_weight_read_count, dw_vector_count;
    wire [31:0] pw_token_count, pw_mac_count, output_word_count;
    wire [4:0] partial_context_peak;

    reg [7:0] dw_bytes [0:DW_BYTES-1];
    reg [7:0] expected_bytes [0:OUT_BYTES-1];
    reg [7:0] weight_bytes [0:511];
    reg [31:0] bias_words [0:31];
    reg [31:0] mult_words [0:31];
    reg [31:0] shift_words [0:31];

    integer order [0:PIXELS-1];
    integer source_index;
    integer cfg_pending;
    integer cfg_delay;
    reg [31:0] cfg_pending_data;
    reg [31:0] cfg_pending_addr;
    integer lfsr;
    integer cfg_lfsr;
    integer cycles;
    integer first_cycle;
    integer last_cycle;
    integer output_errors;
    integer tag_errors;
    integer stall_errors;
    integer dw_accepts;
    integer sink_accepts;
    integer i, lane, b, pidx, widx;
    reg hold_valid;
    reg hold_ready;
    reg [31:0] hold_data, hold_addr;
    reg [9:0] hold_pixel;

    ds12_stream_ds1_pw_consumer dut (
        .clk(clk), .rst_n(rst_n), .start(start), .ready(ready),
        .cfg_req_valid(cfg_req_valid), .cfg_req_ready(cfg_req_ready),
        .cfg_req_addr(cfg_req_addr), .cfg_req_index(cfg_req_index),
        .cfg_req_kind(cfg_req_kind), .cfg_req_last(cfg_req_last),
        .cfg_resp_valid(cfg_resp_valid), .cfg_resp_ready(cfg_resp_ready),
        .cfg_resp_data(cfg_resp_data),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data),
        .dw_row(dw_row), .dw_pixel(dw_pixel), .dw_context(dw_context),
        .dw_owner(dw_owner), .dw_epoch(dw_epoch), .dw_last(dw_last),
        .sink_valid(sink_valid), .sink_ready(sink_ready), .sink_addr(sink_addr),
        .sink_data(sink_data), .sink_strb(sink_strb), .sink_row(sink_row),
        .sink_pixel(sink_pixel), .sink_word_in_pixel(sink_word_in_pixel),
        .sink_context(sink_context), .sink_owner(sink_owner),
        .sink_epoch(sink_epoch), .sink_last(sink_last), .busy(busy),
        .done(done), .error(error), .cfg_read_count(cfg_read_count),
        .cfg_weight_read_count(cfg_weight_read_count), .dw_vector_count(dw_vector_count),
        .pw_token_count(pw_token_count), .pw_mac_count(pw_mac_count),
        .output_word_count(output_word_count), .partial_context_peak(partial_context_peak)
    );

    function automatic [31:0] cfg_lookup;
        input [31:0] addr;
        integer n;
        begin
            cfg_lookup = 0;
            if ((addr >= 32'h3200) && (addr < 32'h3400)) begin
                n = (addr - 32'h3200) >> 2;
                cfg_lookup = {weight_bytes[n*4+3], weight_bytes[n*4+2], weight_bytes[n*4+1], weight_bytes[n*4]};
            end else if ((addr >= 32'h3400) && (addr < 32'h3480)) begin
                n = (addr - 32'h3400) >> 2; cfg_lookup = bias_words[n];
            end else if ((addr >= 32'h3480) && (addr < 32'h3500)) begin
                n = (addr - 32'h3480) >> 2; cfg_lookup = mult_words[n];
            end else if ((addr >= 32'h3500) && (addr < 32'h3580)) begin
                n = (addr - 32'h3500) >> 2; cfg_lookup = shift_words[n];
            end
        end
    endfunction

    // Configuration response source: request fields are sampled only on the
    // request handshake and a response is held until cfg_resp_ready.
    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_req_ready <= 0;
            cfg_resp_valid <= 0;
            cfg_resp_data <= 0;
            cfg_pending <= 0;
            cfg_delay <= 0;
            cfg_pending_data <= 0;
            cfg_pending_addr <= 0;
            cfg_lfsr <= 32'h73ac19e1;
        end else begin
            cfg_req_ready <= ((cfg_lfsr & 3) != 0);
            if (cfg_resp_valid && cfg_resp_ready) begin
                cfg_resp_valid <= 0;
                cfg_pending <= 0;
            end
            if (cfg_pending && !cfg_resp_valid) begin
                if (cfg_delay > 0) cfg_delay <= cfg_delay - 1;
                else begin cfg_resp_valid <= 1; cfg_resp_data <= cfg_pending_data; end
            end
            if (cfg_req_valid && cfg_req_ready) begin
                cfg_pending <= 1;
                cfg_delay <= cfg_req_index[2:0] + 1;
                cfg_pending_addr <= cfg_req_addr;
                cfg_pending_data <= cfg_lookup(cfg_req_addr);
            end
            cfg_lfsr <= {cfg_lfsr[28:0], cfg_lfsr[31] ^ cfg_lfsr[21] ^ cfg_lfsr[1] ^ cfg_lfsr[0]};
        end
    end

    // Permuted DW producer and randomized output sink.
    always @* begin
        dw_valid = 0; dw_data = 0; dw_pixel = 0; dw_row = 0;
        dw_context = 0; dw_owner = 0; dw_epoch = 0; dw_last = 0;
        if (source_index < PIXELS) begin
            pidx = order[source_index];
            dw_valid = ((lfsr[5:0] != 0) || (source_index[2:0] == 0));
            dw_pixel = pidx;
            dw_row = pidx / 32;
            dw_context = (pidx >> 3) & 3;
            dw_owner = (pidx >> 3) & 1;
            dw_epoch = pidx >> 4;
            dw_last = (source_index == PIXELS-1);
            for (lane = 0; lane < 16; lane = lane + 1)
                dw_data[lane*8 +: 8] = dw_bytes[pidx*16+lane];
        end
    end

    always @* sink_ready = (lfsr[10:8] != 0);

    always @(posedge clk) begin
        if (!rst_n) begin
            source_index <= PIXELS;
            cycles <= 0; first_cycle <= -1; last_cycle <= -1;
            output_errors <= 0; tag_errors <= 0; stall_errors <= 0;
            dw_accepts <= 0; sink_accepts <= 0; hold_valid <= 0; hold_ready <= 0;
            start <= 0; lfsr <= 32'h1aceb00c;
        end else begin
            cycles <= cycles + 1;
            start <= 0;
            if (ready && source_index == PIXELS) begin
                start <= 1;
                source_index <= 0;
            end
            if (dw_valid && dw_ready) begin
                dw_accepts <= dw_accepts + 1;
                if (first_cycle < 0) first_cycle <= cycles;
                source_index <= source_index + 1;
            end
            if (hold_valid && !hold_ready) begin
                if (sink_data !== hold_data || sink_addr !== hold_addr || sink_pixel !== hold_pixel)
                    stall_errors <= stall_errors + 1;
            end
            if (sink_valid && sink_ready) begin
                sink_accepts <= sink_accepts + 1;
                if (sink_addr !== (32'h00100000 + sink_pixel*32 + sink_word_in_pixel*4) || sink_strb !== 4'hf)
                    tag_errors <= tag_errors + 1;
                if (sink_owner !== ((sink_pixel >> 3) & 1) || sink_epoch !== (sink_pixel >> 4) || sink_context !== ((sink_pixel >> 3) & 3))
                    tag_errors <= tag_errors + 1;
                for (b = 0; b < 4; b = b + 1)
                    if (sink_data[b*8 +: 8] !== expected_bytes[sink_pixel*32 + sink_word_in_pixel*4 + b])
                        output_errors <= output_errors + 1;
                if (sink_last) last_cycle <= cycles;
            end
            hold_valid <= sink_valid;
            hold_ready <= sink_ready;
            hold_data <= sink_data;
            hold_addr <= sink_addr;
            hold_pixel <= sink_pixel;
            if (done) begin
                if (error || dw_accepts != PIXELS || sink_accepts != PIXELS*8 ||
                    cfg_read_count != CFG_WORDS || cfg_weight_read_count != 128 ||
                    pw_token_count != 8192 || pw_mac_count != 524288 || output_word_count != PIXELS*8 ||
                    output_errors != 0 || tag_errors != 0 || stall_errors != 0 || partial_context_peak < 2 ||
                    last_cycle - first_cycle > 11000) begin
                    $display("DS12_PW_FAIL cfg=%0d/%0d weight_cfg=%0d dw=%0d token=%0d mac=%0d out=%0d peak=%0d span=%0d errors=%0d/%0d/%0d", cfg_read_count, CFG_WORDS, cfg_weight_read_count, dw_accepts, pw_token_count, pw_mac_count, output_word_count, partial_context_peak, last_cycle-first_cycle, output_errors, tag_errors, stall_errors);
                    $fatal(1, "DS1 PW consumer acceptance failed");
                end
                $display("DS12_PW_PASS byteexact=1 cfg_reads=%0d weight_reads=%0d dw_vectors=%0d pw_tokens=%0d mac=%0d output_words=%0d partial_context_peak=%0d span=%0d", cfg_read_count, cfg_weight_read_count, dw_accepts, pw_token_count, pw_mac_count, output_word_count, partial_context_peak, last_cycle-first_cycle);
                $finish(0);
            end
            lfsr <= {lfsr[28:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (cycles > 30000) begin
                $display("TIMEOUT ready=%0d source=%0d dw=%0d cfg=%0d token=%0d out=%0d sink_ready=%0d lfsr=%h busy=%0d dut_compute=%0d dut_output=%0d", ready, source_index, dw_accepts, cfg_read_count, pw_token_count, output_word_count, sink_ready, lfsr, busy, dut.compute_active, dut.output_active);
                $fatal(2, "DS1 PW consumer timeout");
            end
        end
    end

    initial begin
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_dw_output_i8.hex", dw_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_output_i8.hex", expected_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_pw_weight_i8.hex", weight_bytes);
        // PW affine words are read from the generated transaction ledger;
        // the reference intentionally keeps the complete packed stream in a
        // single file rather than emitting redundant per-array files.
        begin : read_pw_cfg
            integer fd, rc, layer, kind, index, address, mask, data_word;
            fd = $fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex", "r");
            if (fd == 0) $fatal(2, "missing DS12 packed config ledger");
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%d %d %d %h %h %h\n", layer, kind, index, address, mask, data_word);
                if (rc == 6 && layer == 1) begin
                    if (kind == 5) bias_words[index] = data_word;
                    if (kind == 6) mult_words[index] = data_word;
                    if (kind == 7) shift_words[index] = data_word;
                end
            end
            $fclose(fd);
        end
        // Context order is permuted, and each eight-pixel context has its
        // own permutation.  This exercises tag association while respecting
        // the bounded partial-context contract (the DUT never buffers a full
        // layer of DW vectors).
        for (i = 0; i < PIXELS; i = i + 1)
            order[i] = (((i / 8) * 17) % 128) * 8 + (((i % 8) * 3) % 8);
        repeat (3) @(posedge clk);
        rst_n = 1;
    end
endmodule

`default_nettype wire
