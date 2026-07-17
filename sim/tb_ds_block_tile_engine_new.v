`timescale 1ns/1ps
`default_nettype none

module tb_ds_block_tile_engine_new;
    localparam MAX_CIN = 128;
    localparam MAX_COUT = 256;
    localparam MAX_IN_H = 17;
    localparam MAX_IN_W = 17;

    localparam CFG_INPUT      = 4'd0;
    localparam CFG_DW_WEIGHT  = 4'd1;
    localparam CFG_DW_BIAS    = 4'd2;
    localparam CFG_DW_MUL     = 4'd3;
    localparam CFG_DW_SHIFT   = 4'd4;
    localparam CFG_PW_WEIGHT  = 4'd5;
    localparam CFG_PW_BIAS    = 4'd6;
    localparam CFG_PW_MUL     = 4'd7;
    localparam CFG_PW_SHIFT   = 4'd8;

    reg clk;
    reg rst_n;
    reg cfg_wr_en;
    wire cfg_ready;
    reg [3:0] cfg_target;
    reg [15:0] cfg_index;
    reg [31:0] cfg_data;
    reg start;
    wire busy;
    wire done;
    wire error;

    reg [3:0] out_h;
    reg [3:0] out_w;
    reg [7:0] channels;
    reg [15:0] out_channels;
    reg [1:0] stride;
    reg signed [7:0] input_zero_point;
    reg signed [31:0] dw_output_zero_point;
    reg signed [31:0] dw_activation_min;
    reg signed [31:0] dw_activation_max;
    reg signed [31:0] pw_output_zero_point;
    reg signed [31:0] pw_activation_min;
    reg signed [31:0] pw_activation_max;

    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [7:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;
    wire [31:0] perf_total_cycles;
    wire [31:0] perf_dw_cycles;
    wire [31:0] perf_pw_cycles;
    wire [31:0] perf_pw_issue_cycles;

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
    integer timeout;
    integer idx;
    integer expected_pw_issue_cycles;
    reg signed [7:0] tmp_i8;
    reg signed [31:0] tmp_i32;
    reg [7:0] tmp_u8;
    reg signed [7:0] expected_mem [0:16383];
    reg signed [7:0] actual_mem [0:16383];

    ds_block_tile_engine_new #(
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_wr_en(cfg_wr_en),
        .cfg_ready(cfg_ready),
        .cfg_target(cfg_target),
        .cfg_index(cfg_index),
        .cfg_data(cfg_data),
        .start(start),
        .busy(busy),
        .done(done),
        .error(error),
        .out_h(out_h),
        .out_w(out_w),
        .channels(channels),
        .out_channels(out_channels),
        .stride(stride),
        .input_zero_point(input_zero_point),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_output_zero_point(pw_output_zero_point),
        .pw_activation_min(pw_activation_min),
        .pw_activation_max(pw_activation_max),
        .out_wr_en(out_wr_en),
        .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_idx(out_wr_channel_idx),
        .out_wr_data_int8(out_wr_data_int8),
        .perf_total_cycles(perf_total_cycles),
        .perf_dw_cycles(perf_dw_cycles),
        .perf_pw_cycles(perf_pw_cycles),
        .perf_pw_issue_cycles(perf_pw_issue_cycles)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (out_wr_en) begin
            actual_mem[out_wr_pixel_idx * MAX_COUT + out_wr_channel_idx] <=
                out_wr_data_int8;
        end
        if ($test$plusargs("TRACE_NEW_DSBLOCK") && dut.rq_fire) begin
            $display(
                "RQ_IN case=%0d p=%0d co=%0d acc=%0d bias=%0d mul=%0d shift=%0d",
                case_idx,
                dut.rq_pixel_idx_wide,
                dut.rq_cout_idx_wide,
                $signed(dut.rq_psum_shift[31:0]),
                $signed(dut.pw_bias_mem[dut.rq_cout_idx_wide[7:0]]),
                $signed(dut.pw_multiplier_mem[dut.rq_cout_idx_wide[7:0]]),
                dut.pw_shift_mem[dut.rq_cout_idx_wide[7:0]]
            );
        end
        if ($test$plusargs("TRACE_NEW_DSBLOCK") && out_wr_en) begin
            $display(
                "RQ_OUT case=%0d p=%0d co=%0d data=%0d",
                case_idx,
                out_wr_pixel_idx,
                out_wr_channel_idx,
                out_wr_data_int8
            );
        end
        if ($test$plusargs("TRACE_NEW_DSBLOCK") && dut.dw_buf_wr_en) begin
            $display(
                "DW_OUT case=%0d p=%0d c=%0d data=%0d",
                case_idx,
                dut.dw_out_pixel_idx,
                dut.dw_out_channel_idx,
                dut.dw_out_data_int8
            );
        end
        if ($test$plusargs("TRACE_NEW_DSBLOCK") &&
            (dut.state == 5'd2) &&
            (dut.stream_x == 5'd0) &&
            (dut.stream_y == 5'd0)) begin
            $display(
                "DW_CFG case=%0d base=%0d weights=%h bias=%h mul=%h shift=%h",
                case_idx,
                dut.dw_channel_base,
                dut.dw_weight_vec,
                dut.dw_bias_vec,
                dut.dw_multiplier_vec,
                dut.dw_shift_vec
            );
        end
        if ($test$plusargs("TRACE_NEW_DSBLOCK") &&
            (dut.state == 5'd3) &&
            (dut.stream_y >= 5'd1) &&
            (dut.stream_y <= 5'd3) &&
            (dut.stream_x >= 5'd6) &&
            (dut.stream_x <= 5'd8)) begin
            $display(
                "DW_INPUT case=%0d x=%0d y=%0d data=%h",
                case_idx,
                dut.stream_x,
                dut.stream_y,
                dut.dw_pixel_vec
            );
        end
    end

    task cfg_write;
        input [3:0] target;
        input [15:0] index;
        input [31:0] data;
        begin
            while (!cfg_ready) begin
                @(negedge clk);
            end
            @(negedge clk);
            cfg_target = target;
            cfg_index = index;
            cfg_data = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task clear_case_mem;
        begin
            for (idx = 0; idx < 16384; idx = idx + 1) begin
                expected_mem[idx] = 8'sd0;
                actual_mem[idx] = 8'sd0;
            end
        end
    endtask

    task pulse_start_and_wait_done;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout = 0;
            while (!done && timeout < 2000000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done) begin
                $display(
                    "ERROR timeout case=%0d state=%0d cycles=%0d",
                    case_idx,
                    dut.state,
                    perf_total_cycles
                );
                $fatal;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cfg_wr_en = 1'b0;
        cfg_target = 4'd0;
        cfg_index = 16'd0;
        cfg_data = 32'd0;
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
        clear_case_mem();

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/dsblock_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/dsblock_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            clear_case_mem();
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
                $display(
                    "ERROR: bad new dsblock header case=%0d scan=%0d",
                    case_idx,
                    scan_count
                );
                $fatal;
            end

            for (y = 0; y < MAX_IN_H; y = y + 1) begin
                for (x = 0; x < MAX_IN_W; x = x + 1) begin
                    for (c = 0; c < channels; c = c + 1) begin
                        scan_count = $fscanf(fd, "%h\n", tmp_i8);
                        cfg_write(
                            CFG_INPUT,
                            ((y*MAX_IN_W*MAX_CIN) + (x*MAX_CIN) + c),
                            {{24{tmp_i8[7]}}, tmp_i8}
                        );
                    end
                end
            end
            for (c = 0; c < channels; c = c + 1) begin
                for (k = 0; k < 9; k = k + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    cfg_write(
                        CFG_DW_WEIGHT,
                        (c*9) + k,
                        {{24{tmp_i8[7]}}, tmp_i8}
                    );
                end
            end
            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                cfg_write(CFG_DW_BIAS, c, tmp_i32);
            end
            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                cfg_write(CFG_DW_MUL, c, tmp_i32);
            end
            for (c = 0; c < channels; c = c + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                cfg_write(CFG_DW_SHIFT, c, {24'd0, tmp_u8});
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                for (c = 0; c < channels; c = c + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    cfg_write(
                        CFG_PW_WEIGHT,
                        (co*MAX_CIN) + c,
                        {{24{tmp_i8[7]}}, tmp_i8}
                    );
                end
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                cfg_write(CFG_PW_BIAS, co, tmp_i32);
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_i32);
                cfg_write(CFG_PW_MUL, co, tmp_i32);
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                scan_count = $fscanf(fd, "%h\n", tmp_u8);
                cfg_write(CFG_PW_SHIFT, co, {24'd0, tmp_u8});
            end

            out_pixels = out_h * out_w;
            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < out_channels; co = co + 1) begin
                    scan_count = $fscanf(fd, "%h\n", tmp_i8);
                    expected_mem[p*MAX_COUT + co] = tmp_i8;
                end
            end

            pulse_start_and_wait_done();

            if (error) begin
                $display("MISMATCH unexpected engine error case=%0d", case_idx);
                error_count = error_count + 1;
            end

            expected_pw_issue_cycles =
                ((out_pixels + 7) / 8) *
                ((out_channels + 7) / 8) *
                channels;
            if (perf_pw_issue_cycles != expected_pw_issue_cycles) begin
                $display(
                    "MISMATCH case=%0d pw_issue expected=%0d actual=%0d",
                    case_idx,
                    expected_pw_issue_cycles,
                    perf_pw_issue_cycles
                );
                error_count = error_count + 1;
            end

            for (p = 0; p < out_pixels; p = p + 1) begin
                for (co = 0; co < out_channels; co = co + 1) begin
                    if (actual_mem[p*MAX_COUT + co] !==
                        expected_mem[p*MAX_COUT + co]) begin
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

            $display(
                "PERF new_dsblock case=%0d total=%0d dw=%0d pw=%0d pw_issue=%0d",
                case_idx,
                perf_total_cycles,
                perf_dw_cycles,
                perf_pw_cycles,
                perf_pw_issue_cycles
            );
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display(
                "PASS tb_ds_block_tile_engine_new cases=%0d checks=%0d",
                num_cases,
                total_checks
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_ds_block_tile_engine_new checks=%0d errors=%0d",
                total_checks,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
