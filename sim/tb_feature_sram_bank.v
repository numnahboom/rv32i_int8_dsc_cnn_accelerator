`timescale 1ns/1ps
`default_nettype none

module tb_feature_sram_bank;
    reg clk;
    reg rst_n;
    reg wr_en;
    reg [14:0] wr_addr;
    reg signed [7:0] wr_data;
    reg rd_en;
    reg [14:0] rd_addr;
    wire rd_valid;
    wire signed [7:0] rd_data;

    integer fd;
    integer scan_count;
    integer num_ops;
    integer op_idx;
    integer op;
    integer error_count;
    integer total_checks;
    reg [14:0] tmp_addr;
    reg [7:0] tmp_data;
    reg [7:0] tmp_expected;

    feature_sram_bank dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_en(rd_en),
        .rd_addr(rd_addr),
        .rd_valid(rd_valid),
        .rd_data(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task do_write;
        input [14:0] addr;
        input [7:0] data;
        begin
            wr_addr = addr;
            wr_data = data;
            wr_en = 1'b1;
            @(posedge clk);
            #1;
            wr_en = 1'b0;
        end
    endtask

    task do_read_check;
        input [14:0] addr;
        input [7:0] expected;
        begin
            rd_addr = addr;
            rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (!rd_valid || rd_data[7:0] !== expected) begin
                $display(
                    "MISMATCH read addr=%04x expected=%0d actual_valid=%0d actual=%0d",
                    addr,
                    $signed(expected),
                    rd_valid,
                    $signed(rd_data)
                );
                error_count = error_count + 1;
            end
            rd_en = 1'b0;
            total_checks = total_checks + 1;
        end
    endtask

    task do_write_read_same_check;
        input [14:0] addr;
        input [7:0] data;
        input [7:0] expected;
        begin
            wr_addr = addr;
            wr_data = data;
            wr_en = 1'b1;
            rd_addr = addr;
            rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (!rd_valid || rd_data[7:0] !== expected) begin
                $display(
                    "MISMATCH same-cycle addr=%04x expected=%0d actual_valid=%0d actual=%0d",
                    addr,
                    $signed(expected),
                    rd_valid,
                    $signed(rd_data)
                );
                error_count = error_count + 1;
            end
            wr_en = 1'b0;
            rd_en = 1'b0;
            total_checks = total_checks + 1;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_addr = 15'd0;
        wr_data = 8'sd0;
        rd_en = 1'b0;
        rd_addr = 15'd0;
        error_count = 0;
        total_checks = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/feature_sram_bank_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/feature_sram_bank_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_ops);

        for (op_idx = 0; op_idx < num_ops; op_idx = op_idx + 1) begin
            scan_count = $fscanf(fd, "%d %h %h %h\n", op, tmp_addr, tmp_data, tmp_expected);
            if (scan_count != 4) begin
                $display("ERROR: bad feature_sram_bank op=%0d scan=%0d", op_idx, scan_count);
                $fatal;
            end

            if (op == 0) begin
                do_write(tmp_addr, tmp_data);
            end else if (op == 1) begin
                do_read_check(tmp_addr, tmp_expected);
            end else if (op == 2) begin
                do_write_read_same_check(tmp_addr, tmp_data, tmp_expected);
            end else begin
                $display("ERROR: unknown feature_sram_bank op=%0d", op);
                $fatal;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_feature_sram_bank ops=%0d checks=%0d", num_ops, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_feature_sram_bank checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
