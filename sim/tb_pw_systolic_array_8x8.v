`timescale 1ns/1ps
`default_nettype none

module tb_pw_systolic_array_8x8;
    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg clear_acc;
    reg k_last;
    reg signed [63:0] act_vec;
    reg signed [63:0] wgt_vec;
    reg ready_out;
    wire valid_out;
    wire signed [2047:0] psum_out;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer cin;
    integer k;
    integer m;
    integer n;
    integer error_count;
    integer total_checks;
    reg [63:0] vec_act;
    reg [63:0] vec_wgt;
    reg signed [31:0] expected;
    reg signed [31:0] actual;

    pw_systolic_array_8x8 dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .clear_acc(clear_acc),
        .k_last(k_last),
        .act_vec(act_vec),
        .wgt_vec(wgt_vec),
        .ready_out(ready_out),
        .valid_out(valid_out),
        .psum_out(psum_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task feed_k;
        input [63:0] t_act;
        input [63:0] t_wgt;
        input t_clear;
        input t_last;
        begin
            @(posedge clk);
            while (!ready_in) begin
                @(posedge clk);
            end
            act_vec = t_act;
            wgt_vec = t_wgt;
            clear_acc = t_clear;
            k_last = t_last;
            valid_in = 1'b1;
            @(posedge clk);
            valid_in = 1'b0;
            clear_acc = 1'b0;
            k_last = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        clear_acc = 1'b0;
        k_last = 1'b0;
        act_vec = 64'sd0;
        wgt_vec = 64'sd0;
        ready_out = 1'b1;
        error_count = 0;
        total_checks = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/pw_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/pw_cases.hex");
            $finish;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: missing case count in pw_cases.hex");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            scan_count = $fscanf(fd, "%d\n", cin);
            if (scan_count != 1) begin
                $display("ERROR: missing Cin for case %0d", case_idx);
                $fatal;
            end

            for (k = 0; k < cin; k = k + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", vec_act, vec_wgt);
                if (scan_count != 2) begin
                    $display("ERROR: missing vectors for case=%0d k=%0d", case_idx, k);
                    $fatal;
                end
                feed_k(vec_act, vec_wgt, (k == 0), (k == (cin - 1)));
            end

            while (!valid_out) begin
                @(posedge clk);
            end

            for (m = 0; m < 8; m = m + 1) begin
                for (n = 0; n < 8; n = n + 1) begin
                    scan_count = $fscanf(fd, "%h\n", expected);
                    if (scan_count != 1) begin
                        $display("ERROR: missing expected case=%0d m=%0d n=%0d", case_idx, m, n);
                        $fatal;
                    end
                    actual = psum_out[((m*8 + n)*32) +: 32];
                    if (actual !== expected) begin
                        $display(
                            "MISMATCH case=%0d m=%0d n=%0d cin=%0d expected=%0d actual=%0d",
                            case_idx,
                            m,
                            n,
                            cin,
                            expected,
                            actual
                        );
                        error_count = error_count + 1;
                    end
                    total_checks = total_checks + 1;
                end
            end
            @(posedge clk);
        end

        $fclose(fd);
        repeat (5) @(posedge clk);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_pw_systolic_array_8x8 cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_pw_systolic_array_8x8 checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
