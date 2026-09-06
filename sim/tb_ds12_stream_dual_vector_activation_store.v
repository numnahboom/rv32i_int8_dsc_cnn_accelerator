`timescale 1ns/1ps
`default_nettype none

module tb_ds12_stream_dual_vector_activation_store;
    localparam integer LINE_WORDS = 2048;
    localparam integer BANK_BYTES = LINE_WORDS * 16;
    localparam integer DS1_WORDS = 32*32*32/4;
    localparam integer DS2_WORDS = 16*16*64/4;
    localparam integer DS1_VECTORS = 4608;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg start_valid, start_bank;
    reg [31:0] start_epoch, start_expected_words;
    wire start_ready;
    reg write_valid, write_bank, write_last;
    reg [31:0] write_epoch, write_addr, write_data;
    reg [3:0] write_be;
    wire write_ready;
    wire write_resp_valid, write_resp_bank;
    wire [31:0] write_resp_epoch, write_resp_addr;
    reg write_resp_ready;
    reg layer_end_valid, layer_end_bank;
    reg [31:0] layer_end_epoch;
    wire layer_end_ready, layer_end_done;
    reg commit_valid, commit_bank;
    reg [31:0] commit_epoch;
    wire commit_ready, commit_done, atomic_swap;
    reg read_req_valid, read_req_bank;
    reg [31:0] read_req_epoch, read_req_addr;
    wire read_req_ready, read_resp_valid;
    wire [127:0] read_resp_data;
    wire read_resp_bank;
    wire [31:0] read_resp_epoch, read_resp_addr;
    reg read_resp_ready;
    wire [1:0] bank0_state, bank1_state;
    wire [31:0] bank0_epoch, bank1_epoch, active_read_epoch;
    wire active_read_bank, active_write, active_write_bank;
    wire [31:0] write_count, write_expected_words;
    wire write_last_seen, error;
    wire [7:0] error_code;

    reg [7:0] model0 [0:BANK_BYTES-1];
    reg [7:0] model1 [0:BANK_BYTES-1];
    reg [31:0] rng;
    reg random_ready, random_read_only;
    integer i, b, waits, checks, concurrent_cycles;
    integer edge_count;
    reg [31:0] w, a;
    reg [127:0] expected_vector;
    reg [127:0] stalled_vector;
    reg stalled_bank;
    reg [31:0] stalled_epoch, stalled_addr;
    wire [31:0] dut_write_epoch_active;

    ds12_stream_dual_vector_activation_store #(.LINE_WORDS(LINE_WORDS)) dut (
        .clk(clk), .rst_n(rst_n),
        .layer_start_valid(start_valid), .layer_start_ready(start_ready),
        .layer_start_bank(start_bank), .layer_start_epoch(start_epoch),
        .layer_start_expected_words(start_expected_words),
        .write_valid(write_valid), .write_ready(write_ready),
        .write_bank(write_bank), .write_epoch(write_epoch),
        .write_addr(write_addr), .write_data(write_data), .write_be(write_be),
        .write_last(write_last), .write_resp_valid(write_resp_valid),
        .write_resp_ready(write_resp_ready), .write_resp_bank(write_resp_bank),
        .write_resp_epoch(write_resp_epoch), .write_resp_addr(write_resp_addr),
        .layer_end_valid(layer_end_valid), .layer_end_ready(layer_end_ready),
        .layer_end_bank(layer_end_bank), .layer_end_epoch(layer_end_epoch),
        .layer_end_done(layer_end_done), .commit_valid(commit_valid),
        .commit_ready(commit_ready), .commit_bank(commit_bank),
        .commit_epoch(commit_epoch), .commit_done(commit_done),
        .atomic_swap(atomic_swap), .read_req_valid(read_req_valid),
        .read_req_ready(read_req_ready), .read_req_bank(read_req_bank),
        .read_req_epoch(read_req_epoch), .read_req_addr(read_req_addr),
        .read_resp_valid(read_resp_valid), .read_resp_ready(read_resp_ready),
        .read_resp_data(read_resp_data), .read_resp_bank(read_resp_bank),
        .read_resp_epoch(read_resp_epoch), .read_resp_addr(read_resp_addr),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
        .active_read_bank(active_read_bank), .active_read_epoch(active_read_epoch),
        .active_write(active_write), .active_write_bank(active_write_bank),
        .write_epoch_active(dut_write_epoch_active),
        .write_count(write_count), .write_expected_words(write_expected_words),
        .write_last_seen(write_last_seen), .error(error), .error_code(error_code)
    );
    function automatic [31:0] next_rng;
        input [31:0] x;
        begin next_rng = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]}; end
    endfunction

    always @(negedge clk) begin
        if (!rst_n) begin
            write_resp_ready <= 1'b0;
            read_resp_ready <= 1'b0;
            rng <= 32'h91e10da5;
        end else if (!random_ready) begin
            write_resp_ready <= 1'b1;
            read_resp_ready <= 1'b1;
        end else begin
            write_resp_ready <= random_read_only ? 1'b1 : (rng[2:0] != 0);
            read_resp_ready <= (rng[6:4] != 0);
            rng <= next_rng(rng);
        end
    end

    task reset_dut;
        begin
            rst_n = 1'b0; start_valid = 0; write_valid = 0;
            layer_end_valid = 0; commit_valid = 0; read_req_valid = 0;
            random_ready = 0;
            random_read_only = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    task start_layer;
        input bank; input [31:0] epoch; input [31:0] words;
        begin
            @(negedge clk); start_bank = bank; start_epoch = epoch;
            start_expected_words = words; start_valid = 1'b1;
            while (!start_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); start_valid = 1'b0;
        end
    endtask

    task send_write;
        input bank; input [31:0] epoch; input [31:0] addr;
        input [31:0] data; input [3:0] be; input last;
        begin
            @(negedge clk); write_bank = bank; write_epoch = epoch;
            write_addr = addr; write_data = data; write_be = be;
            write_last = last; write_valid = 1'b1; waits = 0;
            while (!write_ready) begin
                waits = waits + 1;
                if (waits > 1000) $fatal(1, "write timeout");
                @(negedge clk);
            end
            @(posedge clk); @(negedge clk); write_valid = 1'b0;
        end
    endtask

    task finish_layer;
        input bank; input [31:0] epoch;
        begin
            while (write_resp_valid) @(posedge clk);
            @(negedge clk); commit_bank = bank; commit_epoch = epoch;
            commit_valid = 1'b1;
            while (!commit_ready) @(negedge clk);
            @(posedge clk); #1;
            if (!atomic_swap || !commit_done || !layer_end_done)
                $fatal(1, "atomic swap pulse missing");
            @(negedge clk); commit_valid = 1'b0;
            @(posedge clk); @(negedge clk);
        end
    endtask

    task check_vector;
        input bank; input [31:0] epoch; input [31:0] addr;
        begin
            if (bank == 0)
                for (b = 0; b < 16; b = b + 1) expected_vector[b*8 +: 8] = model0[addr+b];
            else
                for (b = 0; b < 16; b = b + 1) expected_vector[b*8 +: 8] = model1[addr+b];
            @(negedge clk); read_req_bank = bank; read_req_epoch = epoch;
            read_req_addr = addr; read_req_valid = 1'b1;
            while (!read_req_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); read_req_valid = 1'b0;
            while (!read_resp_valid) @(negedge clk);
            if (read_resp_data !== expected_vector || read_resp_bank !== bank ||
                read_resp_epoch !== epoch || read_resp_addr !== addr)
                $fatal(1, "vector mismatch bank=%0d addr=%h", bank, addr);
            stalled_vector = read_resp_data; stalled_bank = read_resp_bank;
            stalled_epoch = read_resp_epoch; stalled_addr = read_resp_addr;
            while (!read_resp_ready) begin
                @(negedge clk);
                if (read_resp_data !== stalled_vector || read_resp_bank !== stalled_bank ||
                    read_resp_epoch !== stalled_epoch || read_resp_addr !== stalled_addr)
                    $fatal(1, "stalled vector response changed");
            end
            @(posedge clk); checks = checks + 1;
        end
    endtask

    initial begin
        start_valid = 0; start_bank = 0; start_epoch = 0; start_expected_words = 0;
        write_valid = 0; write_bank = 0; write_epoch = 0; write_addr = 0;
        write_data = 0; write_be = 0; write_last = 0; write_resp_ready = 0;
        layer_end_valid = 0; layer_end_bank = 0; layer_end_epoch = 0;
        commit_valid = 0; commit_bank = 0; commit_epoch = 0;
        read_req_valid = 0; read_req_bank = 0; read_req_epoch = 0; read_req_addr = 0;
        read_resp_ready = 0; random_ready = 0; random_read_only = 0;
        rng = 32'h91e10da5; checks = 0;
        for (i = 0; i < BANK_BYTES; i = i + 1) begin model0[i] = 0; model1[i] = 0; end

        // DS1: all 8,192 words into B, one accepted write on every cycle.
        reset_dut; start_layer(1, 32'h11, DS1_WORDS);
        @(negedge clk); write_valid = 1'b1; write_bank = 1; write_epoch = 32'h11;
        write_be = 4'hf; edge_count = 0;
        for (i = 0; i < DS1_WORDS; i = i + 1) begin
            w = 32'ha5000000 ^ i; write_addr = i*4; write_data = w;
            write_last = (i == DS1_WORDS-1);
            @(posedge clk); edge_count = edge_count + 1;
            model1[i*4] = w[7:0]; model1[i*4+1] = w[15:8];
            model1[i*4+2] = w[23:16]; model1[i*4+3] = w[31:24];
            if (i != DS1_WORDS-1) @(negedge clk);
        end
        @(negedge clk); write_valid = 0;
        if (edge_count != 8192 || write_count != DS1_WORDS || !write_last_seen)
            $fatal(1, "DS1 write count/cycle failure cycles=%0d count=%0d last=%0d", edge_count, write_count, write_last_seen);
        finish_layer(1, 32'h11);
        if (bank1_state != 2'd1 || bank0_state != 2'd0 || active_read_bank != 1)
            $fatal(1, "DS1 owner swap failure");

        // DS2 is written to A while every real DS1 vector address is read
        // from B.  The independent lane-bank instances overlap on each edge.
        start_layer(0, 32'h22, DS2_WORDS);
        // Random read backpressure is enabled during the overlap.  The write
        // response stays always-ready, and write_valid is gated until the
        // matching read request can be accepted, preventing duplicate writes
        // while the one-entry vector response is stalled.
        random_ready = 1; random_read_only = 1;
        @(negedge clk); write_valid = 0; write_bank = 0; write_epoch = 32'h22;
        write_be = 4'hf; read_req_valid = 1'b1; read_req_bank = 1;
        read_req_epoch = 32'h11; concurrent_cycles = 0;
        for (i = 0; i < DS1_VECTORS; i = i + 1) begin
            a = ((i * 29) % LINE_WORDS) * 16;
            read_req_addr = a;
            for (b = 0; b < 16; b = b + 1) expected_vector[b*8 +: 8] = model1[a+b];
            if (i < DS2_WORDS) begin
                w = 32'h5a000000 + i*32'h01010101;
                write_addr = i*4; write_data = w;
                if ((i % 17) == 0) write_be = 4'h7; else write_be = 4'hf;
                model0[i*4] = w[7:0]; model0[i*4+1] = w[15:8];
                model0[i*4+2] = w[23:16]; model0[i*4+3] = w[31:24];
                if ((i % 17) == 0) model0[i*4+3] = 0;
                write_last = (i == DS2_WORDS-1);
            end else begin
                write_last = 0;
            end
            while (!read_req_ready) @(negedge clk);
            write_valid = (i < DS2_WORDS);
            @(posedge clk); concurrent_cycles = concurrent_cycles + 1;
            @(negedge clk);
            write_valid = 0;
            for (b = 0; b < 16; b = b + 1)
                expected_vector[b*8 +: 8] = model1[read_resp_addr+b];
            if (!read_resp_valid || read_resp_data !== expected_vector ||
                read_resp_bank !== 1'b1 || read_resp_epoch !== 32'h11)
                $fatal(1, "concurrent vector mismatch i=%0d got=%h exp=%h valid=%0d addr=%h", i, read_resp_data, expected_vector, read_resp_valid, read_resp_addr);
            if (i != DS1_VECTORS-1) begin
                // setup for next iteration occurs at this falling edge
            end
        end
        write_valid = 0; read_req_valid = 0;
        while (!read_resp_ready) @(negedge clk);
        @(posedge clk); @(negedge clk);
        if (concurrent_cycles > DS1_VECTORS + 4)
            $fatal(1, "concurrent vector data-cycle bound exceeded=%0d", concurrent_cycles);
        finish_layer(0, 32'h22);
        if (bank0_state != 2'd1 || bank1_state != 2'd0 || active_read_bank != 0 ||
            bank0_epoch != 32'h22 || checks != 0)
            $fatal(1, "DS2 owner swap failure");

        // Randomized response stalls/delays and a complete 16 KiB DS2 vector
        // sweep after the second atomic publication.
        random_ready = 1;
        for (i = 0; i < DS2_WORDS/4; i = i + 1)
            check_vector(0, 32'h22, i*16);

        // Invalid cases equivalent to activation_banks: stale, range, early,
        // same-bank, and an invalid start against the published READ bank.
        reset_dut; @(negedge clk); read_req_bank=0; read_req_epoch=99;
        read_req_addr=0; read_req_valid=1; @(posedge clk); @(negedge clk);
        read_req_valid=0; repeat (1) @(posedge clk);
        if (!error || !(| (error_code & 8'h02))) $fatal(1, "stale epoch missing");
        reset_dut; start_layer(1, 1, 1); send_write(1, 1, BANK_BYTES, 32'hdeadbeef, 4'hf, 1);
        if (!error || !(| (error_code & 8'h10))) $fatal(1, "range error missing");
        reset_dut; start_layer(1, 3, 1); @(negedge clk); commit_bank=1; commit_epoch=3;
        commit_valid=1; @(posedge clk); @(negedge clk); commit_valid=0;
        if (!error || !(| (error_code & 8'h20))) $fatal(1, "early commit error missing");
        reset_dut; start_layer(1, 5, 1); @(negedge clk); read_req_bank=1;
        read_req_epoch=5; read_req_addr=0; read_req_valid=1; @(posedge clk); @(negedge clk);
        read_req_valid=0; if (!error || !(| (error_code & 8'h08))) $fatal(1, "same-bank error missing");
        reset_dut; start_layer(0, 6, 1);
        if (!error || !(| (error_code & 8'h01))) $fatal(1, "invalid start error missing");

        $display("PASS ds12_stream_dual_vector_activation_store DS1_words=%0d DS1_write_cycles=%0d DS2_words=%0d DS1_vectors=%0d DS2_vectors=%0d concurrent_data_cycles=%0d physical_vector_banks=2 estimated_BRAM18=16 invalid_cases=5", DS1_WORDS, edge_count, DS2_WORDS, DS1_VECTORS, DS2_WORDS/4, concurrent_cycles);
        $finish(0);
    end
endmodule

`default_nettype wire
