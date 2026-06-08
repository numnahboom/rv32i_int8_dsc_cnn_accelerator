`timescale 1ns/1ps
`default_nettype none

module tb_feature_sram_pingpong;
    reg clk;
    reg rst_n;
    reg reset_to_a;
    reg layer_done;
    wire input_bank_sel;
    wire output_bank_sel;

    reg input_rd_en;
    reg [14:0] input_rd_addr;
    wire input_rd_valid;
    wire signed [7:0] input_rd_data;

    reg output_wr_en;
    reg [14:0] output_wr_addr;
    reg signed [7:0] output_wr_data;

    reg host_wr_en;
    reg host_bank_sel;
    reg [14:0] host_addr;
    reg signed [7:0] host_wdata;
    reg host_rd_en;
    wire host_rd_valid;
    wire signed [7:0] host_rdata;

    integer fd;
    integer scan_count;
    integer num_ops;
    integer op_idx;
    integer op;
    integer tmp_bank;
    integer tmp_expected_bank;
    integer error_count;
    integer total_checks;
    reg [14:0] tmp_addr;
    reg [7:0] tmp_data;
    reg [7:0] tmp_expected;

    feature_sram_pingpong dut (
        .clk(clk),
        .rst_n(rst_n),
        .reset_to_a(reset_to_a),
        .layer_done(layer_done),
        .input_bank_sel(input_bank_sel),
        .output_bank_sel(output_bank_sel),
        .input_rd_en(input_rd_en),
        .input_rd_addr(input_rd_addr),
        .input_rd_valid(input_rd_valid),
        .input_rd_data(input_rd_data),
        .output_wr_en(output_wr_en),
        .output_wr_addr(output_wr_addr),
        .output_wr_data(output_wr_data),
        .host_wr_en(host_wr_en),
        .host_bank_sel(host_bank_sel),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_rd_en(host_rd_en),
        .host_rd_valid(host_rd_valid),
        .host_rdata(host_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task check_banks;
        input expected_input;
        begin
            if (input_bank_sel !== expected_input || output_bank_sel !== ~expected_input) begin
                $display(
                    "MISMATCH banks expected_input=%0d actual_input=%0d actual_output=%0d",
                    expected_input,
                    input_bank_sel,
                    output_bank_sel
                );
                error_count = error_count + 1;
            end
            total_checks = total_checks + 1;
        end
    endtask

    task do_host_write;
        input bank;
        input [14:0] addr;
        input [7:0] data;
        begin
            host_bank_sel = bank;
            host_addr = addr;
            host_wdata = data;
            host_wr_en = 1'b1;
            @(posedge clk);
            #1;
            host_wr_en = 1'b0;
        end
    endtask

    task do_host_read_check;
        input bank;
        input [14:0] addr;
        input [7:0] expected;
        begin
            host_bank_sel = bank;
            host_addr = addr;
            host_rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (!host_rd_valid || host_rdata[7:0] !== expected) begin
                $display(
                    "MISMATCH host_read bank=%0d addr=%04x expected=%0d actual_valid=%0d actual=%0d",
                    bank,
                    addr,
                    $signed(expected),
                    host_rd_valid,
                    $signed(host_rdata)
                );
                error_count = error_count + 1;
            end
            host_rd_en = 1'b0;
            total_checks = total_checks + 1;
        end
    endtask

    task do_input_read_check;
        input expected_bank;
        input [14:0] addr;
        input [7:0] expected;
        begin
            if (input_bank_sel !== expected_bank) begin
                $display("MISMATCH input bank expected=%0d actual=%0d", expected_bank, input_bank_sel);
                error_count = error_count + 1;
            end
            input_rd_addr = addr;
            input_rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (!input_rd_valid || input_rd_data[7:0] !== expected) begin
                $display(
                    "MISMATCH input_read bank=%0d addr=%04x expected=%0d actual_valid=%0d actual=%0d",
                    expected_bank,
                    addr,
                    $signed(expected),
                    input_rd_valid,
                    $signed(input_rd_data)
                );
                error_count = error_count + 1;
            end
            input_rd_en = 1'b0;
            total_checks = total_checks + 1;
        end
    endtask

    task do_output_write;
        input expected_bank;
        input [14:0] addr;
        input [7:0] data;
        begin
            if (output_bank_sel !== expected_bank) begin
                $display("MISMATCH output bank expected=%0d actual=%0d", expected_bank, output_bank_sel);
                error_count = error_count + 1;
            end
            output_wr_addr = addr;
            output_wr_data = data;
            output_wr_en = 1'b1;
            @(posedge clk);
            #1;
            output_wr_en = 1'b0;
            total_checks = total_checks + 1;
        end
    endtask

    task pulse_layer_done;
        input expected_input;
        begin
            layer_done = 1'b1;
            @(posedge clk);
            #1;
            check_banks(expected_input);
            layer_done = 1'b0;
        end
    endtask

    task pulse_reset_to_a;
        input expected_input;
        begin
            reset_to_a = 1'b1;
            @(posedge clk);
            #1;
            check_banks(expected_input);
            reset_to_a = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        reset_to_a = 1'b0;
        layer_done = 1'b0;
        input_rd_en = 1'b0;
        input_rd_addr = 15'd0;
        output_wr_en = 1'b0;
        output_wr_addr = 15'd0;
        output_wr_data = 8'sd0;
        host_wr_en = 1'b0;
        host_bank_sel = 1'b0;
        host_addr = 15'd0;
        host_wdata = 8'sd0;
        host_rd_en = 1'b0;
        error_count = 0;
        total_checks = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        #1;
        check_banks(1'b0);

        fd = $fopen("tests/vectors/feature_sram_pingpong_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/feature_sram_pingpong_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_ops);

        for (op_idx = 0; op_idx < num_ops; op_idx = op_idx + 1) begin
            scan_count = $fscanf(
                fd,
                "%d %d %h %h %h %d\n",
                op,
                tmp_bank,
                tmp_addr,
                tmp_data,
                tmp_expected,
                tmp_expected_bank
            );
            if (scan_count != 6) begin
                $display("ERROR: bad feature_sram_pingpong op=%0d scan=%0d", op_idx, scan_count);
                $fatal;
            end

            if (op == 0) begin
                do_host_write(tmp_bank[0], tmp_addr, tmp_data);
            end else if (op == 1) begin
                do_host_read_check(tmp_bank[0], tmp_addr, tmp_expected);
            end else if (op == 2) begin
                do_input_read_check(tmp_bank[0], tmp_addr, tmp_expected);
            end else if (op == 3) begin
                do_output_write(tmp_bank[0], tmp_addr, tmp_data);
            end else if (op == 4) begin
                pulse_layer_done(tmp_expected_bank[0]);
            end else if (op == 5) begin
                pulse_reset_to_a(tmp_expected_bank[0]);
            end else begin
                $display("ERROR: unknown feature_sram_pingpong op=%0d", op);
                $fatal;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_feature_sram_pingpong ops=%0d checks=%0d", num_ops, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_feature_sram_pingpong checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
