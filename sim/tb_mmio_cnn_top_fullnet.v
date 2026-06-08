`timescale 1ns/1ps
`default_nettype none

module tb_mmio_cnn_top_fullnet;
    localparam MEM_WORDS = 262144;
    localparam MAX_EXPECTED = 64;
    localparam OFF_DESC_BASE = 32'h0000_0000;
    localparam OFF_LAYER_NUM = 32'h0000_0004;
    localparam OFF_CMD       = 32'h0000_0008;
    localparam OFF_STATUS    = 32'h0000_000c;
    localparam OFF_STAT      = 32'h0000_0010;

    reg clk;
    reg rst_n;

    reg bus_valid;
    reg bus_write;
    reg [31:0] bus_addr;
    reg [31:0] bus_wdata;
    wire bus_ready;
    wire bus_rvalid;
    wire [31:0] bus_rdata;

    wire mmio_cmd_valid;
    wire [1:0] mmio_cmd;
    wire [31:0] mmio_desc_base;
    wire [31:0] mmio_layer_num;
    wire cmd_ready;
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

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer timeout;
    integer poll_count;
    integer total_checks;
    integer error_count;
    reg [31:0] desc_base_addr;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg [31:0] rd_value;
    reg [31:0] final_status;
    reg [31:0] stat_status;

    cnn_mmio_regs u_mmio (
        .clk(clk),
        .rst_n(rst_n),
        .bus_valid(bus_valid),
        .bus_write(bus_write),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_ready(bus_ready),
        .bus_rvalid(bus_rvalid),
        .bus_rdata(bus_rdata),
        .acc_cmd_valid(mmio_cmd_valid),
        .acc_cmd(mmio_cmd),
        .acc_desc_base(mmio_desc_base),
        .acc_layer_num(mmio_layer_num),
        .acc_cmd_ready(cmd_ready),
        .acc_status(status)
    );

    cnn_top u_cnn_top (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(mmio_cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_type(mmio_cmd),
        .desc_base_addr(mmio_desc_base),
        .layer_num(mmio_layer_num),
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

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
        end else begin
            mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[19:2]];
                end
            end
        end
    end

    task reset_dut;
        begin
            rst_n = 1'b0;
            bus_valid = 1'b0;
            bus_write = 1'b0;
            bus_addr = 32'd0;
            bus_wdata = 32'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task mmio_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            bus_addr = addr;
            bus_wdata = data;
            bus_write = 1'b1;
            bus_valid = 1'b1;
            while (!bus_ready) begin
                @(posedge clk);
            end
            @(posedge clk);
            bus_valid = 1'b0;
            bus_write = 1'b0;
            @(posedge clk);
        end
    endtask

    task mmio_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            bus_addr = addr;
            bus_wdata = 32'd0;
            bus_write = 1'b0;
            bus_valid = 1'b1;
            @(posedge clk);
            #1;
            data = bus_rvalid ? bus_rdata : 32'hffff_ffff;
            bus_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    task wait_done_mmio;
        begin
            poll_count = 0;
            timeout = 0;
            final_status = 32'd0;
            while (!final_status[1] && timeout < 10000000) begin
                mmio_read(OFF_STATUS, final_status);
                poll_count = poll_count + 1;
                timeout = timeout + 1;
            end
            if (timeout >= 10000000) begin
                $display("FAIL tb_mmio_cnn_top_fullnet timeout case=%0d status=%08x", case_idx, final_status);
                $fatal;
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        bus_valid = 1'b0;
        bus_write = 1'b0;
        bus_addr = 32'd0;
        bus_wdata = 32'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        poll_count = 0;
        total_checks = 0;
        error_count = 0;
        final_status = 32'd0;
        stat_status = 32'd0;

        fd = $fopen("tests/vectors/cnn_top_fullnet_sram_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_fullnet_sram_cases.hex");
            $finish;
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
                $display("ERROR: bad mmio fullnet header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end

            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("ERROR: bad memory entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                mem[tmp_addr[19:2]] = tmp_data;
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
            mmio_write(OFF_DESC_BASE, desc_base_addr);
            mmio_write(OFF_LAYER_NUM, layer_num_file[31:0]);
            mmio_read(OFF_DESC_BASE, rd_value);
            if (rd_value !== desc_base_addr) begin
                $display("MISMATCH case=%0d desc readback expected=%08x actual=%08x", case_idx, desc_base_addr, rd_value);
                error_count = error_count + 1;
            end
            mmio_read(OFF_LAYER_NUM, rd_value);
            if (rd_value !== layer_num_file[31:0]) begin
                $display("MISMATCH case=%0d layer readback expected=%0d actual=%0d", case_idx, layer_num_file, rd_value);
                error_count = error_count + 1;
            end

            mmio_write(OFF_CMD, 32'd0);
            wait_done_mmio();
            mmio_read(OFF_STAT, stat_status);

            if (final_status[2]) begin
                $display("MISMATCH case=%0d MMIO status error status=%08x", case_idx, final_status);
                error_count = error_count + 1;
            end
            if (stat_status !== {8'd0, final_status[31:8]}) begin
                $display("MISMATCH case=%0d MMIO stat_cycles=%08x status=%08x", case_idx, stat_status, final_status);
                error_count = error_count + 1;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                if (mem[expected_addr[i][19:2]][7:0] !== expected_data[i]) begin
                    $display(
                        "MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                        case_idx,
                        i,
                        expected_addr[i],
                        $signed(expected_data[i]),
                        $signed(mem[expected_addr[i][19:2]][7:0])
                    );
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end

            $display(
                "PERF tb_mmio_cnn_top_fullnet case=%0d polls=%0d status=%08x hw_cycles=%0d checks=%0d",
                case_idx,
                poll_count,
                final_status,
                final_status[31:8],
                expected_count
            );
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_mmio_cnn_top_fullnet cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_mmio_cnn_top_fullnet checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
