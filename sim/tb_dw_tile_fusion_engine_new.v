`timescale 1ns/1ps
`default_nettype none

module tb_dw_tile_fusion_engine_new;
    localparam DW_LANES = 16;
    localparam MAX_INPUT_PIXELS = 289;
    localparam MAX_EXPECTED = 1024;

    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg [4:0] x_idx;
    reg [4:0] y_idx;
    reg signed [(DW_LANES*8)-1:0] pixel_vec_in;
    reg [3:0] out_h;
    reg [3:0] out_w;
    reg [1:0] stride;
    reg [6:0] channel_base;
    reg signed [(DW_LANES*9*8)-1:0] weight_vec;
    reg signed [(DW_LANES*32)-1:0] bias_vec;
    reg signed [(DW_LANES*32)-1:0] multiplier_vec;
    reg [(DW_LANES*6)-1:0] shift_vec;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;
    reg ready_out;
    wire valid_out;
    wire [5:0] out_pixel_idx;
    wire [6:0] out_channel_idx;
    wire signed [7:0] out_data_int8;
    wire busy;
    wire done;

    reg [127:0] input_pixels [0:MAX_INPUT_PIXELS-1];
    reg [5:0] expected_pixel [0:MAX_EXPECTED-1];
    reg [6:0] expected_channel [0:MAX_EXPECTED-1];
    reg signed [7:0] expected_data [0:MAX_EXPECTED-1];

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer in_h;
    integer in_w;
    integer input_count;
    integer input_idx;
    integer expected_count;
    integer expected_idx;
    integer initial_stall_cycles;
    integer case_cycle;
    integer timeout_cycles;
    integer error_count;
    reg case_active;

    dw_tile_fusion_engine_new #(
        .DW_LANES(DW_LANES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .x_idx(x_idx),
        .y_idx(y_idx),
        .pixel_vec_in(pixel_vec_in),
        .out_h(out_h),
        .out_w(out_w),
        .stride(stride),
        .channel_base(channel_base),
        .weight_vec(weight_vec),
        .bias_vec(bias_vec),
        .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point(output_zero_point),
        .activation_min(activation_min),
        .activation_max(activation_max),
        .ready_out(ready_out),
        .valid_out(valid_out),
        .out_pixel_idx(out_pixel_idx),
        .out_channel_idx(out_channel_idx),
        .out_data_int8(out_data_int8),
        .busy(busy),
        .done(done)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(negedge clk) begin
        if (!rst_n || !case_active) begin
            ready_out = 1'b1;
            case_cycle = 0;
        end else begin
            case_cycle = case_cycle + 1;
            if (case_cycle <= initial_stall_cycles) begin
                ready_out = 1'b0;
            end else begin
                ready_out = ((case_cycle % 13) != 0) &&
                            ((case_cycle % 17) != 0);
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && valid_out && ready_out) begin
            if (expected_idx >= expected_count) begin
                $display(
                    "MISMATCH case=%0d unexpected output p=%0d c=%0d data=%0d",
                    case_idx,
                    out_pixel_idx,
                    out_channel_idx,
                    out_data_int8
                );
                error_count = error_count + 1;
            end else begin
                if (out_pixel_idx !== expected_pixel[expected_idx] ||
                    out_channel_idx !== expected_channel[expected_idx] ||
                    out_data_int8 !== expected_data[expected_idx]) begin
                    $display(
                        "MISMATCH case=%0d output=%0d expected=(p%0d,c%0d,%0d) actual=(p%0d,c%0d,%0d)",
                        case_idx,
                        expected_idx,
                        expected_pixel[expected_idx],
                        expected_channel[expected_idx],
                        expected_data[expected_idx],
                        out_pixel_idx,
                        out_channel_idx,
                        out_data_int8
                    );
                    error_count = error_count + 1;
                end
            end
            expected_idx = expected_idx + 1;
        end
    end

    task reset_dut;
        begin
            case_active = 1'b0;
            valid_in = 1'b0;
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    task feed_input_pixels;
        integer feed_y;
        integer feed_x;
        integer feed_addr;
        begin
            feed_addr = 0;
            for (feed_y = 0; feed_y < in_h; feed_y = feed_y + 1) begin
                for (feed_x = 0; feed_x < in_w; feed_x = feed_x + 1) begin
                    @(negedge clk);
                    valid_in = 1'b1;
                    x_idx = feed_x[4:0];
                    y_idx = feed_y[4:0];
                    pixel_vec_in = input_pixels[feed_addr];
                    while (!ready_in) begin
                        @(negedge clk);
                    end
                    @(posedge clk);
                    feed_addr = feed_addr + 1;
                end
            end
            @(negedge clk);
            valid_in = 1'b0;
            pixel_vec_in = {DW_LANES*8{1'b0}};
        end
    endtask

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        x_idx = 5'd0;
        y_idx = 5'd0;
        pixel_vec_in = {DW_LANES*8{1'b0}};
        out_h = 4'd0;
        out_w = 4'd0;
        stride = 2'd1;
        channel_base = 7'd0;
        weight_vec = {(DW_LANES*9*8){1'b0}};
        bias_vec = {(DW_LANES*32){1'b0}};
        multiplier_vec = {(DW_LANES*32){1'b0}};
        shift_vec = {(DW_LANES*6){1'b0}};
        output_zero_point = 32'sd0;
        activation_min = -32'sd128;
        activation_max = 32'sd127;
        ready_out = 1'b1;
        case_active = 1'b0;
        case_cycle = 0;
        expected_idx = 0;
        expected_count = 0;
        error_count = 0;

        fd = $fopen("tests/vectors/dw_stream_engine_cases.hex", "r");
        if (fd == 0) begin
            $display(
                "ERROR: cannot open tests/vectors/dw_stream_engine_cases.hex"
            );
            $fatal;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: missing streaming DW case count");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            scan_count = $fscanf(
                fd,
                "%d %d %d %d %d %d %h %h %h %d %d\n",
                out_h,
                out_w,
                in_h,
                in_w,
                stride,
                channel_base,
                output_zero_point,
                activation_min,
                activation_max,
                initial_stall_cycles,
                expected_count
            );
            if (scan_count != 11) begin
                $display(
                    "ERROR: bad streaming DW header case=%0d fields=%0d",
                    case_idx,
                    scan_count
                );
                $fatal;
            end

            input_count = in_h * in_w;
            for (input_idx = 0;
                 input_idx < input_count;
                 input_idx = input_idx + 1) begin
                scan_count = $fscanf(fd, "%h\n", input_pixels[input_idx]);
                if (scan_count != 1) begin
                    $display(
                        "ERROR: missing input case=%0d index=%0d",
                        case_idx,
                        input_idx
                    );
                    $fatal;
                end
            end
            scan_count = $fscanf(fd, "%h\n", weight_vec);
            scan_count = $fscanf(fd, "%h\n", bias_vec);
            scan_count = $fscanf(fd, "%h\n", multiplier_vec);
            scan_count = $fscanf(fd, "%h\n", shift_vec);
            for (input_idx = 0;
                 input_idx < expected_count;
                 input_idx = input_idx + 1) begin
                scan_count = $fscanf(
                    fd,
                    "%d %d %h\n",
                    expected_pixel[input_idx],
                    expected_channel[input_idx],
                    expected_data[input_idx]
                );
                if (scan_count != 3) begin
                    $display(
                        "ERROR: missing expected case=%0d index=%0d",
                        case_idx,
                        input_idx
                    );
                    $fatal;
                end
            end

            reset_dut();
            expected_idx = 0;
            case_cycle = 0;
            case_active = 1'b1;
            feed_input_pixels();

            timeout_cycles = 0;
            while (!done && timeout_cycles < 20000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            case_active = 1'b0;

            if (!done) begin
                $display("MISMATCH case=%0d timed out", case_idx);
                error_count = error_count + 1;
            end
            if (expected_idx != expected_count) begin
                $display(
                    "MISMATCH case=%0d expected_count=%0d received=%0d",
                    case_idx,
                    expected_count,
                    expected_idx
                );
                error_count = error_count + 1;
            end
            if (busy) begin
                @(posedge clk);
            end
        end
        $fclose(fd);

        if (error_count == 0 && num_cases > 0) begin
            $display(
                "PASS tb_dw_tile_fusion_engine_new cases=%0d",
                num_cases
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_dw_tile_fusion_engine_new cases=%0d errors=%0d",
                num_cases,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
