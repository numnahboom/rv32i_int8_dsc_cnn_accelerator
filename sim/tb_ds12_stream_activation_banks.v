`timescale 1ns/1ps
`default_nettype none

// Standalone DS12 activation-bank contract test.  The two passes use the
// actual DS1 (32x32x32 bytes) and DS2 (16x16x64 bytes) layer sizes.
module tb_ds12_stream_activation_banks;
    localparam integer BANK_WORDS = 8192;
    localparam integer BANK_BYTES = BANK_WORDS * 4;
    localparam integer DS1_WORDS = 32*32*32/4;
    localparam integer DS2_WORDS = 16*16*64/4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg start_valid, start_bank;
    reg [31:0] start_epoch, start_expected;
    wire start_ready;
    reg write_valid, write_bank, write_last;
    reg [31:0] write_epoch, write_addr, write_data;
    reg [3:0] write_be;
    wire write_ready;
    wire write_resp_valid, write_resp_bank;
    wire [31:0] write_resp_epoch, write_resp_addr;
    reg write_resp_ready;
    reg commit_valid, commit_bank;
    reg [31:0] commit_epoch;
    wire commit_ready, commit_done;
    reg read_req_valid, read_req_bank;
    reg [31:0] read_req_epoch, read_req_addr;
    wire read_req_ready;
    wire read_resp_valid, read_resp_bank;
    wire [31:0] read_resp_data, read_resp_epoch, read_resp_addr;
    reg read_resp_ready;
    wire [1:0] bank0_state, bank1_state;
    wire [31:0] bank0_epoch, bank1_epoch, write_epoch_active;
    wire [31:0] write_count, write_expected_bytes;
    wire write_last_seen, error;
    wire [7:0] error_code;

    reg [7:0] expected0 [0:BANK_BYTES-1];
    reg [7:0] expected1 [0:BANK_BYTES-1];
    integer i, b, k, r, waits, read_checks, write_stalls;
    integer partial_bytes, ds1_cycles;
    integer rd_lfsr;
    reg random_mode;
    reg [31:0] w;

    ds12_stream_activation_banks #(.BANK_WORDS(BANK_WORDS)) dut (
        .clk(clk), .rst_n(rst_n),
        .layer_start_valid(start_valid), .layer_start_ready(start_ready),
        .layer_start_bank(start_bank), .layer_start_epoch(start_epoch),
        .layer_start_expected_bytes(start_expected),
        .write_valid(write_valid), .write_ready(write_ready),
        .write_bank(write_bank), .write_epoch(write_epoch),
        .write_addr(write_addr), .write_data(write_data), .write_be(write_be),
        .write_last(write_last), .write_resp_valid(write_resp_valid),
        .write_resp_ready(write_resp_ready), .write_resp_bank(write_resp_bank),
        .write_resp_epoch(write_resp_epoch), .write_resp_addr(write_resp_addr),
        .commit_valid(commit_valid), .commit_ready(commit_ready),
        .commit_bank(commit_bank), .commit_epoch(commit_epoch),
        .commit_done(commit_done),
        .read_req_valid(read_req_valid), .read_req_ready(read_req_ready),
        .read_req_bank(read_req_bank), .read_req_epoch(read_req_epoch),
        .read_req_addr(read_req_addr), .read_resp_valid(read_resp_valid),
        .read_resp_ready(read_resp_ready), .read_resp_data(read_resp_data),
        .read_resp_bank(read_resp_bank), .read_resp_epoch(read_resp_epoch),
        .read_resp_addr(read_resp_addr), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .bank0_epoch(bank0_epoch),
        .bank1_epoch(bank1_epoch), .write_epoch_active(write_epoch_active),
        .write_count(write_count), .write_expected_bytes(write_expected_bytes),
        .write_last_seen(write_last_seen), .error(error), .error_code(error_code)
    );

    // Response backpressure changes only on falling edges, making a stalled
    // response's payload/tag directly observable and deterministic.
    always @(negedge clk) begin
        if (!rst_n) begin
            write_resp_ready <= 1'b0;
            read_resp_ready <= 1'b0;
            rd_lfsr <= 32'h1f35a7c9;
        end else if (!random_mode) begin
            write_resp_ready <= 1'b1;
            read_resp_ready <= 1'b1;
        end else begin
            write_resp_ready <= (rd_lfsr[2:0] != 0);
            read_resp_ready <= (rd_lfsr[6:4] != 0);
            rd_lfsr <= {rd_lfsr[30:0], rd_lfsr[31] ^ rd_lfsr[21] ^ rd_lfsr[1] ^ rd_lfsr[0]};
        end
    end

    task reset_dut;
        begin
            rst_n = 1'b0; start_valid = 0; write_valid = 0;
            commit_valid = 0; read_req_valid = 0; random_mode = 0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    task start_layer;
        input bank;
        input [31:0] epoch;
        input [31:0] expected;
        begin
            @(negedge clk); start_bank = bank; start_epoch = epoch;
            start_expected = expected; start_valid = 1'b1;
            while (!start_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); start_valid = 1'b0;
        end
    endtask

    task send_write;
        input bank;
        input [31:0] epoch;
        input [31:0] addr;
        input [31:0] data;
        input [3:0] be;
        input last;
        begin
            @(negedge clk); write_bank = bank; write_epoch = epoch;
            write_addr = addr; write_data = data; write_be = be;
            write_last = last; write_valid = 1'b1; waits = 0;
            while (!write_ready) begin
                waits = waits + 1;
                if (waits == 1000) $fatal(1, "write wait timeout bank=%0d epoch=%0d addr=%0d active=%0d ackvalid=%0d ackready=%0d", bank, epoch, addr, dut.active_write, write_resp_valid, write_resp_ready);
                @(negedge clk);
            end
            write_stalls = write_stalls + waits;
            @(posedge clk); @(negedge clk); write_valid = 1'b0;
        end
    endtask

    task do_commit;
        input bank;
        input [31:0] epoch;
        begin
            while (write_resp_valid) @(posedge clk);
            @(negedge clk); commit_bank = bank; commit_epoch = epoch;
            commit_valid = 1'b1;
            while (!commit_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); commit_valid = 1'b0;
            @(posedge clk); @(negedge clk);
        end
    endtask

    task read_and_check;
        input bank;
        input [31:0] epoch;
        input [31:0] addr;
        input [31:0] expected_word;
        begin
            @(negedge clk); read_req_bank = bank; read_req_epoch = epoch;
            read_req_addr = addr; read_req_valid = 1'b1;
            while (!read_req_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); read_req_valid = 1'b0;
            // At the first falling edge after acceptance the synchronous
            // response is valid, before its following ready handshake.
            if (!read_resp_valid) begin
                repeat (20) @(negedge clk);
                if (!read_resp_valid) $fatal(1, "read response timeout bank=%0d addr=%0d ready=%0d pending=%0d state0=%0d state1=%0d err=%0d code=%h", bank, addr, read_resp_ready, dut.read_pending, bank0_state, bank1_state, error, error_code);
            end
            while (!read_resp_valid) @(negedge clk);
            if (read_resp_data !== expected_word || read_resp_bank !== bank ||
                read_resp_epoch !== epoch || read_resp_addr !== addr)
                $fatal(1, "read mismatch bank=%0d addr=%0d got=%h/%0d/%0d/%h expected=%h", bank, addr,
                       read_resp_data, read_resp_bank, read_resp_epoch, read_resp_addr, expected_word);
            read_checks = read_checks + 1;
            @(posedge clk);
        end
    endtask

    function automatic [31:0] expected_word;
        input integer bank;
        input integer addr;
        begin
            if (bank == 0)
                expected_word = {expected0[addr+3], expected0[addr+2], expected0[addr+1], expected0[addr]};
            else
                expected_word = {expected1[addr+3], expected1[addr+2], expected1[addr+1], expected1[addr]};
        end
    endfunction

    initial begin
        start_valid = 0; start_bank = 0; start_epoch = 0; start_expected = 0;
        write_valid = 0; write_bank = 0; write_epoch = 0; write_addr = 0;
        write_data = 0; write_be = 0; write_last = 0; write_resp_ready = 0;
        commit_valid = 0; commit_bank = 0; commit_epoch = 0;
        read_req_valid = 0; read_req_bank = 0; read_req_epoch = 0; read_req_addr = 0;
        read_resp_ready = 0; read_checks = 0; write_stalls = 0;
        for (i = 0; i < BANK_BYTES; i = i + 1) begin
            expected0[i] = 0;
            expected1[i] = 0;
        end

        // DS1: exactly 8192 full words and no command/response stalls.
        reset_dut; start_layer(1, 32'h11, BANK_BYTES);
        for (i = 0; i < DS1_WORDS; i = i + 1) begin
            w = 32'ha5000000 ^ i;
            expected1[i*4] = w[7:0]; expected1[i*4+1] = w[15:8];
            expected1[i*4+2] = w[23:16]; expected1[i*4+3] = w[31:24];
            send_write(1, 32'h11, i*4, w, 4'hf, (i == DS1_WORDS-1));
        end
        ds1_cycles = DS1_WORDS + write_stalls;
        if (write_stalls != 0 || write_count !== BANK_BYTES || !write_last_seen)
            $fatal(1, "DS1 continuous write failed words=%0d stalls=%0d last=%0d", write_count/4, write_stalls, write_last_seen);
        do_commit(1, 32'h11);
        if (bank1_state != 2'd1 || bank0_state != 2'd0 || bank1_epoch != 32'h11)
            $fatal(1, "DS1 atomic swap state=%0d/%0d epoch=%h", bank0_state, bank1_state, bank1_epoch);
        random_mode = 1;
        for (i = 0; i < DS1_WORDS; i = i + 1) begin
            read_and_check(1, 32'h11, i*4, expected_word(1, i*4));
        end
        random_mode = 0;

        // DS2: 4096 full words followed by partial BE writes.  The latter
        // deliberately exercise byte enables while expected bytes include
        // only selected lanes (and therefore also cover padding behavior).
        partial_bytes = 0; write_stalls = 0;
        // Continue from the DS1 commit so the opposite (old READ -> FREE)
        // bank is exercised for DS2.
        start_layer(0, 32'h22, DS2_WORDS*4 + 300);
        random_mode = 0;
        // The first DS2 write is followed immediately by reads from the
        // still-published DS1 bank.  Its write response and read response
        // therefore overlap on independent banks.
        for (k = 0; k < DS2_WORDS; k = k + 1) begin
            w = 32'h5a000000 + k*32'h01010101;
            expected0[k*4] = w[7:0]; expected0[k*4+1] = w[15:8];
            expected0[k*4+2] = w[23:16]; expected0[k*4+3] = w[31:24];
            send_write(0, 32'h22, k*4, w, 4'hf, 0);
            if (k == 0)
                for (r = 0; r < 64; r = r + 1)
                    read_and_check(1, 32'h11, r*4, expected_word(1, r*4));
        end
        for (k = 0; k < 100; k = k + 1) begin
            b = (k * 37) % DS2_WORDS;
            w = 32'he1000000 ^ (k * 32'h10203);
            // Three selected lanes per command; byte 3 remains padding.
            expected0[b*4] = w[7:0]; expected0[b*4+1] = w[15:8];
            expected0[b*4+2] = w[23:16];
            partial_bytes = partial_bytes + 3;
            send_write(0, 32'h22, b*4, w, 4'h7, (k == 99));
        end
        random_mode = 0;
        if (write_count !== DS2_WORDS*4 + partial_bytes)
            $fatal(1, "DS2 byte count got=%0d expected=%0d", write_count, DS2_WORDS*4 + partial_bytes);
        do_commit(0, 32'h22);
        if (bank0_state != 2'd1 || bank1_state != 2'd0 || bank0_epoch != 32'h22)
            $fatal(1, "DS2 atomic swap state=%0d/%0d epoch=%h", bank0_state, bank1_state, bank0_epoch);
        random_mode = 1;
        for (i = 0; i < DS2_WORDS; i = i + 1) begin
            read_and_check(0, 32'h22, i*4, expected_word(0, i*4));
        end
        random_mode = 0;

        // Invalid command coverage is run after the functional passes so the
        // sticky error indication cannot mask any data-plane failure.
        reset_dut;
        @(negedge clk); read_req_bank=0; read_req_epoch=99; read_req_addr=0; read_req_valid=1;
        @(posedge clk); @(negedge clk); read_req_valid=0; repeat (2) @(posedge clk);
        if (!error || ((error_code & 8'h02) == 0)) $fatal(1, "stale epoch was not rejected");

        reset_dut; start_layer(1, 1, 4);
        send_write(1, 1, BANK_BYTES, 32'hdeadbeef, 4'hf, 0);
        if (!error || ((error_code & 8'h10) == 0)) $fatal(1, "out-of-range write was not rejected");

        reset_dut; start_layer(1, 3, 4);
        @(negedge clk); commit_bank=1; commit_epoch=3; commit_valid=1;
        @(posedge clk); @(negedge clk); commit_valid=0; repeat (1) @(posedge clk);
        if (!error || ((error_code & 8'h20) == 0)) $fatal(1, "early commit was not rejected");

        reset_dut; start_layer(0, 4, 0);
        if (!error || ((error_code & 8'h01) == 0)) $fatal(1, "read-bank start was not rejected");

        reset_dut; start_layer(1, 5, 4);
        @(negedge clk); read_req_bank=1; read_req_epoch=5; read_req_addr=0; read_req_valid=1;
        @(posedge clk); @(negedge clk); read_req_valid=0; repeat (1) @(posedge clk);
        if (!error || ((error_code & 8'h08) == 0)) $fatal(1, "read/write same-bank was not rejected");

        $display("PASS ds12_stream_activation_banks DS1_words=%0d DS2_words=%0d DS1_write_cycles=%0d reads_checked=%0d capacity_each=%0dKiB invalid_cases=5", DS1_WORDS, DS2_WORDS, ds1_cycles, read_checks, BANK_BYTES/1024);
        $finish(0);
    end
endmodule

`default_nettype wire
