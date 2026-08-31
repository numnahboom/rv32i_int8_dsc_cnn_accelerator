`timescale 1ns/1ps
`default_nettype none

module tb_ds_block_tile_engine_spatial;
    localparam MAX_CIN = 128;
    localparam MAX_COUT = 256;
    localparam MAX_IN_H = 17;
    localparam MAX_IN_W = 17;

    reg clk, rst_n;
    reg cfg_wr_en;
    wire cfg_ready;
    reg [3:0] cfg_target;
    reg [15:0] cfg_index;
    reg [31:0] cfg_data;
    reg cfg_vec4_wr_en;
    reg [15:0] cfg_vec4_index;
    reg [31:0] cfg_vec4_data;
    reg start;
    wire busy, done, error;
    reg [3:0] out_h, out_w;
    reg [7:0] channels;
    reg [15:0] out_channels;
    reg [1:0] stride;
    reg signed [7:0] input_zero_point;
    reg signed [31:0] dw_output_zero_point, dw_activation_min, dw_activation_max;
    reg signed [31:0] pw_output_zero_point, pw_activation_min, pw_activation_max;
    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [7:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;
    wire out_wr_vec4_en;
    wire [5:0] out_wr_vec4_pixel_idx;
    wire [7:0] out_wr_vec4_channel_idx;
    wire [31:0] out_wr_vec4_data_int8;
    wire [31:0] perf_total_cycles, perf_dw_cycles, perf_pw_cycles, perf_pw_issue_cycles;

    integer errors, writes, expected_writes, timeout, case_id, expected_value;
    integer y, x, c, co, k, p;
    reg [7:0] seen [0:(64*MAX_COUT)-1];

    ds_block_tile_engine_spatial #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT),
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W)
    ) dut (
        .clk(clk), .rst_n(rst_n), .cfg_wr_en(cfg_wr_en), .cfg_ready(cfg_ready),
        .cfg_target(cfg_target), .cfg_index(cfg_index), .cfg_data(cfg_data),
        .cfg_vec4_wr_en(cfg_vec4_wr_en), .cfg_vec4_index(cfg_vec4_index),
        .cfg_vec4_data(cfg_vec4_data), .start(start), .busy(busy), .done(done),
        .error(error), .out_h(out_h), .out_w(out_w), .channels(channels),
        .out_channels(out_channels), .stride(stride),
        .input_zero_point(input_zero_point),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min), .dw_activation_max(dw_activation_max),
        .pw_output_zero_point(pw_output_zero_point),
        .pw_activation_min(pw_activation_min), .pw_activation_max(pw_activation_max),
        .out_wr_en(out_wr_en), .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_idx(out_wr_channel_idx), .out_wr_data_int8(out_wr_data_int8),
        .out_wr_vec4_en(out_wr_vec4_en), .out_wr_vec4_pixel_idx(out_wr_vec4_pixel_idx),
        .out_wr_vec4_channel_idx(out_wr_vec4_channel_idx),
        .out_wr_vec4_data_int8(out_wr_vec4_data_int8),
        .perf_total_cycles(perf_total_cycles), .perf_dw_cycles(perf_dw_cycles),
        .perf_pw_cycles(perf_pw_cycles), .perf_pw_issue_cycles(perf_pw_issue_cycles)
    );

    always #5 clk <= ~clk;

    task cfg_write;
        input [3:0] target;
        input [15:0] index;
        input [31:0] data;
        begin
            while (!cfg_ready) @(negedge clk);
            @(negedge clk);
            cfg_target = target;
            cfg_index = index;
            cfg_data = data;
            cfg_wr_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task clear_seen;
        begin
            for (p = 0; p < 64*MAX_COUT; p = p + 1)
                seen[p] = 1'b0;
            writes = 0;
        end
    endtask

    task load_case;
        begin
            /* All-zero tensors are an exact reference while still exercising
             * every address, tail mask, tap, group, and ownership transition. */
            for (y = 0; y < ((out_h-1)*stride + 3); y = y + 1)
                for (x = 0; x < ((out_w-1)*stride + 3); x = x + 1)
                    for (c = 0; c < channels; c = c + 1)
                        cfg_write(4'd0, (y*MAX_IN_W*MAX_CIN) + (x*MAX_CIN) + c,
                                  (case_id == 0) ? 32'd1 : 32'd0);
            for (c = 0; c < channels; c = c + 1) begin
                for (k = 0; k < 9; k = k + 1)
                    cfg_write(4'd1, (c*9)+k, (case_id == 0) ? 32'd1 : 32'd0);
                cfg_write(4'd2, c, 32'd0);
                cfg_write(4'd3, c, (case_id == 0) ? 32'h7fffffff : 32'd0);
                cfg_write(4'd4, c, 32'd0);
            end
            for (co = 0; co < out_channels; co = co + 1) begin
                for (c = 0; c < channels; c = c + 1)
                    cfg_write(4'd5, (co*MAX_CIN)+c, (case_id == 0) ? 32'd1 : 32'd0);
                cfg_write(4'd6, co, 32'd0);
                cfg_write(4'd7, co, (case_id == 0) ? 32'h7fffffff : 32'd0);
                cfg_write(4'd8, co, 32'd0);
            end
        end
    endtask

    task run_case;
        input integer h_arg;
        input integer w_arg;
        input integer cin_arg;
        input integer cout_arg;
        input integer stride_arg;
        begin
            out_h = h_arg; out_w = w_arg; channels = cin_arg;
            out_channels = cout_arg; stride = stride_arg;
            clear_seen();
            load_case();
            expected_writes = out_h * out_w * out_channels;
            expected_value = (case_id == 0) ? 9 : 0;
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            timeout = 0;
            while (!done && timeout < 1000000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done || error) begin
                $display("FAIL case=%0d timeout=%0d done=%b error=%b state=%0d",
                         case_id, timeout, done, error, dut.dw_state);
                errors = errors + 1;
            end
            @(negedge clk);
            if (writes != expected_writes) begin
                $display("FAIL case=%0d writes=%0d expected=%0d cycles=%0d",
                         case_id, writes, expected_writes, perf_total_cycles);
                errors = errors + 1;
            end
            if (dut.perf_overlap_cycles == 0 && (out_h*out_w > 8)) begin
                $display("FAIL case=%0d no DW/PW overlap", case_id);
                errors = errors + 1;
            end
            $display("CASE %0d h=%0d w=%0d cin=%0d cout=%0d s=%0d cycles=%0d dw=%0d pw=%0d pw_issue=%0d overlap=%0d writes=%0d",
                     case_id, out_h, out_w, channels, out_channels, stride,
                     perf_total_cycles, perf_dw_cycles, perf_pw_cycles,
                     perf_pw_issue_cycles, dut.perf_overlap_cycles, writes);
            case_id = case_id + 1;
        end
    endtask

    always @(negedge clk) begin
        if (rst_n && out_wr_vec4_en) begin
            for (c = 0; c < 4; c = c + 1) begin
                if (seen[(out_wr_vec4_pixel_idx*MAX_COUT) + out_wr_vec4_channel_idx + c])
                    errors = errors + 1;
                if ($signed(out_wr_vec4_data_int8[(c*8) +: 8]) !== expected_value)
                    errors = errors + 1;
                seen[(out_wr_vec4_pixel_idx*MAX_COUT) + out_wr_vec4_channel_idx + c] = 1'b1;
                writes = writes + 1;
            end
        end else if (rst_n && out_wr_en) begin
            if (seen[(out_wr_pixel_idx*MAX_COUT) + out_wr_channel_idx])
                errors = errors + 1;
            if ($signed(out_wr_data_int8) !== expected_value)
                errors = errors + 1;
            seen[(out_wr_pixel_idx*MAX_COUT) + out_wr_channel_idx] = 1'b1;
            writes = writes + 1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; cfg_wr_en = 0; cfg_target = 0; cfg_index = 0;
        cfg_data = 0; cfg_vec4_wr_en = 0; cfg_vec4_index = 0; cfg_vec4_data = 0;
        start = 0; out_h = 0; out_w = 0; channels = 0; out_channels = 0;
        stride = 1; input_zero_point = 0;
        dw_output_zero_point = 0; dw_activation_min = -128; dw_activation_max = 127;
        pw_output_zero_point = 0; pw_activation_min = -128; pw_activation_max = 127;
        errors = 0; case_id = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        run_case(1, 1, 1, 8, 1);
        run_case(2, 4, 7, 13, 1);
        run_case(3, 6, 16, 16, 1);
        run_case(1, 1, 17, 8, 2);
        run_case(2, 4, 48, 13, 2);
        run_case(3, 6, 128, 16, 2);

        if (errors == 0)
            $display("PASS tb_ds_block_tile_engine_spatial cases=6 exact_reference");
        else begin
            $display("FAIL tb_ds_block_tile_engine_spatial errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
