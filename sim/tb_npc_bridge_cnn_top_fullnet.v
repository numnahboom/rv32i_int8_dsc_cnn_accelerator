`timescale 1ns/1ps
`default_nettype none

module tb_npc_bridge_cnn_top_fullnet;
    localparam MEM_WORDS = 262144;
    localparam MAX_EXPECTED = 64;

    reg clk;
    reg rst_n;

    reg cpu_cmd_valid;
    reg [2:0] cpu_cmd_funct3;
    reg [31:0] cpu_cmd_rs1;
    reg [31:0] cpu_cmd_rs2;
    wire [31:0] cpu_cmd_rdata;

    wire bridge_acc_cmd_valid;
    wire [1:0] bridge_acc_cmd;
    wire [31:0] bridge_acc_desc_base;
    wire [31:0] bridge_acc_layer_num;
    wire acc_cmd_ready;
    wire [31:0] acc_status;

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
    integer poll_count;
    reg [31:0] desc_base_addr;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg [31:0] final_status;
    reg [31:0] stat_status;

    npc_cnn_custom_bridge u_bridge (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_cmd_valid(cpu_cmd_valid),
        .cpu_cmd_funct3(cpu_cmd_funct3),
        .cpu_cmd_rs1(cpu_cmd_rs1),
        .cpu_cmd_rs2(cpu_cmd_rs2),
        .cpu_cmd_rdata(cpu_cmd_rdata),
        .acc_cmd_valid(bridge_acc_cmd_valid),
        .acc_cmd(bridge_acc_cmd),
        .acc_desc_base(bridge_acc_desc_base),
        .acc_layer_num(bridge_acc_layer_num),
        .acc_cmd_ready(acc_cmd_ready),
        .acc_status(acc_status)
    );

    cnn_top u_cnn_top (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(bridge_acc_cmd_valid),
        .cmd_ready(acc_cmd_ready),
        .cmd_type(bridge_acc_cmd),
        .desc_base_addr(bridge_acc_desc_base),
        .layer_num(bridge_acc_layer_num),
        .status(acc_status),
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
            cpu_cmd_valid = 1'b0;
            cpu_cmd_funct3 = 3'd0;
            cpu_cmd_rs1 = 32'd0;
            cpu_cmd_rs2 = 32'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task cpu_start;
        input [31:0] desc_base;
        input [31:0] num_layers;
        begin
            while (cpu_cmd_rdata[0] != 1'b1) begin
                cpu_cmd_funct3 = 3'd0;
                @(posedge clk);
            end
            cpu_cmd_funct3 = 3'd0;
            cpu_cmd_rs1 = desc_base;
            cpu_cmd_rs2 = num_layers;
            cpu_cmd_valid = 1'b1;
            @(posedge clk);
            cpu_cmd_valid = 1'b0;
        end
    endtask

    task cpu_poll_done;
        begin
            poll_count = 0;
            timeout = 0;
            cpu_cmd_funct3 = 3'd1;
            while (!cpu_cmd_rdata[1] && timeout < 10000000) begin
                timeout = timeout + 1;
                poll_count = poll_count + 1;
                @(posedge clk);
                cpu_cmd_funct3 = 3'd1;
            end
            final_status = cpu_cmd_rdata;
            if (timeout >= 10000000) begin
                $display("FAIL tb_npc_bridge_cnn_top_fullnet timeout case=%0d status=%08x", case_idx, final_status);
                $fatal;
            end
        end
    endtask

    task cpu_stat;
        output [31:0] status_value;
        begin
            cpu_cmd_funct3 = 3'd2;
            #1;
            status_value = cpu_cmd_rdata;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cpu_cmd_valid = 1'b0;
        cpu_cmd_funct3 = 3'd0;
        cpu_cmd_rs1 = 32'd0;
        cpu_cmd_rs2 = 32'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        total_checks = 0;
        error_count = 0;
        poll_count = 0;
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
                $display("ERROR: bad bridge fullnet header case=%0d scan=%0d", case_idx, scan_count);
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
            cpu_start(desc_base_addr, layer_num_file[31:0]);
            cpu_poll_done();
            cpu_stat(stat_status);

            if (final_status[2]) begin
                $display("MISMATCH case=%0d bridge reported error status=%08x", case_idx, final_status);
                error_count = error_count + 1;
            end
            if (stat_status !== {8'd0, final_status[31:8]}) begin
                $display("MISMATCH case=%0d bridge stat_cycles=%08x poll_status=%08x", case_idx, stat_status, final_status);
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
                "PERF tb_npc_bridge_cnn_top_fullnet case=%0d polls=%0d status=%08x hw_cycles=%0d checks=%0d",
                case_idx,
                poll_count,
                final_status,
                final_status[31:8],
                expected_count
            );
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_npc_bridge_cnn_top_fullnet cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_npc_bridge_cnn_top_fullnet checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
