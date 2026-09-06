`timescale 1ns/1ps
`default_nettype none

// Independent contract checker for the DS1 -> DS2 stream admission boundary.
// It checks generated reference transactions and sink tags.  No existing
// cnn_top or ds1_retained* RTL is compiled here.
module tb_ds12_stream_harness;
    localparam integer DS1_CFG_WORDS = 308;
    localparam integer DS2_CFG_WORDS = 872;
    localparam integer DS1_SINK_WORDS = 8192;
    localparam integer DS2_SINK_WORDS = 4096;
    localparam integer DS2_CONTEXT_BASE = 128;
    localparam integer SINK_WORDS = DS1_SINK_WORDS + DS2_SINK_WORDS;
    localparam integer MAX_WAIT = 200000;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer fd;
    integer rc;
    integer layer;
    integer kind;
    integer index;
    integer byte_enable;
    integer cfg_address;
    integer cfg_data;
    integer cfg_count [1:2];
    integer cfg_errors;
    integer sink_layer;
    integer sink_index;
    integer sink_address;
    integer sink_data;
    integer sink_mask;
    integer sink_owner;
    integer sink_epoch;
    integer sink_context;
    integer request_cycle;
    integer response_cycle;
    integer sink_count [1:2];
    integer sink_errors;
    integer i;
    integer expected_owner;
    integer expected_epoch;
    integer expected_context;

    // Future candidate hook.  The default run deliberately leaves it out so
    // reference checks can be run before a datapath exists.  Defining
    // DS12_STREAM_DUT selects the port-compatible stub (or a real module via
    // DS12_STREAM_DUT_MODULE) and enables the explicit output wait below.
