`timescale 1ns/1ps
`default_nettype none

module tb_dw_tile_fusion_engine;
    localparam MAX_CIN = 128;
    localparam MAX_IN_H = 17;
    localparam MAX_IN_W = 17;
    localparam DW_LANES = 16;

    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg [3:0] out_h;
    reg [3:0] out_w;
    reg [7:0] channels;
    reg [1:0] stride;
    reg signed [7:0] input_zero_point;
    reg signed [(MAX_IN_H*MAX_IN_W*MAX_CIN*8)-1:0] input_tile;
    reg signed [(MAX_CIN*9*8)-1:0] dw_weight;
    reg signed [(MAX_CIN*32)-1:0] dw_bias;
    reg signed [(MAX_CIN*32)-1:0] dw_multiplier;
    reg [(MAX_CIN*8)-1:0] dw_shift;
    reg signed [31:0] dw_output_zero_point;
    reg signed [31:0] activation_min;
    reg signed [31:0] activation_max;

    wire [DW_LANES-1:0] buf_wr_en_vec;
    wire [5:0] buf_wr_pixel_idx;
    wire [6:0] buf_wr_channel_base;
    wire signed [(DW_LANES*8)-1:0] buf_wr_data_vec;
    reg rd_en;
    reg [5:0] rd_pixel_base;
    reg [6:0] rd_channel_idx;
    wire signed [63:0] rd_data_vector;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer in_h;
    integer in_w;
    integer y;
    integer x;
    integer c;
    integer k;
    integer p;
    integer pbase;
    integer lane;
    integer out_pixels;
    integer total_checks;
    integer error_count;
    reg signed [7:0] tmp_i8;
    reg signed [31:0] tmp_i32;
    reg [7:0] tmp_u8;
    reg signed [7:0] expected_mem [0:8191];
    reg signed [7:0] actual;
    reg signed [7:0] expected;

    dw_tile_fusion_engine #(
        .MAX_CIN(MAX_CIN),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W),
        .DW_LANES(DW_LANES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .out_h(out_h),
        .out_w(out_w),
        .channels(channels),
        .stride(stride),
        .input_zero_point(input_zero_point),
        .input_tile(input_tile),
        .dw_weight(dw_weight),
        .dw_bias(dw_bias),
        .dw_multiplier(dw_multiplier),
        .dw_shift(dw_shift),
        .dw_output_zero_point(dw_output_zero_point),
        .activation_min(activation_min),
        .activation_max(activation_max),
        .buf_wr_en_vec(buf_wr_en_vec),
        .buf_wr_pixel_idx(buf_wr_pixel_idx),
        .buf_wr_channel_base(buf_wr_channel_base),
        .buf_wr_data_vec(buf_wr_data_vec)
    );

    dw_tile_buffer #(
        .WRITE_LANES(DW_LANES)
    ) u_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en_vec(buf_wr_en_vec),
        .wr_pixel_idx(buf_wr_pixel_idx),
        .wr_channel_base(buf_wr_channel_base),
        .wr_data_vec(buf_wr_data_vec),
        .rd_en(rd_en),
        .rd_pixel_base(rd_pixel_base),
        .rd_channel_idx(rd_channel_idx),
        .rd_data_vector(rd_data_vector)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task clear_case_regs;
        integer idx;
        begin
            input_tile = 0;
            dw_weight = 0;
            dw_bias = 0;
            dw_multiplier = 0;
            dw_shift = 0;
            for (idx = 0; idx < 8192; idx = idx + 1) begin
                expected_mem[idx] = 8'sd0;
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

    task read_buffer_vector;
        input [5:0] t_pixel_base;
        input [6:0] t_channel;
        begin
            rd_pixel_base = t_pixel_base;
            rd_channel_idx = t_channel;
            rd_en = 1'b1;
            @(posedge clk);
            rd_en = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        start = 1'b0;
        out_h = 4'd0;
        out_w = 4'd0;
        channels = 8'd0;
        stride = 2'd1;
        input_zero_point = 8'sd0;
        dw_output_zero_point = 32'sd0;
        activation_min = -32'sd128;
        activation_max = 32'sd127;
        rd_en = 1'b0;
        rd_pixel_base = 6'd0;
        rd_channel_idx = 7'd0;
        total_checks = 0;
        error_count = 0;
        clear_case_regs();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/dw_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/dw_cases.hex");
            $finish;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: missing DW case count");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            clear_case_regs();
            scan_count = $fscanf(
                fd,
                "%d %d %d %d %d %d %h %h %h %h\n",
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                stride,
                input_zero_point,
                dw_output_zero_point,
                activation_min,
                activation_max
            );
            if (scan_count != 10) begin
                $display("ERROR: bad DW case header %0d scan=%0d", case_idx, scan_count);
                $fatal;
            end

            for (y = 0; y < MAX_IN_H; y = y + 1) begin
                for (x = 0; x < MAX_IN_W; x = x + 1) begin
                    for (c = 0; c < channels; c = c + 1) begin
                        scan_count = $fscanf(fd, "%h\n", tmp_i8);
                        if (scan_count != 1) begin
                            $display("ERROR: missing input case=%0d y=%0d x=%0d c=%0d", case_idx, y, x, c);
                            $fatal;
                        end
                        input_tile[(((y*MAX_IN_W*MAX_CIN) + (x*MAX_CIN) + c)*8) +: 8] = tmp_i8;
                    end
                end
            end

            for (c = 0; c < channels; c = c + 1) begin
                for (k = 0; k < 9; k = k + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    if (scan_count != 1) begin
                        $display("ERROR: missing weight case=%0d c=%0d k=%0d", case_idx, c, k);
                        $fatal;
                    end
                    dw_weight[((c*9 + k)*8) +: 8] = tmp_i8;
                end
            end

            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                dw_bias[(c*32) +: 32] = tmp_i32;
            end
            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                dw_multiplier[(c*32) +: 32] = tmp_i32;
            end
            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                dw_shift[(c*8) +: 8] = tmp_u8;
            end

            out_pixels = out_h * out_w;
            for (p = 0; p < out_pixels; p = p + 1) begin
                for (c = 0; c < channels; c = c + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    if (scan_count != 1) begin
                        $display("ERROR: missing expected case=%0d p=%0d c=%0d", case_idx, p, c);
                        $fatal;
                    end
                    expected_mem[p*MAX_CIN + c] = tmp_i8;
                end
            end

            pulse_start_and_wait_done();

            for (c = 0; c < channels; c = c + 1) begin
                for (pbase = 0; pbase < out_pixels; pbase = pbase + 8) begin
                    read_buffer_vector(pbase[5:0], c[6:0]);
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        p = pbase + lane;
                        if (p < out_pixels) begin
                            actual = rd_data_vector[(lane*8) +: 8];
                            expected = expected_mem[p*MAX_CIN + c];
                            if (actual !== expected) begin
                                $display(
                                    "MISMATCH case=%0d p=%0d c=%0d expected=%0d actual=%0d",
                                    case_idx,
                                    p,
                                    c,
                                    expected,
                                    actual
                                );
                                error_count = error_count + 1;
                            end
                            total_checks = total_checks + 1;
                        end
                    end
                end
            end
        end

        $fclose(fd);
        repeat (5) @(posedge clk);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_dw_tile_fusion_engine cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_dw_tile_fusion_engine checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
