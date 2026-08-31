`timescale 1ns/1ps
`default_nettype none

/* Native-source model and external readback check for ds_tile_dma_writer. */
module tb_ds_tile_dma_writer #(
    parameter integer TEST_CIN = 48,
    parameter integer TEST_EXTENT_OVERRIDE = 0,
    parameter integer TEST_BASE_OVERRIDE = -1
);
    localparam integer PIXELS = 100;
    localparam integer DEFAULT_EXTENT = (TEST_CIN == 3) ? 299 :
                                        (TEST_CIN == 16) ? 1597 : 4799;
    localparam integer EXTENT = (TEST_EXTENT_OVERRIDE != 0) ?
                                TEST_EXTENT_OVERRIDE : DEFAULT_EXTENT;
    localparam [23:0] DEFAULT_BASE = (TEST_CIN == 3) ? 24'h000003 :
                                     (TEST_CIN == 16) ? 24'h000005 : 24'h000009;
    localparam [23:0] BASE = (TEST_BASE_OVERRIDE >= 0) ?
                              TEST_BASE_OVERRIDE[23:0] : DEFAULT_BASE;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg fill_start_valid = 1'b0;
    wire fill_start_ready;
    reg fill_bank = 1'b0;
    reg [3:0] fill_epoch = 4'h0;
    reg [23:0] fill_base_byte_addr = 24'd0;
    reg [15:0] fill_extent = 16'd0;
    wire mem_req_valid;
    reg mem_req_ready = 1'b0;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_data = 32'd0;
    wire fill_done_valid;
    wire fill_done_ready = 1'b1;
    wire fill_done_bank;
    wire [3:0] fill_done_epoch;
    reg rd_en = 1'b0;
    reg [8:0] rd_pixel_idx = 9'd0;
    reg [2:0] rd_channel_tile = 3'd0;
    wire rd_valid;
    wire signed [127:0] rd_data_vector;
    wire busy;
    wire [31:0] stale_resp_count, issue_count, response_count, write_count;

    reg [7:0] source_mem [0:65535];
    reg pipe_valid [0:3];
    reg [31:0] pipe_data [0:3];
    reg inject_stale = 1'b0;
    integer cycle_count = 0;
    integer errors = 0;
    integer max_req_streak = 0;
    integer req_streak = 0;
    integer i, p, c, t, d, idx;
    reg [31:0] expected_stale;

    ds_tile_dma_writer #(
        .MAX_CIN(128), .LAYOUT_CIN(TEST_CIN), .MAX_IN_H(10), .MAX_IN_W(10),
        .LANES(16), .ADDR_WIDTH(24), .EXTENT_WIDTH(16),
        .TOKEN_DEPTH(8), .RESPONSE_DEPTH(8), .COMMAND_DEPTH(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_bank(fill_bank), .fill_epoch(fill_epoch),
        .fill_base_byte_addr(fill_base_byte_addr), .fill_extent(fill_extent),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .fill_done_valid(fill_done_valid),
        .fill_done_ready(fill_done_ready), .fill_done_bank(fill_done_bank),
        .fill_done_epoch(fill_done_epoch), .rd_en(rd_en),
        .rd_pixel_idx(rd_pixel_idx), .rd_channel_tile(rd_channel_tile),
        .rd_valid(rd_valid), .rd_data_vector(rd_data_vector), .busy(busy),
        .stale_resp_count(stale_resp_count), .issue_count(issue_count),
        .response_count(response_count), .write_count(write_count)
    );

    always #5 clk = ~clk;

    function [7:0] source_value;
        input integer n;
        begin source_value = (n*37 + TEST_CIN*11 + 5) & 8'hff; end
    endfunction

    function [31:0] source_word;
        input [23:0] a;
        integer q;
        begin
            source_word = 32'd0;
            for (q = 0; q < 4; q = q + 1)
                source_word[q*8 +: 8] = source_mem[(a + q) & 16'hffff];
        end
    endfunction

    /* Four-cycle registered response latency.  The deterministic ready
     * pattern creates request bubbles while responses remain in order. */
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (!rst_n) begin
            mem_req_ready <= 1'b0;
            mem_resp_valid <= 1'b0;
            mem_resp_data <= 32'd0;
            for (d = 0; d < 4; d = d + 1) begin
                pipe_valid[d] <= 1'b0;
                pipe_data[d] <= 32'd0;
            end
        end else begin
            /* Start with a native one-word/cycle window, then add
             * deterministic request bubbles to exercise credit fencing. */
            mem_req_ready <= (cycle_count < 20) ||
                             (((cycle_count % 13) != 3) &&
                              ((cycle_count % 17) != 6));
            mem_resp_valid <= inject_stale ? 1'b1 : pipe_valid[0];
            mem_resp_data <= inject_stale ? expected_stale : pipe_data[0];
            for (d = 0; d < 3; d = d + 1) begin
                pipe_valid[d] <= pipe_valid[d+1];
                pipe_data[d] <= pipe_data[d+1];
            end
            pipe_valid[3] <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                pipe_valid[3] <= 1'b1;
                pipe_data[3] <= source_word({mem_req_addr[23:2], 2'b00});
                req_streak = req_streak + 1;
                if (req_streak > max_req_streak) max_req_streak = req_streak;
            end else begin
                req_streak = 0;
            end
        end
    end

    task check_read;
        input integer pixel_arg;
        input integer tile_arg;
        integer lane_arg;
        integer source_idx;
        integer channel_idx;
        reg [7:0] got_byte;
        begin
            @(negedge clk);
            rd_pixel_idx = pixel_arg;
            rd_channel_tile = tile_arg;
            rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (!rd_valid) begin
                errors = errors + 1;
                $display("ERROR missing read response pixel=%0d tile=%0d", pixel_arg, tile_arg);
            end else begin
                for (lane_arg = 0; lane_arg < 16; lane_arg = lane_arg + 1) begin
                    channel_idx = tile_arg*16 + lane_arg;
                    source_idx = pixel_arg*TEST_CIN + channel_idx;
                    if (channel_idx < TEST_CIN && source_idx < EXTENT) begin
                        got_byte = rd_data_vector[lane_arg*8 +: 8];
                        if (got_byte !== source_value(source_idx)) begin
                            errors = errors + 1;
                            if (errors < 12)
                                $display("ERROR p=%0d t=%0d lane=%0d got=%02x exp=%02x", pixel_arg, tile_arg, lane_arg, got_byte, source_value(source_idx));
                        end
                    end
                end
            end
            @(negedge clk);
            rd_en = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) source_mem[i] = 8'hc3 ^ i[7:0];
        for (i = 0; i < EXTENT; i = i + 1) source_mem[(BASE+i) & 16'hffff] = source_value(i);
        expected_stale = 32'hefbeadde;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        fill_bank = 1'b1;
        fill_epoch = 4'ha;
        fill_base_byte_addr = BASE;
        fill_extent = EXTENT;
        fill_start_valid = 1'b1;
        while (!fill_start_ready) @(negedge clk);
        repeat (3) @(posedge clk);
        @(negedge clk);
        fill_start_valid = 1'b0;

        while (!fill_done_valid) begin
            @(posedge clk);
        end
        if (!fill_done_bank || fill_done_epoch !== 4'ha) begin
            errors = errors + 1;
            $display("ERROR completion descriptor bank=%b epoch=%h", fill_done_bank, fill_done_epoch);
        end
        /* A stale response after the fence must be discarded, not attached to
         * the next epoch.  Keep the override high for two edges because the
         * source response register itself is synchronous. */
        @(negedge clk);
        inject_stale = 1'b1;
        repeat (2) @(negedge clk);
        inject_stale = 1'b0;
        repeat (3) @(posedge clk);
        if (stale_resp_count == 0) begin
            errors = errors + 1;
            $display("ERROR stale response was not counted");
        end

        for (p = 0; p < PIXELS; p = p + 1)
            for (t = 0; t < ((TEST_CIN+15)/16); t = t + 1)
                check_read(p, t);

        /* The initial ready window must show one native word accepted on
         * eight consecutive clock edges (the bounded response credits). */
        if (TEST_EXTENT_OVERRIDE == 0 && max_req_streak < 8) begin
            errors = errors + 1;
            $display("ERROR request throughput streak=%0d", max_req_streak);
        end
        if (errors == 0)
            $display("PASS tb_ds_tile_dma_writer CIN=%0d extent=%0d checks=%0d issues=%0d responses=%0d writes=%0d max_req_streak=%0d cycles=%0d", TEST_CIN, EXTENT, PIXELS*((TEST_CIN+15)/16)*16, issue_count, response_count, write_count, max_req_streak, cycle_count);
        else
            $display("FAIL tb_ds_tile_dma_writer CIN=%0d errors=%0d", TEST_CIN, errors);
        $finish;
    end

    initial begin
        repeat (25000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule
`default_nettype wire