`ifdef DS12_STREAM_DUT
`ifndef DS12_STREAM_DUT_MODULE
`define DS12_STREAM_DUT_MODULE ds12_stream_future_dut_if
`endif
    wire dut_ready;
    wire dut_cfg_ready;
    wire dut_mem_req_valid;
    wire dut_mem_req_write;
    wire [31:0] dut_mem_req_addr;
    wire [31:0] dut_mem_req_wdata;
    wire [3:0] dut_mem_req_strb;
    wire dut_stream_valid;
    wire [7:0] dut_stream_data;
    wire [15:0] dut_stream_pixel;
    wire [1:0] dut_stream_context;
    wire dut_stream_owner;
    wire [31:0] dut_stream_epoch;
    wire dut_stream_last;
    wire dut_sink_valid;
    wire [31:0] dut_sink_addr;
    wire [31:0] dut_sink_data;
    wire [3:0] dut_sink_strb;
    wire dut_sink_owner;
    wire [31:0] dut_sink_epoch;
    wire [1:0] dut_sink_context;
    reg [31:0] dut_cfg_data;
    reg dut_cfg_valid;
    reg dut_cfg_last;
    reg dut_start;
    integer dut_sink_seen;
    integer dut_wait;

    `DS12_STREAM_DUT_MODULE dut (
        .clk(clk), .rst_n(rst_n), .start(dut_start), .ready(dut_ready),
        .cfg_valid(dut_cfg_valid), .cfg_ready(dut_cfg_ready), .cfg_data(dut_cfg_data), .cfg_last(dut_cfg_last),
        .mem_req_valid(dut_mem_req_valid), .mem_req_ready(1'b1), .mem_req_write(dut_mem_req_write),
        .mem_req_addr(dut_mem_req_addr), .mem_req_wdata(dut_mem_req_wdata), .mem_req_strb(dut_mem_req_strb),
        .mem_resp_valid(1'b0), .mem_resp_rdata(32'd0),
        .stream_valid(dut_stream_valid), .stream_ready(1'b1), .stream_data(dut_stream_data), .stream_pixel(dut_stream_pixel),
        .stream_context(dut_stream_context), .stream_owner(dut_stream_owner), .stream_epoch(dut_stream_epoch), .stream_last(dut_stream_last),
        .sink_valid(dut_sink_valid), .sink_ready(1'b1), .sink_addr(dut_sink_addr), .sink_data(dut_sink_data), .sink_strb(dut_sink_strb),
        .sink_owner(dut_sink_owner), .sink_epoch(dut_sink_epoch), .sink_context(dut_sink_context)
    );

    always @(posedge clk) begin
        if (!rst_n)
            dut_sink_seen <= 0;
        else if (dut_sink_valid)
            dut_sink_seen <= dut_sink_seen + 1;
    end
`endif

    task check_reference_files;
        begin
            cfg_count[1] = 0; cfg_count[2] = 0; cfg_errors = 0;
            fd = $fopen("build/ds12_stream_harness/ds12_stream_cfg_transactions.hex", "r");
            if (fd == 0) begin $display("FAIL missing cfg transaction file"); cfg_errors = cfg_errors + 1; end
            else begin
                while (!$feof(fd)) begin
                    rc = $fscanf(fd, "%d %d %d %h %h %h\n", layer, kind, index, cfg_address, byte_enable, cfg_data);
                    if (rc == 6) begin
                        if (layer < 1 || layer > 2) cfg_errors = cfg_errors + 1;
                        else begin
                            cfg_count[layer] = cfg_count[layer] + 1;
                            if (kind < 0 || kind > 7 || index < 0 || cfg_address < 0 || (cfg_address % 4) != 0 || byte_enable != 15)
                                cfg_errors = cfg_errors + 1;
                            if (^cfg_data === 1'bx) cfg_errors = cfg_errors + 1;
                        end
                    end
                end
                $fclose(fd);
            end
            if (cfg_count[1] != DS1_CFG_WORDS || cfg_count[2] != DS2_CFG_WORDS) begin
                $display("FAIL cfg counts DS1=%0d DS2=%0d expected=%0d/%0d", cfg_count[1], cfg_count[2], DS1_CFG_WORDS, DS2_CFG_WORDS);
                cfg_errors = cfg_errors + 1;
            end

            sink_count[1] = 0; sink_count[2] = 0; sink_errors = 0;
            fd = $fopen("build/ds12_stream_harness/ds12_stream_sink_words.hex", "r");
            if (fd == 0) begin $display("FAIL missing sink word file"); sink_errors = sink_errors + 1; end
            else begin
                while (!$feof(fd)) begin
                    rc = $fscanf(fd, "%d %d %h %h %h %d %d %d %d %d\n", sink_layer, sink_index, sink_address, sink_data, sink_mask, sink_owner, sink_epoch, sink_context, request_cycle, response_cycle);
                    if (rc == 10) begin
                        if (sink_layer < 1 || sink_layer > 2) sink_errors = sink_errors + 1;
                        else begin
                            sink_count[sink_layer] = sink_count[sink_layer] + 1;
                            // One context is exactly eight pixels.  DS1
                            // emits eight words/pixel and DS2 sixteen.
                            if (sink_layer == 1) begin
                                expected_owner = (sink_index / 64) & 1;
                                expected_epoch = (sink_index / 64) / 2;
                                expected_context = (sink_index / 64) & 3;
                            end else begin
                                expected_owner = ((DS2_CONTEXT_BASE + sink_index / 128) & 1);
                                expected_epoch = (DS2_CONTEXT_BASE + sink_index / 128) / 2;
                                expected_context = (DS2_CONTEXT_BASE + sink_index / 128) & 3;
                            end
                            if (sink_mask != 15 || (sink_address % 4) != 0 || response_cycle != request_cycle + 1 ||
                                sink_owner != expected_owner || sink_epoch != expected_epoch || sink_context != expected_context || ^sink_data === 1'bx)
                                sink_errors = sink_errors + 1;
                            if (sink_layer == 1 && (sink_address < 32'h00100000 || sink_address >= 32'h00108000)) sink_errors = sink_errors + 1;
                            if (sink_layer == 2 && (sink_address < 32'h00200000 || sink_address >= 32'h00204000)) sink_errors = sink_errors + 1;
                        end
                    end
                end
                $fclose(fd);
            end
            if (sink_count[1] != DS1_SINK_WORDS || sink_count[2] != DS2_SINK_WORDS) begin
                $display("FAIL sink counts DS1=%0d DS2=%0d expected=%0d/%0d", sink_count[1], sink_count[2], DS1_SINK_WORDS, DS2_SINK_WORDS);
                sink_errors = sink_errors + 1;
            end
            if (cfg_errors != 0 || sink_errors != 0) begin
                $display("FAIL ds12_stream_reference cfg_errors=%0d sink_errors=%0d", cfg_errors, sink_errors);
                $fatal(1, "ds12_stream reference checks failed");
            end
            $display("REFERENCE_PASS ds12_stream cfg=DS1:%0d/DS2:%0d sink=DS1:%0d/DS2:%0d masks=all_valid response_delay=1", cfg_count[1], cfg_count[2], sink_count[1], sink_count[2]);
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        check_reference_files;
`ifdef DS12_STREAM_DUT
        dut_cfg_valid = 1'b0;
        dut_cfg_data = 32'd0;
        dut_cfg_last = 1'b0;
        dut_start = 1'b1;
        @(posedge clk);
        dut_start = 1'b0;
        dut_wait = 0;
        while (dut_sink_seen < SINK_WORDS && dut_wait < MAX_WAIT) begin
            @(posedge clk);
            dut_wait = dut_wait + 1;
        end
        if (dut_sink_seen < SINK_WORDS) begin
            $display("DUT_DEFERRED_OR_FAIL no DUT output after %0d cycles; architecture is not PASS", dut_wait);
            $fatal(2, "DUT produced no complete sink stream");
        end
        $display("DUT_OUTPUT_OBSERVED sink_words=%0d; compare against reference files before claiming architecture PASS", dut_sink_seen);
`else
        $display("DUT_DEFERRED no candidate module wired; reference/memory checks complete, architecture is not PASS");
`endif
        $finish(0);
    end
endmodule

`default_nettype wire
