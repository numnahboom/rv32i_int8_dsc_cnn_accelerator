`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_tiled_dsblock_datapath;
    localparam MEM_WORDS = 131072;
    localparam MAX_EXPECTED = 8192;

    reg clk;
    reg rst_n;
    reg cmd_valid;
    wire cmd_ready;
    reg [1:0] cmd_type;
    reg [31:0] desc_base_addr;
    reg [31:0] layer_num;
    wire [31:0] status;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;

    reg [31:0] mem [0:MEM_WORDS-1];
    reg [31:0] expected_addr [0:MAX_EXPECTED-1];
    reg [7:0] expected_data [0:MAX_EXPECTED-1];
    reg expected_write_valid [0:MEM_WORDS-1];
    reg expected_write_seen [0:MEM_WORDS-1];
    reg [31:0] expected_write_addr [0:MEM_WORDS-1];
    reg [7:0] expected_write_data [0:MEM_WORDS-1];

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer timeout;
    integer total_checks;
    integer error_count;
    integer responder_cycle;
    integer accepted_reads;
    integer returned_reads;
    integer accepted_writes;
    integer response_delay;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg pending_read;
    reg [31:0] pending_rdata;
    reg saw_ready_stall;
    reg [3:0] delay_coverage;
    reg stalled_request;
    reg stalled_write;
    reg [31:0] stalled_addr;
    reg [31:0] stalled_wdata;
    reg [15:0] stall_lfsr;

    cnn_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_type(cmd_type),
        .desc_base_addr(desc_base_addr),
        .layer_num(layer_num),
        .status(status),
        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Keep a single outstanding external read and perturb both request-ready
    // and response latency deterministically.  This catches lookahead code
    // that only works with the old always-ready, immediate responder.
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_req_ready <= 1'b1;
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            responder_cycle <= 0;
            accepted_reads <= 0;
            returned_reads <= 0;
            accepted_writes <= 0;
            response_delay <= 0;
            pending_read <= 1'b0;
            pending_rdata <= 32'd0;
            saw_ready_stall <= 1'b0;
            delay_coverage <= 4'b0000;
            stalled_request <= 1'b0;
            stalled_write <= 1'b0;
            stalled_addr <= 32'd0;
            stalled_wdata <= 32'd0;
            stall_lfsr <= 16'h1ace;
        end else begin
            responder_cycle <= responder_cycle + 1;
            // Fixed-seed pseudo-random ready/response perturbation keeps this
            // regression reproducible while exercising arbitrary memory
            // stalls rather than one hand-written periodic schedule.
            stall_lfsr <= {stall_lfsr[14:0],
                           stall_lfsr[15] ^ stall_lfsr[13] ^
                           stall_lfsr[12] ^ stall_lfsr[10]};
            mem_req_ready <= (stall_lfsr[2:0] != 3'b000);

            mem_resp_valid <= 1'b0;
            if (pending_read) begin
                if (response_delay == 0) begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= pending_rdata;
                    pending_read <= 1'b0;
                    returned_reads <= returned_reads + 1;
                end else begin
                    response_delay <= response_delay - 1;
                end
            end

            if (stalled_request) begin
                if (!mem_req_valid ||
                    mem_req_write !== stalled_write ||
                    mem_req_addr !== stalled_addr ||
                    mem_req_wdata !== stalled_wdata) begin
                    $display("FAIL tb_cnn_top_tiled_dsblock_datapath unstable request while stalled case=%0d", case_idx);
                    $fatal;
                end
            end
            if (mem_req_valid && !mem_req_ready) begin
                saw_ready_stall <= 1'b1;
                stalled_request <= 1'b1;
                stalled_write <= mem_req_write;
                stalled_addr <= mem_req_addr;
                stalled_wdata <= mem_req_wdata;
            end else begin
                stalled_request <= 1'b0;
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    if (accepted_writes >= expected_count) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath unexpected extra write case=%0d index=%0d addr=%08x data=%08x",
                                 case_idx, accepted_writes, mem_req_addr, mem_req_wdata);
                        $fatal;
                    end
                    if (!expected_write_valid[mem_req_addr[18:2]]) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath write to unexpected address case=%0d index=%0d addr=%08x data=%08x",
                                 case_idx, accepted_writes, mem_req_addr, mem_req_wdata);
                        $fatal;
                    end
                    if (mem_req_addr !== expected_write_addr[mem_req_addr[18:2]]) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath aliased write address case=%0d index=%0d addr=%08x expected_addr=%08x",
                                 case_idx, accepted_writes, mem_req_addr,
                                 expected_write_addr[mem_req_addr[18:2]]);
                        $fatal;
                    end
                    if (expected_write_seen[mem_req_addr[18:2]]) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath duplicate write case=%0d index=%0d addr=%08x data=%08x",
                                 case_idx, accepted_writes, mem_req_addr, mem_req_wdata);
                        $fatal;
                    end
                    if (mem_req_wdata !==
                        {{24{expected_write_data[mem_req_addr[18:2]][7]}},
                          expected_write_data[mem_req_addr[18:2]]}) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath write data mismatch case=%0d index=%0d addr=%08x data=%08x expected_data=%08x",
                                 case_idx, accepted_writes, mem_req_addr,
                                 mem_req_wdata,
                                 {{24{expected_write_data[mem_req_addr[18:2]][7]}},
                                   expected_write_data[mem_req_addr[18:2]]});
                        $fatal;
                    end
                    mem[mem_req_addr[18:2]] <= mem_req_wdata;
                    expected_write_seen[mem_req_addr[18:2]] <= 1'b1;
                    accepted_writes <= accepted_writes + 1;
                end else begin
                    if (pending_read) begin
                        $display("FAIL tb_cnn_top_tiled_dsblock_datapath second accepted read before reply case=%0d addr=%08x", case_idx, mem_req_addr);
                        $fatal;
                    end
                    pending_read <= 1'b1;
                    pending_rdata <= mem[mem_req_addr[18:2]];
                    response_delay <= {1'b0, stall_lfsr[1:0]};
                    delay_coverage[stall_lfsr[1:0]] <= 1'b1;
                    accepted_reads <= accepted_reads + 1;
                end
            end
        end
    end

    task reset_dut;
        begin
            rst_n = 1'b0;
            cmd_valid = 1'b0;
            cmd_type = 2'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            repeat (5) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    task start_and_wait_done;
        begin
            while (!cmd_ready) begin
                @(negedge clk);
            end
            cmd_valid = 1'b1;
            cmd_type = 2'd0;
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;

            timeout = 0;
            while (!status[1] && timeout < 500000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 500000) begin
                $display("FAIL tb_cnn_top_tiled_dsblock_datapath timeout case=%0d status=%08x", case_idx, status);
                $fatal;
            end
        end
    endtask

    task check_bus_protocol;
        begin
            @(negedge clk);
            if (accepted_reads != returned_reads || pending_read) begin
                $display("FAIL tb_cnn_top_tiled_dsblock_datapath incomplete reads case=%0d accepted=%0d returned=%0d pending=%0d", case_idx, accepted_reads, returned_reads, pending_read);
                $fatal;
            end
            if (accepted_writes != expected_count) begin
                $display("FAIL tb_cnn_top_tiled_dsblock_datapath write count case=%0d accepted=%0d expected=%0d",
                         case_idx, accepted_writes, expected_count);
                $fatal;
            end
            if (!saw_ready_stall) begin
                $display("FAIL tb_cnn_top_tiled_dsblock_datapath did not exercise ready stall case=%0d", case_idx);
                $fatal;
            end
            if (delay_coverage !== 4'b1111) begin
                $display("FAIL tb_cnn_top_tiled_dsblock_datapath incomplete response-delay coverage case=%0d coverage=%b", case_idx, delay_coverage);
                $fatal;
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd_type = 2'd0;
        desc_base_addr = 32'd0;
        layer_num = 32'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        total_checks = 0;
        error_count = 0;

        fd = $fopen("tests/vectors/cnn_top_tiled_dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_tiled_dsblock_cases.hex");
            $fatal;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                mem[i] = 32'd0;
                expected_write_valid[i] = 1'b0;
                expected_write_seen[i] = 1'b0;
                expected_write_addr[i] = 32'd0;
                expected_write_data[i] = 8'd0;
            end
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end

            scan_count = $fscanf(fd, "%h %d %d %d\n", desc_base_addr, layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("ERROR: bad tiled dsblock header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end
            layer_num = layer_num_file[31:0];

            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("ERROR: bad memory entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                mem[tmp_addr[18:2]] = tmp_data;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_i8);
                if (scan_count != 2) begin
                    $display("ERROR: bad expected entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                expected_addr[i] = tmp_addr;
                expected_data[i] = tmp_i8;
                if (expected_write_valid[tmp_addr[18:2]]) begin
                    $display("ERROR: duplicate expected write address case=%0d index=%0d addr=%08x",
                             case_idx, i, tmp_addr);
                    $fatal;
                end
                expected_write_valid[tmp_addr[18:2]] = 1'b1;
                expected_write_addr[tmp_addr[18:2]] = tmp_addr;
                expected_write_data[tmp_addr[18:2]] = tmp_i8;
            end

            reset_dut();
            start_and_wait_done();
            check_bus_protocol();

            if (status[2]) begin
                $display("MISMATCH case=%0d unexpected error status=%08x", case_idx, status);
                error_count = error_count + 1;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                if (mem[expected_addr[i][18:2]][7:0] !== expected_data[i]) begin
                    $display(
                        "MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                        case_idx,
                        i,
                        expected_addr[i],
                        $signed(expected_data[i]),
                        $signed(mem[expected_addr[i][18:2]][7:0])
                    );
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_tiled_dsblock_datapath cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_tiled_dsblock_datapath checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
