`timescale 1ns/1ps
`default_nettype none

module tb_requant_activation_pipeline;
    localparam MAX_CASES = 256;

    reg clk;
    reg rst_n;
    reg valid_in;
    reg signed [31:0] acc_int32;
    reg signed [31:0] bias_int32;
    reg signed [31:0] multiplier_int32;
    reg [5:0] shift;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    wire valid_out;
    wire signed [7:0] output_int8;

    reg signed [31:0] case_acc [0:MAX_CASES-1];
    reg signed [31:0] case_bias [0:MAX_CASES-1];
    reg signed [31:0] case_multiplier [0:MAX_CASES-1];
    reg [5:0] case_shift [0:MAX_CASES-1];
    reg signed [31:0] case_ozp [0:MAX_CASES-1];
    reg signed [31:0] case_act_min [0:MAX_CASES-1];
    reg signed [31:0] case_act_max [0:MAX_CASES-1];
    reg signed [7:0] case_expected [0:MAX_CASES-1];

    integer fd;
    integer scan_count;
    integer case_count;
    integer drive_idx;
    integer receive_idx;
    integer error_count;
    integer timeout_cycles;
    reg [7:0] shift_raw;

    requant_activation_pipeline dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .acc_int32(acc_int32),
        .bias_int32(bias_int32),
        .multiplier_int32(multiplier_int32),
        .shift(shift),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .valid_out(valid_out),
        .output_int8(output_int8)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (rst_n && valid_out) begin
            if (receive_idx >= case_count) begin
                $display("MISMATCH unexpected pipeline output=%0d", output_int8);
                error_count = error_count + 1;
            end else if (output_int8 !== case_expected[receive_idx]) begin
                $display(
                    "MISMATCH case=%0d expected=%0d actual=%0d",
                    receive_idx,
                    case_expected[receive_idx],
                    output_int8
                );
                error_count = error_count + 1;
            end
            receive_idx = receive_idx + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        acc_int32 = 32'sd0;
        bias_int32 = 32'sd0;
        multiplier_int32 = 32'sd0;
        shift = 6'd0;
        output_zero_point_int32 = 32'sd0;
        activation_min_int32 = -32'sd128;
        activation_max_int32 = 32'sd127;
        case_count = 0;
        receive_idx = 0;
        error_count = 0;

        fd = $fopen("tests/vectors/requant_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/requant_cases.hex");
            $fatal;
        end

        while (!$feof(fd) && case_count < MAX_CASES) begin
            scan_count = $fscanf(
                fd,
                "%h %h %h %h %h %h %h %h\n",
                case_acc[case_count],
                case_bias[case_count],
                case_multiplier[case_count],
                shift_raw,
                case_ozp[case_count],
                case_act_min[case_count],
                case_act_max[case_count],
                case_expected[case_count]
            );
            if (scan_count == 8) begin
                case_shift[case_count] = shift_raw[5:0];
                case_count = case_count + 1;
            end
        end
        $fclose(fd);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        for (drive_idx = 0; drive_idx < case_count; drive_idx = drive_idx + 1) begin
            @(negedge clk);
            valid_in = 1'b1;
            acc_int32 = case_acc[drive_idx];
            bias_int32 = case_bias[drive_idx];
            multiplier_int32 = case_multiplier[drive_idx];
            shift = case_shift[drive_idx];
            output_zero_point_int32 = case_ozp[drive_idx];
            activation_min_int32 = case_act_min[drive_idx];
            activation_max_int32 = case_act_max[drive_idx];
        end

        @(negedge clk);
        valid_in = 1'b0;

        timeout_cycles = 0;
        while (receive_idx < case_count && timeout_cycles < 64) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end

        if (receive_idx != case_count) begin
            $display(
                "MISMATCH pipeline drain expected=%0d received=%0d",
                case_count,
                receive_idx
            );
            error_count = error_count + 1;
        end

        if (error_count == 0 && case_count > 0) begin
            $display(
                "PASS tb_requant_activation_pipeline cases=%0d",
                case_count
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_requant_activation_pipeline cases=%0d errors=%0d",
                case_count,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
