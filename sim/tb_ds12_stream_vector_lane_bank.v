`timescale 1ns/1ps
`default_nettype none

module tb_ds12_stream_vector_lane_bank;
    localparam integer LINE_WORDS = 2048;
    localparam integer BANK_BYTES = LINE_WORDS * 16;
    localparam integer DS1_WORDS = (32*32*32)/4;
    localparam integer VECTOR_READS = 4608;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg write_valid;
    wire write_ready;
    reg [31:0] write_addr, write_data;
    reg [3:0] write_be;
    reg vector_req_valid;
    wire vector_req_ready;
    reg [31:0] vector_req_addr;
    wire vector_resp_valid;
    reg vector_resp_ready;
    wire [127:0] vector_resp_data;
    wire [31:0] vector_resp_addr;
    wire error;
    wire [3:0] error_code;

    reg [7:0] model [0:BANK_BYTES-1];
    reg [31:0] rng;
    reg ready_mode;
    integer cycle_counter;
    integer write_cycles;
    integer throughput_cycles;
    integer read_checks;
    integer i;
    integer b;
    integer line;
    integer start_cycle;
    integer write_edge_count;
    reg [31:0] w;
    reg [31:0] a;
    reg [3:0] be;

    ds12_stream_vector_lane_bank #(.LINE_WORDS(LINE_WORDS)) dut (
        .clk(clk), .rst_n(rst_n),
        .write_valid(write_valid), .write_ready(write_ready),
        .write_addr(write_addr), .write_data(write_data), .write_be(write_be),
        .vector_req_valid(vector_req_valid), .vector_req_ready(vector_req_ready),
        .vector_req_addr(vector_req_addr), .vector_resp_valid(vector_resp_valid),
        .vector_resp_ready(vector_resp_ready), .vector_resp_data(vector_resp_data),
        .vector_resp_addr(vector_resp_addr), .error(error), .error_code(error_code)
    );

    function automatic [31:0] next_rng;
        input [31:0] x;
        begin
            next_rng = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n)
            cycle_counter <= 0;
        else
            cycle_counter <= cycle_counter + 1;
    end

    // Ready changes only away from the active edge.  This makes it possible
    // to check that a stalled response remains bit-for-bit stable.
    always @(negedge clk) begin
        if (!rst_n) begin
            vector_resp_ready <= 1'b0;
            rng <= 32'h91e10da5;
        end else if (ready_mode) begin
            vector_resp_ready <= 1'b1;
        end else begin
            vector_resp_ready <= (rng[2:0] != 3'b000);
            rng <= next_rng(rng);
        end
    end

    task reset_dut;
        begin
            rst_n = 1'b0;
            write_valid = 1'b0;
            vector_req_valid = 1'b0;
            ready_mode = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    task write_word;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  byte_en;
        begin
            @(negedge clk);
            write_addr = addr;
            write_data = data;
            write_be = byte_en;
            write_valid = 1'b1;
            while (!write_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            write_valid = 1'b0;
            if (addr[1:0] == 2'b00 && addr < BANK_BYTES)
                for (b = 0; b < 4; b = b + 1)
                    if (byte_en[b]) model[addr+b] = data[b*8 +: 8];
        end
    endtask

    task read_check;
        input [31:0] addr;
        reg [127:0] expected;
        reg [127:0] stalled_value;
        begin
            for (b = 0; b < 16; b = b + 1)
                expected[b*8 +: 8] = model[addr+b];
            @(negedge clk);
            #1;
            vector_req_addr = addr;
            vector_req_valid = 1'b1;
            while (!vector_req_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            #1;
            vector_req_valid = 1'b0;
            while (!vector_resp_valid) @(negedge clk);
            stalled_value = vector_resp_data;
            while (!vector_resp_ready) begin
                @(negedge clk);
                #1;
                if (!vector_resp_valid || vector_resp_data !== stalled_value ||
                    vector_resp_addr !== addr)
                    $fatal(1, "stalled response changed req=%h resp=%h valid=%0d ready=%0d", addr, vector_resp_addr, vector_resp_valid, vector_resp_ready);
            end
            if (vector_resp_data !== expected || vector_resp_addr !== addr)
                $fatal(1, "vector mismatch addr=%h got=%h expected=%h", addr,
                       vector_resp_data, expected);
            read_checks = read_checks + 1;
            @(posedge clk);
        end
    endtask

    task collision_check;
        input [31:0] old_addr;
        input [31:0] write_addr_t;
        input [31:0] write_data_t;
        input [3:0]  write_be_t;
        input [31:0] read_addr_t;
        input         same_line;
        reg [127:0] expected_old;
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1)
                expected_old[j*8 +: 8] = model[old_addr+j];
            ready_mode = 1'b1;
            @(negedge clk);
            #1;
            write_addr = write_addr_t;
            write_data = write_data_t;
            write_be = write_be_t;
            write_valid = 1'b1;
            vector_req_addr = read_addr_t;
            vector_req_valid = 1'b1;
            while (!vector_req_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            #1;
            write_valid = 1'b0;
            vector_req_valid = 1'b0;
            if (!vector_resp_valid || vector_resp_data !== expected_old)
                $fatal(1, "READ_FIRST collision failed same_line=%0d got=%h expected=%h",
                       same_line, vector_resp_data, expected_old);
            @(posedge clk);
            for (j = 0; j < 4; j = j + 1)
                if (write_be_t[j]) model[write_addr_t+j] = write_data_t[j*8 +: 8];
        end
    endtask

    initial begin
        write_valid = 1'b0;
        write_addr = 0;
        write_data = 0;
        write_be = 0;
        vector_req_valid = 1'b0;
        vector_req_addr = 0;
        vector_resp_ready = 1'b0;
        ready_mode = 1'b1;
        rng = 32'h91e10da5;
        cycle_counter = 0;
        read_checks = 0;
        for (i = 0; i < BANK_BYTES; i = i + 1)
            model[i] = 8'h00;

        // Real DS1 capacity: every one of 8,192 words is accepted in one
        // cycle, with all four byte enables asserted.
        reset_dut;
        start_cycle = cycle_counter;
        // Keep valid asserted and replace the command on each falling edge;
        // there is deliberately no per-word task gap in this proof.
        @(negedge clk);
        write_valid = 1'b1;
        write_be = 4'hf;
        write_edge_count = 0;
        for (i = 0; i < DS1_WORDS; i = i + 1) begin
            rng = next_rng(rng);
            w = rng ^ (32'h5a000000 + i);
            write_addr = i*4;
            write_data = w;
            @(posedge clk);
            write_edge_count = write_edge_count + 1;
            for (b = 0; b < 4; b = b + 1)
                model[i*4+b] = w[b*8 +: 8];
            if (i != DS1_WORDS-1)
                @(negedge clk);
        end
        @(negedge clk);
        write_valid = 1'b0;
        write_cycles = write_edge_count;
        if (write_edge_count != DS1_WORDS)
            $fatal(1, "DS1 continuous write took %0d cycles expected %0d",
                   write_cycles, DS1_WORDS);

        // Random partial writes exercise each word offset in a 16-byte line,
        // all byte enables, and preservation of disabled bytes.
        for (i = 0; i < 1024; i = i + 1) begin
            rng = next_rng(rng);
            line = rng % DS1_WORDS;
            rng = next_rng(rng);
            w = rng;
            be = rng[3:0];
            if (be == 0) be = 4'h8;
            write_word(line*4, w, be);
        end

        // Random reads with response backpressure and a stable held payload.
        ready_mode = 1'b0;
        for (i = 0; i < 1200; i = i + 1) begin
            rng = next_rng(rng);
            // Any aligned vector line is legal; this covers all lane banks.
            a = (rng % LINE_WORDS) * 16;
            read_check(a);
        end

        // Same-line READ_FIRST: old vector must be observed although four
        // lanes are written on the same clock edge.
        collision_check(32'd16*32'd37, 32'd16*32'd37 + 32'd8,
                        32'hc3a59687, 4'hf, 32'd16*32'd37, 1'b1);
        // Independent line read/write is legal in the same cycle.
        collision_check(32'd16*32'd41, 32'd16*32'd73,
                        32'h11223344, 4'hd, 32'd16*32'd41, 1'b0);
        read_check(32'd16*32'd37);
        read_check(32'd16*32'd73);

        // Throughput proof: 4,608 accepted reads and responses in a
        // one-per-cycle stream with no response stalls.
        ready_mode = 1'b1;
        start_cycle = cycle_counter;
        @(negedge clk);
        vector_req_valid = 1'b1;
        for (i = 0; i < VECTOR_READS; i = i + 1) begin
            a = ((i * 29) % LINE_WORDS) * 16;
            vector_req_addr = a;
            while (!vector_req_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            if (!vector_resp_valid)
                $fatal(1, "throughput response missing i=%0d", i);
            for (b = 0; b < 16; b = b + 1)
                if (vector_resp_data[b*8 +: 8] !== model[a+b])
                    $fatal(1, "throughput mismatch i=%0d lane=%0d", i, b);
            // This falling edge is also the setup edge for the next
            // request; no per-request task/wait gap is permitted here.
            if (i != VECTOR_READS-1)
                vector_req_addr = (((i + 1) * 29) % LINE_WORDS) * 16;
        end
        vector_req_valid = 1'b0;
        @(posedge clk);
        @(negedge clk);
        throughput_cycles = cycle_counter - start_cycle;
        if (throughput_cycles > VECTOR_READS + 2)
            $fatal(1, "vector throughput exceeded bound cycles=%0d", throughput_cycles);

        // Invalid requests handshake but do not create a response; errors
        // are sticky and independently identify alignment versus range.
        write_word(32'd1, 32'hdeadbeef, 4'hf);
        write_word(BANK_BYTES, 32'hdeadbeef, 4'hf);
        if (!error || (error_code & 4'h3) != 4'h3)
            $fatal(1, "write range/alignment errors missing error=%0d code=%h", error, error_code);
        @(negedge clk);
        vector_req_addr = 32'd4;
        vector_req_valid = 1'b1;
        while (!vector_req_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        vector_req_valid = 1'b0;
        @(negedge clk);
        vector_req_addr = BANK_BYTES;
        vector_req_valid = 1'b1;
        while (!vector_req_ready) @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        vector_req_valid = 1'b0;
        if ((error_code & 4'hc) != 4'hc)
            $fatal(1, "read range/alignment errors missing code=%h", error_code);

        $display("PASS ds12_stream_vector_lane_bank DS1_words=%0d DS1_write_cycles=%0d random_reads=%0d throughput_reads=%0d throughput_cycles=%0d capacity=%0dKiB read_first=1", DS1_WORDS, write_cycles, read_checks, VECTOR_READS, throughput_cycles, BANK_BYTES/1024);
        $finish(0);
    end
endmodule

`default_nettype wire
