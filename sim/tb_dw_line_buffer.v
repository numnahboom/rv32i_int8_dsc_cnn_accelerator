`timescale 1ns/1ps
`default_nettype none

module tb_dw_line_buffer;
    reg clk;
    reg rst_n;
    reg valid_in;
    reg ready_out;
    reg [4:0] x_idx;
    reg [4:0] y_idx;
    reg [127:0] pixel_vec_in;
    wire ready_in;
    wire window_valid;
    wire [127:0] row0_col0;
    wire [127:0] row0_col1;
    wire [127:0] row0_col2;
    wire [127:0] row1_col0;
    wire [127:0] row1_col1;
    wire [127:0] row1_col2;
    wire [127:0] row2_col0;
    wire [127:0] row2_col1;
    wire [127:0] row2_col2;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer error_count;
    integer total_checks;
    reg [127:0] expected_row0_col0;
    reg [127:0] expected_row0_col1;
    reg [127:0] expected_row0_col2;
    reg [127:0] expected_row1_col0;
    reg [127:0] expected_row1_col1;
    reg [127:0] expected_row1_col2;
    reg [127:0] expected_row2_col0;
    reg [127:0] expected_row2_col1;
    reg [127:0] expected_row2_col2;
    reg vec_expected_ready;
    reg vec_expected_valid;

    dw_line_buffer dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_out(ready_out),
        .x_idx(x_idx),
        .y_idx(y_idx),
        .pixel_vec_in(pixel_vec_in),
        .ready_in(ready_in),
        .window_valid(window_valid),
        .row0_col0(row0_col0),
        .row0_col1(row0_col1),
        .row0_col2(row0_col2),
        .row1_col0(row1_col0),
        .row1_col1(row1_col1),
        .row1_col2(row1_col2),
        .row2_col0(row2_col0),
        .row2_col1(row2_col1),
        .row2_col2(row2_col2)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        ready_out = 1'b1;
        x_idx = 0;
        y_idx = 0;
        pixel_vec_in = 0;
        error_count = 0;
        total_checks = 0;

        #20;
        rst_n = 1'b1;

        @(negedge clk);

        fd = $fopen("tests/vectors/dw_line_buffer_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/dw_line_buffer_cases.hex");
            $fatal;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: failed to read number of line-buffer cycles");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            scan_count = $fscanf(
                fd,
                "%d %d %d %d %h %d %d %h %h %h %h %h %h %h %h %h\n",
                valid_in,
                ready_out,
                x_idx,
                y_idx,
                pixel_vec_in,
                vec_expected_ready,
                vec_expected_valid,
                expected_row0_col0,
                expected_row0_col1,
                expected_row0_col2,
                expected_row1_col0,
                expected_row1_col1,
                expected_row1_col2,
                expected_row2_col0,
                expected_row2_col1,
                expected_row2_col2
            );

            if (scan_count != 16) begin
                $display(
                    "ERROR: failed to read line-buffer cycle=%0d fields=%0d",
                    case_idx,
                    scan_count
                );
                $fatal;
            end

            #1;
            if (ready_in !== vec_expected_ready) begin
                $display("Test case %0d: ready_in mismatch. Expected: %b, Got: %b", case_idx, vec_expected_ready, ready_in);
                error_count = error_count + 1;
            end

            @(posedge clk);
            #1;

            if (window_valid !== vec_expected_valid) begin
                $display("Test case %0d: window_valid mismatch. Expected: %b, Got: %b", case_idx, vec_expected_valid, window_valid);
                error_count = error_count + 1;
            end

            if (vec_expected_valid) begin
                if (row0_col0 !== expected_row0_col0) begin
                    $display("Test case %0d: row0_col0 mismatch. Expected: %h, Got: %h", case_idx, expected_row0_col0, row0_col0);
                    error_count = error_count + 1;
                end
                if (row0_col1 !== expected_row0_col1) begin
                    $display("Test case %0d: row0_col1 mismatch. Expected: %h, Got: %h", case_idx, expected_row0_col1, row0_col1);
                    error_count = error_count + 1;
                end
                if (row0_col2 !== expected_row0_col2) begin
                    $display("Test case %0d: row0_col2 mismatch. Expected: %h, Got: %h", case_idx, expected_row0_col2, row0_col2);
                    error_count = error_count + 1;
                end
                if (row1_col0 !== expected_row1_col0) begin
                    $display("Test case %0d: row1_col0 mismatch. Expected: %h, Got: %h", case_idx, expected_row1_col0, row1_col0);
                    error_count = error_count + 1;
                end
                if (row1_col1 !== expected_row1_col1) begin
                    $display("Test case %0d: row1_col1 mismatch. Expected: %h, Got: %h", case_idx, expected_row1_col1, row1_col1);
                    error_count = error_count + 1;
                end
                if (row1_col2 !== expected_row1_col2) begin
                    $display("Test case %0d: row1_col2 mismatch. Expected: %h, Got: %h", case_idx, expected_row1_col2, row1_col2);
                    error_count = error_count + 1;
                end
                if (row2_col0 !== expected_row2_col0) begin
                    $display("Test case %0d: row2_col0 mismatch. Expected: %h, Got: %h", case_idx, expected_row2_col0, row2_col0);
                    error_count = error_count + 1;
                end
                if (row2_col1 !== expected_row2_col1) begin
                    $display("Test case %0d: row2_col1 mismatch. Expected: %h, Got: %h", case_idx, expected_row2_col1, row2_col1);
                    error_count = error_count + 1;
                end
                if (row2_col2 !== expected_row2_col2) begin
                    $display("Test case %0d: row2_col2 mismatch. Expected: %h, Got: %h", case_idx, expected_row2_col2, row2_col2);
                    error_count = error_count + 1;
                end
            end
            total_checks = total_checks + 1;
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display(
                "PASS tb_dw_line_buffer cycles=%0d checks=%0d",
                num_cases,
                total_checks
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_dw_line_buffer checks=%0d errors=%0d",
                total_checks,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
