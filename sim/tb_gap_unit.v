`timescale 1ns/1ps
`default_nettype none

module tb_gap_unit;
    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg signed [(4*4*256*8)-1:0] feature_in;
    wire signed [(256*8)-1:0] gap_out;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer y;
    integer x;
    integer c;
    integer total_checks;
    integer error_count;
    reg signed [7:0] tmp_i8;
    reg signed [7:0] expected [0:255];
    reg signed [7:0] actual;

    gap_unit dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .feature_in(feature_in),
        .gap_out(gap_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task pulse_start_and_wait_done;
        begin
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            while (!done) begin
                @(posedge clk);
            end
            @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        start = 1'b0;
        feature_in = 0;
        total_checks = 0;
        error_count = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/gap_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/gap_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            feature_in = 0;
            for (y = 0; y < 4; y = y + 1) begin
                for (x = 0; x < 4; x = x + 1) begin
                    for (c = 0; c < 256; c = c + 1) begin
                        scan_count = $fscanf(fd, "%h\n", tmp_i8);
                        feature_in[(((y*4*256) + (x*256) + c)*8) +: 8] = tmp_i8;
                    end
                end
            end
            for (c = 0; c < 256; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", expected[c]);
            end

            pulse_start_and_wait_done();

            for (c = 0; c < 256; c = c + 1) begin
                actual = gap_out[(c*8) +: 8];
                if (actual !== expected[c]) begin
                    $display("MISMATCH case=%0d c=%0d expected=%0d actual=%0d", case_idx, c, expected[c], actual);
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_gap_unit cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_gap_unit checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
