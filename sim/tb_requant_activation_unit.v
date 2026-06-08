`timescale 1ns/1ps
`default_nettype none

module tb_requant_activation_unit;
    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg signed [31:0] acc_int32;
    reg signed [31:0] bias_int32;
    reg signed [31:0] multiplier_int32;
    reg [5:0] shift;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    reg ready_out;
    wire valid_out;
    wire signed [7:0] output_int8;

    integer fd;
    integer scan_count;
    integer case_count;
    integer error_count;
    reg signed [31:0] vec_acc;
    reg signed [31:0] vec_bias;
    reg signed [31:0] vec_multiplier;
    reg [7:0] vec_shift_raw;
    reg signed [31:0] vec_ozp;
    reg signed [31:0] vec_act_min;
    reg signed [31:0] vec_act_max;
    reg signed [7:0] vec_expected;

    requant_activation_unit dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .acc_int32(acc_int32),
        .bias_int32(bias_int32),
        .multiplier_int32(multiplier_int32),
        .shift(shift),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .ready_out(ready_out),
        .valid_out(valid_out),
        .output_int8(output_int8)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task run_case;
        input signed [31:0] t_acc;
        input signed [31:0] t_bias;
        input signed [31:0] t_multiplier;
        input [5:0] t_shift;
        input signed [31:0] t_ozp;
        input signed [31:0] t_act_min;
        input signed [31:0] t_act_max;
        input signed [7:0] t_expected;
        begin
            @(posedge clk);
            while (!ready_in) begin
                @(posedge clk);
            end
            acc_int32 = t_acc;
            bias_int32 = t_bias;
            multiplier_int32 = t_multiplier;
            shift = t_shift;
            output_zero_point_int32 = t_ozp;
            activation_min_int32 = t_act_min;
            activation_max_int32 = t_act_max;
            valid_in = 1'b1;
            @(posedge clk);
            valid_in = 1'b0;

            while (!valid_out) begin
                @(posedge clk);
            end
            if (output_int8 !== t_expected) begin
                $display(
                    "MISMATCH case=%0d acc=%0d bias=%0d mul=%0d shift=%0d ozp=%0d min=%0d max=%0d expected=%0d actual=%0d",
                    case_count,
                    t_acc,
                    t_bias,
                    t_multiplier,
                    t_shift,
                    t_ozp,
                    t_act_min,
                    t_act_max,
                    t_expected,
                    output_int8
                );
                error_count = error_count + 1;
            end
            case_count = case_count + 1;
        end
    endtask

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
        ready_out = 1'b1;
        case_count = 0;
        error_count = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/requant_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/requant_cases.hex");
            $finish;
        end

        while (!$feof(fd)) begin
            scan_count = $fscanf(
                fd,
                "%h %h %h %h %h %h %h %h\n",
                vec_acc,
                vec_bias,
                vec_multiplier,
                vec_shift_raw,
                vec_ozp,
                vec_act_min,
                vec_act_max,
                vec_expected
            );
            if (scan_count == 8) begin
                run_case(
                    vec_acc,
                    vec_bias,
                    vec_multiplier,
                    vec_shift_raw[5:0],
                    vec_ozp,
                    vec_act_min,
                    vec_act_max,
                    vec_expected
                );
            end
        end
        $fclose(fd);

        repeat (5) @(posedge clk);
        if (error_count == 0 && case_count > 0) begin
            $display("PASS tb_requant_activation_unit cases=%0d", case_count);
            $finish;
        end else begin
            $display("FAIL tb_requant_activation_unit cases=%0d errors=%0d", case_count, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
