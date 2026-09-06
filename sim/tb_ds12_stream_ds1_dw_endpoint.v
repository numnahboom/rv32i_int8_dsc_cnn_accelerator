`timescale 1ns/1ps
`default_nettype none

// Directed acceptance TB for ds12_stream_ds1_dw_endpoint.  It uses the real
// C0 DS1 feature/parameter files emitted by ds12_stream_reference.py, checks
// every output byte and tag, and runs both a one-cycle bank and delayed/random
// ready/valid transaction schedule.
module tb_ds12_stream_ds1_dw_endpoint;
    localparam integer PIXELS = 1024;
    localparam integer BYTES_PER_PIXEL = 16;
    localparam integer CFG_WORDS = 84;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg start;
    reg cfg_valid;
    reg [31:0] cfg_data;
    reg cfg_last;
    wire ready;
    wire cfg_ready;
    wire mem_req_valid;
    reg mem_req_ready;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [127:0] mem_req_wdata;
    wire [15:0] mem_req_strb;
    wire [1:0] mem_req_context;
    wire mem_req_owner;
    wire [31:0] mem_req_epoch;
    reg mem_resp_valid;
    reg [127:0] mem_resp_rdata;
    wire dw_valid;
    reg dw_ready;
    wire [127:0] dw_data;
    wire [5:0] dw_row;
    wire [9:0] dw_pixel;
    wire [1:0] dw_context;
    wire dw_owner;
    wire [31:0] dw_epoch;
    wire dw_last;
    wire done;
    wire error;
    wire [31:0] input_read_count;
    wire [31:0] padding_tap_count;
    wire [31:0] dw_mac_count;
    wire [3:0] context_peak;

    reg [7:0] input_bytes [0:16383];
    reg [7:0] expected_bytes [0:16383];
    reg [31:0] cfg_words [0:CFG_WORDS-1];
    reg mem_pending;
    reg [31:0] mem_pending_addr;
    integer mem_delay;
    integer response_mode;
    integer ready_mode;
    integer lfsr;
    integer out_lfsr;
    integer outputs_seen;
    integer output_errors;
    integer tag_errors;
    integer input_req_seen;
    integer cycles;
    integer max_cycles;
    integer i;
    integer j;
    integer fd;
    integer rc;
    integer layer;
    integer kind;
    integer index;
    integer address;
    integer mask;
    integer data_word;
    integer hold_count;
    reg [127:0] held_data;
    reg [9:0] held_pixel;

    ds12_stream_ds1_dw_endpoint dut (
        .clk(clk), .rst_n(rst_n), .start(start), .ready(ready),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_data(cfg_data), .cfg_last(cfg_last),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata), .mem_req_strb(mem_req_strb),
        .mem_req_context(mem_req_context), .mem_req_owner(mem_req_owner), .mem_req_epoch(mem_req_epoch),
        .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data), .dw_row(dw_row), .dw_pixel(dw_pixel),
        .dw_context(dw_context), .dw_owner(dw_owner), .dw_epoch(dw_epoch), .dw_last(dw_last),
        .done(done), .error(error), .input_read_count(input_read_count), .padding_tap_count(padding_tap_count),
        .dw_mac_count(dw_mac_count), .context_peak(context_peak)
    );

    initial begin
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_input_i8.hex", input_bytes);
        $readmemh("build/ds12_stream_harness/ds12_stream_ds1_dw_output_i8.hex", expected_bytes);
        fd = $fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex", "r");
        if (fd == 0) $fatal(1, "missing generated DS12 config stream");
        i = 0;
        while (!$feof(fd) && i < CFG_WORDS) begin
            rc = $fscanf(fd, "%d %d %d %h %h %h\n", layer, kind, index, address, mask, data_word);
            if (rc == 6 && layer == 1) begin
                cfg_words[i] = data_word;
                i = i + 1;
            end
        end
        $fclose(fd);
        if (i != CFG_WORDS) $fatal(1, "DS1 config stream only has %0d words", i);
    end

    // One outstanding request models a synchronous bank with either a fixed
    // one-cycle response or a bounded, pseudo-random response delay.
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_pending <= 1'b0;
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 0;
            input_req_seen <= 0;
            lfsr = 32'h1;
        end else begin
            mem_resp_valid <= 1'b0;
            if (mem_pending) begin
                if (mem_delay > 0)
                    mem_delay = mem_delay - 1;
                else begin
                    mem_resp_rdata <= 128'd0;
                    for (j = 0; j < BYTES_PER_PIXEL; j = j + 1)
                        mem_resp_rdata[(j*8) +: 8] <= input_bytes[mem_pending_addr + j];
                    mem_resp_valid <= 1'b1;
                    mem_pending <= 1'b0;
                end
            end else if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write || mem_req_strb != 0 || mem_req_addr[3:0] != 0)
                    $fatal(1, "invalid feature memory request");
                if (mem_req_addr >= 16384)
                    $fatal(1, "feature memory address out of range %0d", mem_req_addr);
                if (mem_req_addr !== (input_req_seen * BYTES_PER_PIXEL) ||
                    mem_req_context !== ((input_req_seen / 8) & 3) ||
                    mem_req_owner !== ((input_req_seen / 8) & 1) ||
                    mem_req_epoch !== ((input_req_seen / 8) / 2))
                    $fatal(1, "feature request tag/address mismatch n=%0d addr=%0d ctx=%0d owner=%0d epoch=%0d", input_req_seen, mem_req_addr, mem_req_context, mem_req_owner, mem_req_epoch);
                mem_pending_addr <= mem_req_addr;
                mem_pending <= 1'b1;
                input_req_seen <= input_req_seen + 1;
                if (response_mode == 0)
                    mem_delay = 0;
                else begin
                    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                    mem_delay = (lfsr & 3) + 1;
                end
            end
        end
    end

    always @(*) begin
        if (ready_mode == 0)
            dw_ready = 1'b1;
        else
            dw_ready = out_lfsr[2] | out_lfsr[5];
    end

    // Change output readiness only between active clock edges so the DUT and
    // monitor observe the same handshake value.
    always @(negedge clk) begin
        if (rst_n && ready_mode != 0)
            out_lfsr = {out_lfsr[30:0], out_lfsr[31] ^ out_lfsr[21] ^ out_lfsr[1] ^ out_lfsr[0]};
    end

    task configure_and_start;
        begin
            cfg_valid = 1'b0; cfg_data = 0; cfg_last = 1'b0; start = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            for (i = 0; i < CFG_WORDS; i = i + 1) begin
                @(negedge clk);
                cfg_valid = 1'b1;
                cfg_data = cfg_words[i];
                cfg_last = (i == CFG_WORDS-1);
                while (!cfg_ready) @(negedge clk);
                @(posedge clk);
            end
            $display("CFG_CHECK w00=%0d bias0=%0d mul0=%0d sh0=%0d", dut.dw_weight[0][0], dut.dw_bias[0], dut.dw_multiplier[0], dut.dw_shift[0]);
            @(negedge clk); cfg_valid = 1'b0; cfg_last = 1'b0; start = 1'b1;
            @(posedge clk);
            @(negedge clk); start = 1'b0;
        end
    endtask

    task run_case;
        input integer case_response_mode;
        input integer case_ready_mode;
        begin
            response_mode = case_response_mode;
            ready_mode = case_ready_mode;
            rst_n = 1'b0;
            mem_req_ready = 1'b1;
            mem_pending = 1'b0;
            outputs_seen = 0;
            output_errors = 0;
            tag_errors = 0;
            cycles = 0;
            hold_count = 0;
            lfsr = 32'h1;
            out_lfsr = 32'h1;
            configure_and_start;
            while (!done && cycles < 1000000) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (dw_valid && dw_ready) begin
                    if (dw_pixel !== outputs_seen[9:0] || dw_row !== (outputs_seen / 32) ||
                        dw_context !== ((outputs_seen / 8) & 3) || dw_owner !== ((outputs_seen / 8) & 1) ||
                        dw_epoch !== ((outputs_seen / 8) / 2))
                        tag_errors = tag_errors + 1;
                    for (j = 0; j < BYTES_PER_PIXEL; j = j + 1)
                        if (dw_data[(j*8) +: 8] !== expected_bytes[outputs_seen*BYTES_PER_PIXEL+j]) begin
                            output_errors = output_errors + 1;
                            if (output_errors < 4)
                                $display("MISMATCH pixel=%0d chan=%0d got=%02x exp=%02x", outputs_seen, j, dw_data[(j*8) +: 8], expected_bytes[outputs_seen*BYTES_PER_PIXEL+j]);
                        end
                    if (dw_last !== (outputs_seen == PIXELS-1)) tag_errors = tag_errors + 1;
                    outputs_seen = outputs_seen + 1;
                end
                if (dw_valid && !dw_ready) begin
                    if (hold_count != 0 && (dw_data !== held_data || dw_pixel !== held_pixel))
                        tag_errors = tag_errors + 1;
                    held_data = dw_data; held_pixel = dw_pixel; hold_count = hold_count + 1;
                end else hold_count = 0;
            end
            if (!done) $fatal(1, "case timed out");
            if (outputs_seen != PIXELS || output_errors != 0 || tag_errors != 0 || error)
                $fatal(1, "DS1 DW mismatch outputs=%0d byte_errors=%0d tag_errors=%0d error=%0d", outputs_seen, output_errors, tag_errors, error);
            if (input_read_count != 1024 || input_req_seen != 1024 || padding_tap_count != 380 ||
                dw_mac_count != 147456 || context_peak != 4)
                $fatal(1, "ledger mismatch reads=%0d req=%0d padding=%0d mac=%0d peak=%0d", input_read_count, input_req_seen, padding_tap_count, dw_mac_count, context_peak);
            if (case_response_mode == 0 && case_ready_mode == 0 && cycles > 10000)
                $fatal(1, "no-backpressure cycle gate failed: %0d", cycles);
            $display("DS12_DW_CASE_PASS response_mode=%0d ready_mode=%0d cycles=%0d vectors=%0d reads=%0d padding=%0d mac=%0d context_peak=%0d", case_response_mode, case_ready_mode, cycles, outputs_seen, input_read_count, padding_tap_count, dw_mac_count, context_peak);
        end
    endtask

    initial begin
        response_mode = 0; ready_mode = 0; mem_req_ready = 1'b1;
        mem_pending = 1'b0; mem_resp_valid = 1'b0; mem_resp_rdata = 0;
        start = 1'b0; cfg_valid = 1'b0; cfg_data = 0; cfg_last = 1'b0;
        run_case(0, 0);
        run_case(1, 1);
        $display("DS12_DW_ENDPOINT_PASS bit_exact=1 backpressure=1 same_padding=1 response_delay=stable");
        $finish(0);
    end
endmodule

`default_nettype wire
