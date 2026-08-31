`timescale 1ns/1ps
`default_nettype none

// Direct runner integration proof for the compile-time unified64 DS path.
// The vector file is the same externally addressed DS workload used by the
// top-level DS test, but the descriptor is supplied directly to the runner so
// no descriptor-fetch or feature-SRAM behavior can hide a runner transaction.
module tb_cnn_layer_runner_unified64_ds;
    parameter integer USE_SHARED_ARRAY = 0;
    localparam integer MEM_WORDS = 262144;
    localparam integer MAX_EXPECTED = 8192;
    localparam integer MAX_ENTRIES = 8192;

    reg clk;
    reg rst_n;
    reg start;
    reg [1023:0] desc_words;
    wire busy;
    wire done;
    wire error;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;
    wire sram_input_rd_en;
    wire [14:0] sram_input_rd_addr;
    reg sram_input_rd_valid;
    reg signed [7:0] sram_input_rd_data;
    wire sram_input_rd_word_en;
    wire [14:0] sram_input_rd_word_addr;
    reg sram_input_rd_word_valid;
    reg [31:0] sram_input_rd_word_data;
    wire sram_output_wr_en;
    wire [14:0] sram_output_wr_addr;
    wire signed [7:0] sram_output_wr_data;
    wire sram_output_wr4_en;
    wire [14:0] sram_output_wr4_addr;
    wire [31:0] sram_output_wr4_data;
    wire [3:0] sram_output_wr4_be;

    reg [31:0] mem [0:MEM_WORDS-1];
    reg [31:0] expected_addr [0:MAX_EXPECTED-1];
    reg [7:0] expected_data [0:MAX_EXPECTED-1];
    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer timeout;
    integer cycle_count;
    integer mem_read_count;
    integer mem_write_count;
    integer nonzero_expected;
    integer nonzero_actual;
    integer errors;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;

    cnn_layer_runner #(.USE_UNIFIED64_DS(1), .USE_SHARED_UNIFIED64(USE_SHARED_ARRAY)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .desc_words(desc_words),
        .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready), .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(sram_input_rd_en),
        .sram_input_rd_addr(sram_input_rd_addr),
        .sram_input_rd_valid(sram_input_rd_valid),
        .sram_input_rd_data(sram_input_rd_data),
        .sram_input_rd_word_en(sram_input_rd_word_en),
        .sram_input_rd_word_addr(sram_input_rd_word_addr),
        .sram_input_rd_word_valid(sram_input_rd_word_valid),
        .sram_input_rd_word_data(sram_input_rd_word_data),
        .sram_output_wr_en(sram_output_wr_en),
        .sram_output_wr_addr(sram_output_wr_addr),
        .sram_output_wr_data(sram_output_wr_data),
        .sram_output_wr4_en(sram_output_wr4_en),
        .sram_output_wr4_addr(sram_output_wr4_addr),
        .sram_output_wr4_data(sram_output_wr4_data),
        .sram_output_wr4_be(sram_output_wr4_be)
    );

    always #5 clk = ~clk;

    // One-cycle response for every accepted external read, matching the
    // runner's single-outstanding memory contract.  The test intentionally
    // keeps ready high to isolate the unified64 data path first.
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_word_valid <= 1'b0;
        end else begin
            mem_resp_valid <= 1'b0;
            sram_input_rd_valid <= 1'b0;
            sram_input_rd_word_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    if (mem_write_count >= expected_count) begin
                        $display("MISMATCH extra write addr=%08x", mem_req_addr);
                        errors = errors + 1;
                    end else begin
                        if (mem_req_addr !== expected_addr[mem_write_count]) begin
                            $display("MISMATCH write[%0d] addr=%08x expected=%08x",
                                     mem_write_count, mem_req_addr,
                                     expected_addr[mem_write_count]);
                            errors = errors + 1;
                        end
                        if (mem_req_wdata[7:0] !== expected_data[mem_write_count]) begin
                            $display("MISMATCH write[%0d] data=%0d expected=%0d",
                                     mem_write_count, $signed(mem_req_wdata[7:0]),
                                     $signed(expected_data[mem_write_count]));
                            errors = errors + 1;
                        end
                        if (mem_req_wdata[7:0] != 8'd0)
                            nonzero_actual = nonzero_actual + 1;
                    end
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                    mem_write_count = mem_write_count + 1;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[19:2]];
                    mem_read_count = mem_read_count + 1;
                end
            end
        end
    end

    task reset_and_start;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start = 1'b0;
            mem_req_ready = 1'b1;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            sram_input_rd_valid = 1'b0;
            sram_input_rd_data = 8'sd0;
            sram_input_rd_word_valid = 1'b0;
            sram_input_rd_word_data = 32'd0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task wait_for_done;
        begin
            timeout = 0;
            cycle_count = 0;
            while (!done && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (busy) cycle_count = cycle_count + 1;
            end
            if (!done) begin
                $display("FAIL timeout case=%0d after=%0d cycles", case_idx, timeout);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        desc_words = 1024'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        sram_input_rd_valid = 1'b0;
        sram_input_rd_data = 8'sd0;
        sram_input_rd_word_valid = 1'b0;
        sram_input_rd_word_data = 32'd0;
        errors = 0;

        fd = $fopen("tests/vectors/cnn_top_dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("FAIL cannot open DS vector");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);
        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'd0;
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end
            nonzero_expected = 0;
            desc_words = 1024'd0;
            scan_count = $fscanf(fd, "%h %d %d %d\n", tmp_addr,
                                 layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("FAIL malformed header case=%0d", case_idx);
                $finish;
            end
            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("FAIL malformed entry case=%0d i=%0d", case_idx, i);
                    $finish;
                end
                mem[tmp_addr[19:2]] = tmp_data;
                if (i < 32) desc_words[(i*32) +: 32] = tmp_data;
            end
            for (i = 0; i < expected_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", expected_addr[i], tmp_i8);
                if (scan_count != 2) begin
                    $display("FAIL malformed expected case=%0d i=%0d", case_idx, i);
                    $finish;
                end
                expected_data[i] = tmp_i8;
                if (tmp_i8 != 8'd0) nonzero_expected = nonzero_expected + 1;
            end

            mem_read_count = 0;
            mem_write_count = 0;
            nonzero_actual = 0;
            errors = 0;
            reset_and_start();
            wait_for_done();
            $display("RESULT case=%0d cycles=%0d reads=%0d writes=%0d expected_writes=%0d nonzero=%0d error=%b",
                     case_idx, cycle_count, mem_read_count, mem_write_count,
                     expected_count, nonzero_actual, error);
            if (error) errors = errors + 1;
            if (mem_read_count != entry_count - 32) begin
                $display("MISMATCH reads=%0d expected=%0d", mem_read_count,
                         entry_count - 32);
                errors = errors + 1;
            end
            if (mem_write_count != expected_count) begin
                $display("MISMATCH writes=%0d expected=%0d", mem_write_count,
                         expected_count);
                errors = errors + 1;
            end
            if (nonzero_expected == 0 || nonzero_actual == 0) begin
                $display("MISMATCH nonzero output was not exercised");
                errors = errors + 1;
            end
            if (errors != 0) $finish;
        end
        $fclose(fd);
        $display("PASS tb_cnn_layer_runner_unified64_ds cases=%0d", num_cases);
        $finish;
    end
endmodule

`default_nettype wire
