`timescale 1ns/1ps
`default_nettype none

/*
 * Focused protocol regression for ds_word_window_fill_engine's elastic
 * request entry.  The source model deliberately combines request-ready
 * bubbles, delayed responses, and a stalled destination so the descriptor
 * FIFO reaches full.  The scoreboard checks the accepted request address and
 * descriptor index independently; a moving issue counter cannot satisfy it
 * when the queue is held.
 */
module tb_ds_word_window_fill_engine_request_queue;
    localparam integer NWORDS = 40;
    localparam [23:0] BASE = 24'h001003;
    localparam [23:0] BASE_ALIGNED = 24'h001000;

    reg clk = 1'b0;
    always #1 clk = ~clk;

    reg rst_n = 1'b0;
    reg start_valid = 1'b0;
    wire start_ready;
    reg [3:0] start_bank = 4'd3;
    reg [3:0] start_epoch = 4'h9;
    reg [23:0] start_base_addr = BASE;
    reg [15:0] start_word_count = NWORDS;
    wire done_valid;
    reg done_ready = 1'b0;
    wire done_bank;
    wire [3:0] done_epoch;
    wire mem_req_valid;
    reg mem_req_ready = 1'b0;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_data = 32'd0;
    wire mem_resp_ready;
    wire wr_valid;
    reg wr_ready = 1'b0;
    wire [9:0] wr_vector_addr;
    wire [1:0] wr_quarter;
    wire [31:0] wr_data;
    wire [3:0] wr_epoch;
    wire busy;
    wire [31:0] issue_count, response_count, write_count, stale_response_count;

    ds_word_window_fill_engine #(
        .ADDR_WIDTH(24), .VECTOR_ADDR_WIDTH(10), .WORD_COUNT_WIDTH(16),
        .FIFO_DEPTH(8), .EPOCH_WIDTH(4)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_bank(start_bank), .start_epoch(start_epoch),
        .start_base_addr(start_base_addr), .start_word_count(start_word_count),
        .done_valid(done_valid), .done_ready(done_ready),
        .done_bank(done_bank), .done_epoch(done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .mem_resp_ready(mem_resp_ready),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_vector_addr(wr_vector_addr), .wr_quarter(wr_quarter),
        .wr_data(wr_data), .wr_epoch(wr_epoch), .busy(busy),
        .issue_count(issue_count), .response_count(response_count),
        .write_count(write_count), .stale_response_count(stale_response_count)
    );

    integer sim_cycle = 0;
    integer errors = 0;
    integer req_seen = 0;
    integer resp_seen = 0;
    integer wr_seen = 0;
    integer pending_count = 0;
    integer pending_wr_ptr = 0;
    integer pending_rd_ptr = 0;
    integer pending_addr [0:255];
    integer pending_due [0:255];
    reg presented_stalled = 1'b0;
    reg [23:0] stalled_addr = 24'd0;
    wire req_fire = mem_req_valid && mem_req_ready;
    wire resp_fire = mem_resp_valid && mem_resp_ready;
    wire wr_fire = wr_valid && wr_ready;

    /* Independent request/response source.  A response remains asserted
     * until the fill engine accepts it, matching a normal ready/valid SRAM
     * shim and exercising the queue-full fence. */
    always @* begin
        mem_req_ready = rst_n && ((sim_cycle % 7) != 2) && ((sim_cycle % 13) != 6);
        wr_ready = rst_n && ((sim_cycle % 9) != 3) && ((sim_cycle % 11) != 5);
        mem_resp_valid = (pending_count != 0) &&
                         (pending_due[pending_rd_ptr] <= sim_cycle);
        mem_resp_data = (pending_count != 0) ? pending_addr[pending_rd_ptr] : 0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sim_cycle = 0;
            pending_count = 0;
            pending_wr_ptr = 0;
            pending_rd_ptr = 0;
        end else begin
            sim_cycle = sim_cycle + 1;

            if (mem_req_valid && !mem_req_ready) begin
                if (presented_stalled && mem_req_addr !== stalled_addr) begin
                    $display("REQUEST_CHANGED_WHILE_STALLED cycle=%0d got=%h exp=%h",
                             sim_cycle, mem_req_addr, stalled_addr);
                    errors = errors + 1;
                end
                presented_stalled = 1'b1;
                stalled_addr = mem_req_addr;
            end else begin
                presented_stalled = 1'b0;
            end

            if (req_fire) begin
                if (mem_req_addr !== (BASE_ALIGNED + req_seen*4)) begin
                    $display("REQUEST_ORDER_ERROR n=%0d got=%h exp=%h",
                             req_seen, mem_req_addr, BASE_ALIGNED + req_seen*4);
                    errors = errors + 1;
                end
                pending_addr[pending_wr_ptr] = mem_req_addr;
                pending_due[pending_wr_ptr] = sim_cycle + 5;
                pending_wr_ptr = (pending_wr_ptr + 1) & 255;
                pending_count = pending_count + 1;
                req_seen = req_seen + 1;
            end

            if (resp_fire) begin
                pending_rd_ptr = (pending_rd_ptr + 1) & 255;
                pending_count = pending_count - 1;
                resp_seen = resp_seen + 1;
            end

            if (wr_fire) begin
                if (wr_vector_addr !== (wr_seen >> 2) ||
                    wr_quarter !== (wr_seen & 3) ||
                    wr_data !== (BASE_ALIGNED + wr_seen*4) ||
                    wr_epoch !== start_epoch) begin
                    $display("WRITE_DESCRIPTOR_ERROR n=%0d addr=%0d q=%0d data=%h epoch=%h",
                             wr_seen, wr_vector_addr, wr_quarter, wr_data, wr_epoch);
                    errors = errors + 1;
                end
                wr_seen = wr_seen + 1;
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start_valid = 1'b1;
        begin : wait_start
            while (1) begin
                @(posedge clk);
                if (start_ready) disable wait_start;
            end
        end
        @(negedge clk);
        start_valid = 1'b0;

        while (!done_valid) @(negedge clk);
        if (done_bank !== start_bank[0] || done_epoch !== start_epoch)
            errors = errors + 1;
        if (req_seen != NWORDS || resp_seen != NWORDS || wr_seen != NWORDS)
            errors = errors + 1;
        done_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        if (errors == 0)
            $display("PASS fill_engine_request_queue words=%0d requests=%0d responses=%0d writes=%0d cycles=%0d",
                     NWORDS, req_seen, resp_seen, wr_seen, sim_cycle);
        else begin
            $display("FAIL fill_engine_request_queue errors=%0d requests=%0d responses=%0d writes=%0d",
                     errors, req_seen, resp_seen, wr_seen);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule

`default_nettype wire
