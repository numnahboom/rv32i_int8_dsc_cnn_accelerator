`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_sram_stem_dsblock_datapath;
    localparam MEM_WORDS = 65536;
    localparam MAX_EXPECTED = 2048;

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

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
        end else begin
            mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[mem_req_addr[17:2]] <= mem_req_wdata;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[17:2]];
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
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task start_and_wait_done;
        begin
            while (!cmd_ready) begin
                @(posedge clk);
            end
            cmd_valid = 1'b1;
            cmd_type = 2'd0;
            @(posedge clk);
            cmd_valid = 1'b0;

            timeout = 0;
            while (!status[1] && timeout < 300000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 300000) begin
                $display("FAIL tb_cnn_top_sram_stem_dsblock_datapath timeout case=%0d status=%08x", case_idx, status);
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

        fd = $fopen("tests/vectors/cnn_top_sram_stem_dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_sram_stem_dsblock_cases.hex");
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
                $display("ERROR: bad sram stem-dsblock header case=%0d scan=%0d", case_idx, scan_count);
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

            for (i = 0; i < expected_count; i = i + 1) begin
                if (mem[expected_addr[i][17:2]][7:0] !== expected_data[i]) begin
                    $display(
                        "MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                        case_idx,
                        i,
                        expected_addr[i],
                        $signed(expected_data[i]),
                        $signed(mem[expected_addr[i][17:2]][7:0])
                    );
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_sram_stem_dsblock_datapath cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_sram_stem_dsblock_datapath checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
