`timescale 1ns/1ps
`default_nettype none

// External-memory stress test for cnn_top.  The protocol is deliberately
// conservative (one read response outstanding) because cnn_top currently
// consumes read responses in order.  It exercises both request backpressure
// and non-constant read-response latency while retaining the golden output
// checks used by tb_cnn_top_dsblock_datapath.
module tb_cnn_top_backpressure;
    localparam MEM_WORDS = 65536;
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

    // Registered response queue.  Its countdown is varied deterministically
    // per read so that this TB is repeatable and independent of simulator seed.
    reg resp_pending;
    reg [3:0] resp_delay_count;
    reg [31:0] resp_data;
    integer read_sequence;
    integer bus_cycle;

    // Captures the payload whenever valid is blocked.  At the next edge (and
    // every subsequent blocked edge) a change is a protocol violation.
    reg blocked_last_cycle;
    reg blocked_write;
    reg [31:0] blocked_addr;
    reg [31:0] blocked_wdata;

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
    integer accepted_reads;
    integer accepted_writes;
    integer blocked_cycles;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;

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

    // Change ready only away from the active sampling edge.  Each 17-cycle
    // window contains several 1-3 cycle stalls, including stalls of writes.
    always @(negedge clk) begin
        if (!rst_n) begin
            mem_req_ready <= 1'b0;
        end else begin
            case (bus_cycle % 17)
                2, 3, 7, 11, 12, 13: mem_req_ready <= 1'b0;
                default:              mem_req_ready <= 1'b1;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            bus_cycle <= 0;
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            resp_pending <= 1'b0;
            resp_delay_count <= 4'd0;
            resp_data <= 32'd0;
            read_sequence <= 0;
            accepted_reads <= 0;
            accepted_writes <= 0;
            blocked_cycles <= 0;
            blocked_last_cycle <= 1'b0;
            blocked_write <= 1'b0;
            blocked_addr <= 32'd0;
            blocked_wdata <= 32'd0;
        end else begin
            bus_cycle <= bus_cycle + 1;
            mem_resp_valid <= 1'b0;

            // Request-stability assertion for ready/valid backpressure.
            if (blocked_last_cycle) begin
                if (!mem_req_valid ||
                    (mem_req_write !== blocked_write) ||
                    (mem_req_addr !== blocked_addr) ||
                    (mem_req_wdata !== blocked_wdata)) begin
                    $display("FAIL backpressure payload changed at cycle=%0d valid=%b write=%b addr=%08x wdata=%08x expected_write=%b expected_addr=%08x expected_wdata=%08x",
                             bus_cycle, mem_req_valid, mem_req_write, mem_req_addr,
                             mem_req_wdata, blocked_write, blocked_addr, blocked_wdata);
                    $fatal;
                end
            end
            blocked_last_cycle <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                blocked_cycles <= blocked_cycles + 1;
                blocked_write <= mem_req_write;
                blocked_addr <= mem_req_addr;
                blocked_wdata <= mem_req_wdata;
            end

            if (resp_pending) begin
                if (resp_delay_count == 0) begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= resp_data;
                    resp_pending <= 1'b0;
                end else begin
                    resp_delay_count <= resp_delay_count - 1'b1;
                end
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    // The final-memory image check below cannot detect a
                    // duplicate write, an unexpected write to an unrelated
                    // address, or a reordered write that happens to leave
                    // the expected bytes intact.  Check every accepted bus
                    // write against the golden sequence at the handshake.
                    if (accepted_writes >= expected_count) begin
                        $display("FAIL extra write case=%0d cycle=%0d index=%0d addr=%08x wdata=%08x expected_count=%0d",
                                 case_idx, bus_cycle, accepted_writes, mem_req_addr,
                                 mem_req_wdata, expected_count);
                        $fatal;
                    end
                    if ((mem_req_addr !== expected_addr[accepted_writes]) ||
                        (mem_req_wdata !== {{24{expected_data[accepted_writes][7]}},
                                           expected_data[accepted_writes]})) begin
                        $display("FAIL write sequence case=%0d cycle=%0d index=%0d addr=%08x expected_addr=%08x wdata=%08x expected_wdata=%08x",
                                 case_idx, bus_cycle, accepted_writes, mem_req_addr,
                                 expected_addr[accepted_writes], mem_req_wdata,
                                 {{24{expected_data[accepted_writes][7]}},
                                  expected_data[accepted_writes]});
                        $fatal;
                    end
                    mem[mem_req_addr[17:2]] <= mem_req_wdata;
                    accepted_writes <= accepted_writes + 1;
                end else begin
                    if (resp_pending) begin
                        $display("FAIL read accepted with earlier response pending at cycle=%0d", bus_cycle);
                        $fatal;
                    end
                    resp_pending <= 1'b1;
                    resp_data <= mem[mem_req_addr[17:2]];
                    // 0..4 wait cycles; sequence makes response latency vary.
                    resp_delay_count <= (read_sequence * 3 + case_idx) % 5;
                    read_sequence <= read_sequence + 1;
                    accepted_reads <= accepted_reads + 1;
                end
            end
        end
    end

    task reset_dut;
        begin
            // Drive reset controls away from the DUT sampling edge.  This
            // avoids an active-region race between this TB and posedge RTL.
            @(negedge clk);
            rst_n = 1'b0;
            cmd_valid = 1'b0;
            cmd_type = 2'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task start_and_wait_done;
        begin
            while (!cmd_ready) begin
                @(posedge clk);
            end
            // Assert before, and remove after, a dedicated sampling edge.
            // Blocking assignments at the same posedge would be racy.
            @(negedge clk);
            cmd_valid = 1'b1;
            cmd_type = 2'd0;
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;

            timeout = 0;
            while (!status[1] && timeout < 400000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 400000) begin
                $display("FAIL tb_cnn_top_backpressure timeout case=%0d status=%08x", case_idx, status);
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
        mem_req_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        total_checks = 0;
        error_count = 0;

        fd = $fopen("tests/vectors/cnn_top_dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_dsblock_cases.hex");
            // $finish generally returns a zero simulator status, which can
            // turn a missing prerequisite into a false Verilator PASS.
            $fatal;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                mem[i] = 32'd0;
            end
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end

            scan_count = $fscanf(fd, "%h %d %d %d\n", desc_base_addr, layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("ERROR: bad cnn_top case header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end
            layer_num = layer_num_file[31:0];

            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("ERROR: bad memory entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                mem[tmp_addr[17:2]] = tmp_data;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_i8);
                if (scan_count != 2) begin
                    $display("ERROR: bad expected entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                expected_addr[i] = tmp_addr;
                expected_data[i] = tmp_i8;
            end

            reset_dut();
            start_and_wait_done();

            if (status[2]) begin
                $display("MISMATCH case=%0d unexpected error status=%08x", case_idx, status);
                error_count = error_count + 1;
            end
            if (accepted_writes != expected_count) begin
                $display("MISMATCH case=%0d accepted write count expected=%0d actual=%0d",
                         case_idx, expected_count, accepted_writes);
                error_count = error_count + 1;
            end
            for (i = 0; i < expected_count; i = i + 1) begin
                if (mem[expected_addr[i][17:2]][7:0] !== expected_data[i]) begin
                    $display("MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                             case_idx, i, expected_addr[i], $signed(expected_data[i]),
                             $signed(mem[expected_addr[i][17:2]][7:0]));
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end
            $display("INFO tb_cnn_top_backpressure case=%0d cycles=%0d reads=%0d writes=%0d blocked=%0d",
                     case_idx, bus_cycle, accepted_reads, accepted_writes, blocked_cycles);
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_backpressure cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_backpressure checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
