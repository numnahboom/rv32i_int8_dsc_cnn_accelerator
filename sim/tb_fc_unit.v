`timescale 1ns/1ps
`default_nettype none

module tb_fc_unit;
    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg signed [(256*8)-1:0] input_vec;
    reg signed [(10*256*8)-1:0] fc_weight;
    reg signed [(10*32)-1:0] fc_bias;
    reg signed [(10*32)-1:0] fc_multiplier;
    reg [(10*8)-1:0] fc_shift;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    wire signed [(10*8)-1:0] logits;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer ci;
    integer co;
    integer total_checks;
    integer error_count;
    reg signed [7:0] tmp_i8;
    reg signed [31:0] tmp_i32;
    reg [7:0] tmp_u8;
    reg signed [7:0] expected [0:9];
    reg signed [7:0] actual;

    fc_unit dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .input_vec(input_vec),
        .fc_weight(fc_weight),
        .fc_bias(fc_bias),
        .fc_multiplier(fc_multiplier),
        .fc_shift(fc_shift),
        .output_zero_point(output_zero_point),
        .activation_min(activation_min),
        .activation_max(activation_max),
        .logits(logits)
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
        input_vec = 0;
        fc_weight = 0;
        fc_bias = 0;
        fc_multiplier = 0;
        fc_shift = 0;
        output_zero_point = 32'sd0;
        activation_min = -32'sd128;
        activation_max = 32'sd127;
        total_checks = 0;
        error_count = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/fc_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/fc_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            input_vec = 0;
            fc_weight = 0;
            fc_bias = 0;
            fc_multiplier = 0;
            fc_shift = 0;
            scan_count = $fscanf(fd, "%h %h %h\n", output_zero_point, activation_min, activation_max);
            for (ci = 0; ci < 256; ci = ci + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i8);
                input_vec[(ci*8) +: 8] = tmp_i8;
            end
            for (co = 0; co < 10; co = co + 1) begin
                for (ci = 0; ci < 256; ci = ci + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    fc_weight[((co*256 + ci)*8) +: 8] = tmp_i8;
                end
            end
            for (co = 0; co < 10; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                fc_bias[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < 10; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                fc_multiplier[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < 10; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                fc_shift[(co*8) +: 8] = tmp_u8;
            end
            for (co = 0; co < 10; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", expected[co]);
            end

            pulse_start_and_wait_done();

            for (co = 0; co < 10; co = co + 1) begin
                actual = logits[(co*8) +: 8];
                if (actual !== expected[co]) begin
                    $display("MISMATCH case=%0d co=%0d expected=%0d actual=%0d", case_idx, co, expected[co], actual);
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_fc_unit cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_fc_unit checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
