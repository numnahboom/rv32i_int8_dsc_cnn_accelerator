`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_fullnet_sram_datapath;
    localparam MEM_WORDS = 262144;
    localparam MAX_EXPECTED = 64;
    localparam MAX_LAYERS = 16;

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
    integer report_fd;
    integer layer_metrics_fd;
    integer hw_logits_fd;
    integer expected_logits_fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer perf_i;
    integer timeout;
    integer total_checks;
    integer error_count;
    integer case_errors;
    integer mem_read_total;
    integer mem_write_total;
    integer desc_read_total;
    integer layer_read_total;
    integer layer_write_total;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg [31:0] case_hw_cycles;
    reg perf_layer_active;
    reg [7:0] perf_layer_idx;
    reg [31:0] perf_layer_cycles [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_writes [0:MAX_LAYERS-1];

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
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[19:2]];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            perf_layer_active <= 1'b0;
            perf_layer_idx <= 8'd0;
            mem_read_total <= 0;
            mem_write_total <= 0;
            desc_read_total <= 0;
            layer_read_total <= 0;
            layer_write_total <= 0;
            for (perf_i = 0; perf_i < MAX_LAYERS; perf_i = perf_i + 1) begin
                perf_layer_cycles[perf_i] <= 32'd0;
                perf_layer_reads[perf_i] <= 32'd0;
                perf_layer_writes[perf_i] <= 32'd0;
            end
        end else begin
            if (dut.layer_start) begin
                perf_layer_active <= 1'b1;
                perf_layer_idx <= dut.current_layer;
                if (dut.current_layer < MAX_LAYERS) begin
                    perf_layer_cycles[dut.current_layer] <= 32'd1;
                    perf_layer_reads[dut.current_layer] <= 32'd0;
                    perf_layer_writes[dut.current_layer] <= 32'd0;
                end
            end else if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                perf_layer_cycles[perf_layer_idx] <= perf_layer_cycles[perf_layer_idx] + 32'd1;
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem_write_total <= mem_write_total + 1;
                    if (perf_layer_active) begin
                        layer_write_total <= layer_write_total + 1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_writes[perf_layer_idx] <= perf_layer_writes[perf_layer_idx] + 32'd1;
                        end
                    end
                end else begin
                    mem_read_total <= mem_read_total + 1;
                    if (perf_layer_active) begin
                        layer_read_total <= layer_read_total + 1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_reads[perf_layer_idx] <= perf_layer_reads[perf_layer_idx] + 32'd1;
                        end
                    end else begin
                        desc_read_total <= desc_read_total + 1;
                    end
                end
            end

            if (dut.layer_done) begin
                perf_layer_active <= 1'b0;
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
            while (!status[1] && timeout < 10000000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 10000000) begin
                $display("FAIL tb_cnn_top_fullnet_sram_datapath timeout case=%0d status=%08x", case_idx, status);
                $fatal;
            end
            case_hw_cycles = status[31:8];
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
        case_errors = 0;
        case_hw_cycles = 32'd0;

        fd = $fopen("tests/vectors/cnn_top_fullnet_sram_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_fullnet_sram_cases.hex");
            $finish;
        end
        report_fd = $fopen("build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt", "w");
        layer_metrics_fd = $fopen("build/reports/fullnet_layer_metrics.csv", "w");
        hw_logits_fd = $fopen("build/reports/fullnet_hw_logits.hex", "w");
        expected_logits_fd = $fopen("build/reports/fullnet_expected_logits.hex", "w");
        if (layer_metrics_fd != 0) begin
            $fwrite(layer_metrics_fd, "case,layer,cycles,mem_reads,mem_writes\n");
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            case_errors = 0;
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                mem[i] = 32'd0;
            end
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end

            scan_count = $fscanf(fd, "%h %d %d %d\n", desc_base_addr, layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("ERROR: bad fullnet sram header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end
            layer_num = layer_num_file[31:0];

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
            start_and_wait_done();

            if (status[2]) begin
                $display("MISMATCH case=%0d unexpected error status=%08x", case_idx, status);
                error_count = error_count + 1;
                case_errors = case_errors + 1;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                if (expected_logits_fd != 0) begin
                    $fwrite(expected_logits_fd, "%02x\n", expected_data[i]);
                end
                if (hw_logits_fd != 0) begin
                    $fwrite(hw_logits_fd, "%02x\n", mem[expected_addr[i][19:2]][7:0]);
                end
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
                    case_errors = case_errors + 1;
                end
                total_checks = total_checks + 1;
            end
            if (report_fd != 0) begin
                $fwrite(
                    report_fd,
                    "case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d desc_reads=%0d layer_reads=%0d layer_writes=%0d\n",
                    case_idx,
                    case_hw_cycles,
                    expected_count,
                    case_errors,
                    status,
                    mem_read_total,
                    mem_write_total,
                    desc_read_total,
                    layer_read_total,
                    layer_write_total
                );
            end
            if (layer_metrics_fd != 0) begin
                for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                    $fwrite(
                        layer_metrics_fd,
                        "%0d,%0d,%0d,%0d,%0d\n",
                        case_idx,
                        i,
                        perf_layer_cycles[i],
                        perf_layer_reads[i],
                        perf_layer_writes[i]
                    );
                end
            end
            $display(
                "PERF tb_cnn_top_fullnet_sram_datapath case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d",
                case_idx,
                case_hw_cycles,
                expected_count,
                case_errors,
                status,
                mem_read_total,
                mem_write_total
            );
        end

        $fclose(fd);
        if (report_fd != 0) begin
            $fclose(report_fd);
        end
        if (layer_metrics_fd != 0) begin
            $fclose(layer_metrics_fd);
        end
        if (hw_logits_fd != 0) begin
            $fclose(hw_logits_fd);
        end
        if (expected_logits_fd != 0) begin
            $fclose(expected_logits_fd);
        end
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_fullnet_sram_datapath cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_fullnet_sram_datapath checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
