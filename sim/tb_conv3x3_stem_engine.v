`timescale 1ns/1ps
`default_nettype none

module tb_conv3x3_stem_engine;
    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg [3:0] out_h;
    reg [3:0] out_w;
    reg signed [7:0] input_zero_point;
    reg signed [(10*10*3*8)-1:0] input_tile;
    reg signed [(16*27*8)-1:0] stem_weight;
    reg signed [(16*32)-1:0] stem_bias;
    reg signed [(16*32)-1:0] stem_multiplier;
    reg [(16*8)-1:0] stem_shift;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [3:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer y;
    integer x;
    integer ci;
    integer co;
    integer k;
    integer p;
    integer out_pixels;
    integer total_checks;
    integer error_count;
    reg signed [7:0] tmp_i8;
    reg signed [31:0] tmp_i32;
    reg [7:0] tmp_u8;
    reg signed [7:0] expected_mem [0:1023];
    reg signed [7:0] actual_mem [0:1023];
    integer idx;

    conv3x3_stem_engine dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .out_h(out_h),
        .out_w(out_w),
        .input_zero_point(input_zero_point),
        .input_tile(input_tile),
        .stem_weight(stem_weight),
        .stem_bias(stem_bias),
        .stem_multiplier(stem_multiplier),
        .stem_shift(stem_shift),
        .output_zero_point(output_zero_point),
        .activation_min(activation_min),
        .activation_max(activation_max),
        .out_wr_en(out_wr_en),
        .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_idx(out_wr_channel_idx),
        .out_wr_data_int8(out_wr_data_int8)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (out_wr_en) begin
            actual_mem[out_wr_pixel_idx * 16 + out_wr_channel_idx] <= out_wr_data_int8;
        end
    end

    task clear_case_regs;
        begin
            input_tile = 0;
            stem_weight = 0;
            stem_bias = 0;
            stem_multiplier = 0;
            stem_shift = 0;
            for (idx = 0; idx < 1024; idx = idx + 1) begin
                expected_mem[idx] = 8'sd0;
                actual_mem[idx] = 8'sd0;
            end
        end
    endtask

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
        out_h = 4'd0;
        out_w = 4'd0;
        input_zero_point = 8'sd0;
        output_zero_point = 32'sd0;
        activation_min = 32'sd0;
        activation_max = 32'sd48;
        total_checks = 0;
        error_count = 0;
        clear_case_regs();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/stem_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/stem_cases.hex");
            $finish;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: missing stem case count");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            clear_case_regs();
            scan_count = $fscanf(
                fd,
                "%d %d %h %h %h %h\n",
                out_h,
                out_w,
                input_zero_point,
                output_zero_point,
                activation_min,
                activation_max
            );
            if (scan_count != 6) begin
                $display("ERROR: bad stem header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end

            for (y = 0; y < 10; y = y + 1) begin
                for (x = 0; x < 10; x = x + 1) begin
                    for (ci = 0; ci < 3; ci = ci + 1) begin
                        scan_count = $fscanf(fd, "%h\n", tmp_i8);
                        input_tile[(((y*10*3) + (x*3) + ci)*8) +: 8] = tmp_i8;
                    end
                end
            end

            for (co = 0; co < 16; co = co + 1) begin
                for (k = 0; k < 27; k = k + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    stem_weight[((co*27 + k)*8) +: 8] = tmp_i8;
                end
            end
            for (co = 0; co < 16; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                stem_bias[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < 16; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                stem_multiplier[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < 16; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                stem_shift[(co*8) +: 8] = tmp_u8;
            end

            out_pixels = out_h * out_w;
            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < 16; co = co + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    expected_mem[p*16 + co] = tmp_i8;
                end
            end

            pulse_start_and_wait_done();

            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < 16; co = co + 1) begin
                    if (actual_mem[p*16 + co] !== expected_mem[p*16 + co]) begin
                        $display(
                            "MISMATCH case=%0d p=%0d co=%0d expected=%0d actual=%0d",
                            case_idx,
                            p,
                            co,
                            expected_mem[p*16 + co],
                            actual_mem[p*16 + co]
                        );
                        error_count = error_count + 1;
                    end
                    total_checks = total_checks + 1;
                end
            end
        end

        $fclose(fd);
        repeat (5) @(posedge clk);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_conv3x3_stem_engine cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_conv3x3_stem_engine checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
