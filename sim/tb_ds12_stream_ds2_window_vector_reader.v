`timescale 1ns/1ps
`default_nettype none

// Candidate integration proof: the DS1 activation is written as real 32-bit
// transactions into store bank B, committed/swapped, and then consumed by
// the vector reader as registered 128-bit active-bank responses.
module tb_ds12_stream_ds2_window_vector_reader;
    localparam integer LINE_WORDS = 2048;
    localparam integer BANK_BYTES = LINE_WORDS * 16;
    localparam integer WINDOWS = 16 * 16;
    localparam integer VECTORS_PER_WINDOW = 18;
    localparam integer TOTAL_VECTORS = WINDOWS * VECTORS_PER_WINDOW;
    localparam integer VALID_VECTORS = 4418;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg start_valid, start_bank, start_last;
    reg [5:0] start_row, start_col;
    reg [31:0] start_epoch;
    wire start_ready;
    wire win_valid;
    reg win_ready;
    wire [127:0] win_data;
    wire [5:0] win_row, win_col;
    wire [1:0] win_tap_row, win_tap_col, win_context;
    wire win_slice, win_owner, win_last;
    wire [31:0] win_epoch;
    wire read_req_valid, read_req_ready, read_req_bank;
    wire [31:0] read_req_epoch, read_req_addr;
    wire read_resp_valid, reader_read_resp_ready, read_resp_bank;
    wire [127:0] read_resp_data;
    wire [31:0] read_resp_epoch, read_resp_addr;
    wire busy;
    wire [3:0] context_active, context_peak;
    wire [31:0] read_count, window_count;
    wire reader_error;
    wire [7:0] reader_error_code;

    reg bank_start_valid, bank_start_bank;
    reg [31:0] bank_start_epoch, bank_start_expected;
    wire bank_start_ready;
    reg bank_write_valid, bank_write_bank, bank_write_last;
    reg [31:0] bank_write_epoch, bank_write_addr, bank_write_data;
    reg [3:0] bank_write_be;
    wire bank_write_ready, bank_write_resp_valid;
    reg bank_write_resp_ready;
    reg bank_commit_valid, bank_commit_bank;
    reg [31:0] bank_commit_epoch;
    wire bank_commit_ready, bank_commit_done, atomic_swap;
    wire read_store_resp_valid, read_store_resp_bank;
    wire read_store_resp_ready;
    wire [127:0] read_store_resp_data;
    wire [31:0] read_store_resp_epoch, read_store_resp_addr;
    wire [31:0] reader_store_resp_epoch;
    wire [1:0] bank0_state, bank1_state;
    wire [31:0] bank0_epoch, bank1_epoch;
    wire bank_active_read_bank, bank_active_write;
    wire [31:0] bank_active_read_epoch, bank_write_count;
    wire bank_write_last_seen;
    wire bank_error;
    wire [7:0] bank_error_code;
    reg response_enable;
    assign read_store_resp_ready = reader_read_resp_ready && response_enable;
    assign reader_store_resp_epoch = bad_epoch_mode ? (read_store_resp_epoch ^ 32'h1) : read_store_resp_epoch;

    reg [7:0] expected [0:BANK_BYTES-1];
    integer i, b, iy, ix, ch, pixel, expected_byte;
    integer cycles, perf_start_cycle, perf_cycles, vectors_seen, windows_seen;
    integer physical_reads, perf_logical_reads, perf_physical_reads, mismatches, random_vectors;
    reg seen [0:WINDOWS-1][0:8][0:1];
    reg [31:0] lfsr;
    reg random_mode, bad_epoch_mode;
    reg stall_seen;
    reg [127:0] held_data;
    reg [5:0] held_row, held_col;
    reg [1:0] held_tap_row, held_tap_col, held_context;
    reg held_slice, held_owner;
    reg [31:0] held_epoch;

    ds12_stream_dual_vector_activation_store #(.LINE_WORDS(LINE_WORDS)) store (
        .clk(clk), .rst_n(rst_n),
        .layer_start_valid(bank_start_valid), .layer_start_ready(bank_start_ready),
        .layer_start_bank(bank_start_bank), .layer_start_epoch(bank_start_epoch),
        .layer_start_expected_words(bank_start_expected),
        .write_valid(bank_write_valid), .write_ready(bank_write_ready),
        .write_bank(bank_write_bank), .write_epoch(bank_write_epoch),
        .write_addr(bank_write_addr), .write_data(bank_write_data),
        .write_be(bank_write_be), .write_last(bank_write_last),
        .write_resp_valid(bank_write_resp_valid), .write_resp_ready(bank_write_resp_ready),
        .write_resp_bank(), .write_resp_epoch(), .write_resp_addr(),
        .layer_end_valid(1'b0), .layer_end_ready(), .layer_end_bank(1'b0),
        .layer_end_epoch(32'd0), .commit_valid(bank_commit_valid),
        .commit_ready(bank_commit_ready), .commit_bank(bank_commit_bank),
        .commit_epoch(bank_commit_epoch), .commit_done(bank_commit_done),
        .layer_end_done(), .atomic_swap(atomic_swap),
        .read_req_valid(read_req_valid), .read_req_ready(read_req_ready),
        .read_req_bank(read_req_bank), .read_req_epoch(read_req_epoch),
        .read_req_addr(read_req_addr), .read_resp_valid(read_store_resp_valid),
        .read_resp_ready(read_store_resp_ready), .read_resp_data(read_store_resp_data),
        .read_resp_bank(read_store_resp_bank), .read_resp_epoch(read_store_resp_epoch),
        .read_resp_addr(read_store_resp_addr), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
        .active_read_bank(bank_active_read_bank), .active_read_epoch(bank_active_read_epoch),
        .active_write(bank_active_write), .active_write_bank(), .write_epoch_active(),
        .write_count(bank_write_count), .write_expected_words(), .write_last_seen(bank_write_last_seen),
        .error(bank_error), .error_code(bank_error_code)
    );

    ds12_stream_ds2_window_vector_reader #(.CONTEXTS(4)) dut (
        .clk(clk), .rst_n(rst_n), .window_start_valid(start_valid),
        .window_start_ready(start_ready), .window_start_row(start_row),
        .window_start_col(start_col), .window_start_bank(start_bank),
        .window_start_epoch(start_epoch), .window_start_last(start_last),
        .window_valid(win_valid), .window_ready(win_ready), .window_data(win_data),
        .window_row(win_row), .window_col(win_col), .window_tap_row(win_tap_row),
        .window_tap_col(win_tap_col), .window_channel_slice(win_slice),
        .window_context(win_context), .window_owner(win_owner), .window_epoch(win_epoch),
        .window_last(win_last), .read_req_valid(read_req_valid),
        .read_req_ready(read_req_ready), .read_req_bank(read_req_bank),
        .read_req_epoch(read_req_epoch), .read_req_addr(read_req_addr),
        .read_resp_valid(read_store_resp_valid), .read_resp_ready(reader_read_resp_ready),
        .read_resp_data(read_store_resp_data), .read_resp_bank(read_store_resp_bank),
        .read_resp_epoch(reader_store_resp_epoch), .read_resp_addr(read_store_resp_addr),
        .busy(busy), .context_active(context_active), .context_peak(context_peak),
        .read_count(read_count), .window_count(window_count), .error(reader_error),
        .error_code(reader_error_code)
    );

    function automatic [31:0] next_rng;
        input [31:0] x;
        begin next_rng = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]}; end
    endfunction

    task reset_main;
        begin
            rst_n = 1'b0; start_valid = 0; bank_start_valid = 0;
            bank_write_valid = 0; bank_commit_valid = 0;
            response_enable = 1'b1; random_mode = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    task start_bank_layer;
        begin
            @(negedge clk); bank_start_bank = 1'b1; bank_start_epoch = 32'h11;
            bank_start_expected = 8192; bank_start_valid = 1'b1;
            while (!bank_start_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); bank_start_valid = 1'b0;
        end
    endtask

    task send_write;
        input integer wi;
        begin
            @(negedge clk); bank_write_bank = 1'b1; bank_write_epoch = 32'h11;
            bank_write_addr = wi * 4; bank_write_data = 0;
            bank_write_data[7:0] = expected[wi*4];
            bank_write_data[15:8] = expected[wi*4+1];
            bank_write_data[23:16] = expected[wi*4+2];
            bank_write_data[31:24] = expected[wi*4+3];
            bank_write_be = 4'hf; bank_write_last = (wi == 8191);
            bank_write_valid = 1'b1;
            while (!bank_write_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); bank_write_valid = 1'b0;
        end
    endtask

    task commit_bank_layer;
        begin
            while (bank_write_resp_valid) @(posedge clk);
            @(negedge clk); bank_commit_bank = 1'b1; bank_commit_epoch = 32'h11;
            bank_commit_valid = 1'b1;
            while (!bank_commit_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); bank_commit_valid = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task start_window;
        input integer r, c;
        begin
            @(negedge clk); start_row = r; start_col = c; start_bank = 1'b1;
            start_epoch = 32'h11; start_last = (r == 15 && c == 15);
            start_valid = 1'b1;
            while (!start_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); start_valid = 1'b0;
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'hd1c0ffee;
            response_enable <= 1'b1;
            win_ready <= 1'b1;
        end else if (random_mode) begin
            lfsr <= next_rng(lfsr);
            response_enable <= (lfsr[3:0] != 0);
            win_ready <= (lfsr[7:5] != 0);
        end else response_enable <= 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (read_req_valid && read_req_ready) physical_reads = physical_reads + 1;
            if (win_valid && win_ready) begin
                if (win_row >= 16 || win_col >= 16 || win_tap_row >= 3 || win_tap_col >= 3)
                    mismatches = mismatches + 1;
                else begin
                    pixel = win_row * 16 + win_col;
                    if (!random_mode) begin
                        if (seen[pixel][win_tap_row*3+win_tap_col][win_slice]) mismatches = mismatches + 1;
                        seen[pixel][win_tap_row*3+win_tap_col][win_slice] = 1'b1;
                    end
                    iy = win_row * 2 + win_tap_row - 1;
                    ix = win_col * 2 + win_tap_col - 1;
                    for (b = 0; b < 16; b = b + 1) begin
                        ch = win_slice * 16 + b;
                        if (iy < 0 || iy >= 32 || ix < 0 || ix >= 32)
                            expected_byte = 0;
                        else expected_byte = expected[(iy * 32 + ix) * 32 + ch];
                        if (win_data[b*8 +: 8] !== expected_byte[7:0]) mismatches = mismatches + 1;
                    end
                    if (win_owner !== 1'b1 || win_epoch !== 32'h11 || win_context > 3)
                        mismatches = mismatches + 1;
                    vectors_seen = vectors_seen + 1;
                    if (win_last !== (win_row == 15 && win_col == 15 && win_tap_row == 2 && win_tap_col == 2 && win_slice))
                        mismatches = mismatches + 1;
                end
            end
            if (random_mode && win_valid && !win_ready) begin
                if (stall_seen && (win_data !== held_data || win_row !== held_row || win_col !== held_col ||
                    win_tap_row !== held_tap_row || win_tap_col !== held_tap_col || win_slice !== held_slice ||
                    win_owner !== held_owner || win_epoch !== held_epoch || win_context !== held_context))
                    mismatches = mismatches + 1;
                held_data = win_data; held_row = win_row; held_col = win_col;
                held_tap_row = win_tap_row; held_tap_col = win_tap_col; held_slice = win_slice;
                held_owner = win_owner; held_epoch = win_epoch; held_context = win_context;
                stall_seen = 1'b1;
            end else if (win_valid && win_ready) stall_seen = 1'b0;
        end
    end

    initial begin
        cycles = 0; vectors_seen = 0; windows_seen = 0; physical_reads = 0;
        mismatches = 0; lfsr = 32'hd1c0ffee; stall_seen = 0; bad_epoch_mode = 1'b0;
        start_valid = 0; start_bank = 0; start_epoch = 0; start_last = 0;
        bank_start_valid = 0; bank_start_bank = 0; bank_start_epoch = 0; bank_start_expected = 0;
        bank_write_valid = 0; bank_write_bank = 0; bank_write_epoch = 0; bank_write_addr = 0;
        bank_write_data = 0; bank_write_be = 0; bank_write_last = 0; bank_write_resp_ready = 1;
        bank_commit_valid = 0; bank_commit_bank = 0; bank_commit_epoch = 0; response_enable = 1;
        for (i = 0; i < BANK_BYTES; i = i + 1) expected[i] = 0;
        for (i = 0; i < WINDOWS; i = i + 1)
            for (b = 0; b < 9; b = b + 1) begin seen[i][b][0] = 0; seen[i][b][1] = 0; end
        $readmemh("build/ds12_stream_ds2_window_vector_reader/ds12_stream_ds1_output_i8.hex", expected);

        reset_main;
        start_bank_layer;
        for (i = 0; i < 8192; i = i + 1) send_write(i);
        if (bank_write_count !== 8192 || !bank_write_last_seen)
            $fatal(1, "DS1 store load failed count=%0d last=%0d", bank_write_count, bank_write_last_seen);
        commit_bank_layer;
        if (bank1_state !== 2'd1 || bank1_epoch !== 32'h11 || bank_error)
            $fatal(1, "store commit failed state=%0d epoch=%h err=%0d code=%h", bank1_state, bank1_epoch, bank_error, bank_error_code);

        perf_start_cycle = cycles;
        for (i = 0; i < WINDOWS; i = i + 1) start_window(i / 16, i % 16);
        while (vectors_seen < TOTAL_VECTORS) begin
            if (cycles - perf_start_cycle > 10000) $fatal(1, "vector reader timeout vectors=%0d", vectors_seen);
            @(posedge clk);
        end
        perf_cycles = cycles - perf_start_cycle;
        perf_logical_reads = read_count;
        perf_physical_reads = physical_reads;
        for (i = 0; i < WINDOWS; i = i + 1)
            for (b = 0; b < 9; b = b + 1)
                if (!seen[i][b][0] || !seen[i][b][1]) mismatches = mismatches + 1;
        if (read_count !== TOTAL_VECTORS || physical_reads !== VALID_VECTORS ||
            window_count !== TOTAL_VECTORS || perf_cycles > 5000 || mismatches != 0 || reader_error || bank_error)
            $fatal(1, "FAIL vectors=%0d logical_reads=%0d physical_reads=%0d windows=%0d cycles=%0d mismatches=%0d rerr=%0d/%h berr=%0d/%h",
                   vectors_seen, read_count, physical_reads, window_count, perf_cycles, mismatches,
                   reader_error, reader_error_code, bank_error, bank_error_code);

        // One additional window with randomized store response stalls and
        // output stalls checks elastic/stable registered transactions.
        random_mode = 1'b1;
        start_window(0, 0);
        while (window_count < TOTAL_VECTORS + 18) begin
            if (cycles > perf_start_cycle + 20000) $fatal(1, "random stall timeout");
            @(posedge clk);
        end
        random_mode = 1'b0;
        if (reader_error || bank_error || mismatches != 0)
            $fatal(1, "random stall failure rerr=%0d/%h berr=%0d/%h mismatches=%0d", reader_error, reader_error_code, bank_error, bank_error_code, mismatches);

        // Corrupt only the returned epoch tag for a final randomized vector;
        // the reader must flag the stale response without losing its stream.
        bad_epoch_mode = 1'b1;
        random_mode = 1'b1;
        start_window(0, 0);
        while (!reader_error) begin
            if (cycles > perf_start_cycle + 22000) $fatal(1, "epoch invalid timeout");
            @(posedge clk);
        end
        random_mode = 1'b0;
        if (!(reader_error_code & 8'h02) || bank_error || mismatches != 0)
            $fatal(1, "epoch invalid check failed rerr=%0d/%h berr=%0d/%h mismatches=%0d", reader_error, reader_error_code, bank_error, bank_error_code, mismatches);

        $display("PASS ds12_stream_ds2_window_vector_reader windows=%0d vectors=%0d bytes_checked=%0d logical_reads=%0d physical_vector_reads=%0d cycles=%0d context_peak=%0d no_backpressure=1 random_response_output_stalls=1 epoch_invalid=PASS padding=PASS bank_epoch=%h",
                 WINDOWS, TOTAL_VECTORS, TOTAL_VECTORS*16, perf_logical_reads, perf_physical_reads, perf_cycles, context_peak, bank1_epoch);
        $finish(0);
    end
endmodule

`default_nettype wire
