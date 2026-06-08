`timescale 1ns/1ps
`default_nettype none

module tb_ds_block_tile_engine;
    localparam MAX_CIN = 128;
    localparam MAX_COUT = 256;
    localparam MAX_IN_H = 17;
    localparam MAX_IN_W = 17;

    reg clk;
    reg rst_n;
    reg start;
    wire busy;
    wire done;
    reg [3:0] out_h;
    reg [3:0] out_w;
    reg [7:0] channels;
    reg [15:0] out_channels;
    reg [1:0] stride;
    reg signed [7:0] input_zero_point;
    reg signed [(MAX_IN_H*MAX_IN_W*MAX_CIN*8)-1:0] input_tile;
    reg signed [(MAX_CIN*9*8)-1:0] dw_weight;
    reg signed [(MAX_CIN*32)-1:0] dw_bias;
    reg signed [(MAX_CIN*32)-1:0] dw_multiplier;
    reg [(MAX_CIN*8)-1:0] dw_shift;
    reg signed [31:0] dw_output_zero_point;
    reg signed [31:0] dw_activation_min;
    reg signed [31:0] dw_activation_max;
    reg signed [(MAX_COUT*MAX_CIN*8)-1:0] pw_weight;
    reg signed [(MAX_COUT*32)-1:0] pw_bias;
    reg signed [(MAX_COUT*32)-1:0] pw_multiplier;
    reg [(MAX_COUT*8)-1:0] pw_shift;
    reg signed [31:0] pw_output_zero_point;
    reg signed [31:0] pw_activation_min;
    reg signed [31:0] pw_activation_max;
    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [7:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer in_h;
    integer in_w;
    integer y;
    integer x;
    integer c;
    integer co;
    integer k;
    integer p;
    integer out_pixels;
    integer total_checks;
    integer error_count;
    integer idx;
    reg signed [7:0] tmp_i8;
    reg signed [31:0] tmp_i32;
    reg [7:0] tmp_u8;
    reg signed [7:0] expected_mem [0:16383];
    reg signed [7:0] actual_mem [0:16383];

    ds_block_tile_engine #(
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done),
        .out_h(out_h),
        .out_w(out_w),
        .channels(channels),
        .out_channels(out_channels),
        .stride(stride),
        .input_zero_point(input_zero_point),
        .input_tile(input_tile),
        .dw_weight(dw_weight),
        .dw_bias(dw_bias),
        .dw_multiplier(dw_multiplier),
        .dw_shift(dw_shift),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_weight(pw_weight),
        .pw_bias(pw_bias),
        .pw_multiplier(pw_multiplier),
        .pw_shift(pw_shift),
        .pw_output_zero_point(pw_output_zero_point),
        .pw_activation_min(pw_activation_min),
        .pw_activation_max(pw_activation_max),
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
            actual_mem[out_wr_pixel_idx * MAX_COUT + out_wr_channel_idx] <= out_wr_data_int8;
        end
    end

    task clear_case_regs;
        begin
            input_tile = 0;
            dw_weight = 0;
            dw_bias = 0;
            dw_multiplier = 0;
            dw_shift = 0;
            pw_weight = 0;
            pw_bias = 0;
            pw_multiplier = 0;
            pw_shift = 0;
            for (idx = 0; idx < 16384; idx = idx + 1) begin
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
        channels = 8'd0;
        out_channels = 16'd0;
        stride = 2'd1;
        input_zero_point = 8'sd0;
        dw_output_zero_point = 32'sd0;
        dw_activation_min = 32'sd0;
        dw_activation_max = 32'sd48;
        pw_output_zero_point = 32'sd0;
        pw_activation_min = 32'sd0;
        pw_activation_max = 32'sd48;
        total_checks = 0;
        error_count = 0;
        clear_case_regs();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/dsblock_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            clear_case_regs();
            scan_count = $fscanf(
                fd,
                "%d %d %d %d %d %d %d %h %h %h %h %h %h %h\n",
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                out_channels,
                stride,
                input_zero_point,
                dw_output_zero_point,
                dw_activation_min,
                dw_activation_max,
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max
            );
            if (scan_count != 14) begin
                $display("ERROR: bad dsblock header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end

            for (y = 0; y < MAX_IN_H; y = y + 1) begin
                for (x = 0; x < MAX_IN_W; x = x + 1) begin
                    for (c = 0; c < channels; c = c + 1) begin
                        scan_count = $fscanf(fd, "%h\n", tmp_i8);
                        input_tile[(((y*MAX_IN_W*MAX_CIN) + (x*MAX_CIN) + c)*8) +: 8] = tmp_i8;
                    end
                end
            end
            for (c = 0; c < channels; c = c + 1) begin
                for (k = 0; k < 9; k = k + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
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
            for (co = 0; co < out_channels; co = co + 1) begin
                for (c = 0; c < channels; c = c + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    pw_weight[((co*MAX_CIN + c)*8) +: 8] = tmp_i8;
                end
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                pw_bias[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                pw_multiplier[(co*32) +: 32] = tmp_i32;
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                pw_shift[(co*8) +: 8] = tmp_u8;
            end

            out_pixels = out_h * out_w;
            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < out_channels; co = co + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    expected_mem[p*MAX_COUT + co] = tmp_i8;
                end
            end

            pulse_start_and_wait_done();

            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < out_channels; co = co + 1) begin
                    if (actual_mem[p*MAX_COUT + co] !== expected_mem[p*MAX_COUT + co]) begin
                        $display(
                            "MISMATCH case=%0d p=%0d co=%0d expected=%0d actual=%0d",
                            case_idx,
                            p,
                            co,
                            expected_mem[p*MAX_COUT + co],
                            actual_mem[p*MAX_COUT + co]
                        );
                        error_count = error_count + 1;
                    end
                    total_checks = total_checks + 1;
                end
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_ds_block_tile_engine cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_ds_block_tile_engine checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
