`timescale 1ns/1ps
`default_nettype none

/* Real-vector and protocol test for the independent D4 DW16 primitive. */
module tb_edgembconv_hwacandidate_d4_dw16_stream_tile;
    localparam integer SOURCE_WORDS = 1024;
    localparam integer OUTPUT_PIXELS = 64;

    reg clk, rst_n;
    reg cfg_valid;
    wire cfg_ready;
    reg [1:0] cfg_kind;
    reg [7:0] cfg_addr;
    reg [31:0] cfg_data;
    reg start_valid;
    wire start_ready;
    reg [7:0] start_in_w, start_in_h, start_out_w, start_out_h;
    reg [1:0] start_stride;
    reg [7:0] start_tile_x, start_tile_y;
    reg [3:0] start_tile_w, start_tile_h;
    reg [7:0] start_channel_base;
    reg [15:0] start_channel_mask;
    reg signed [7:0] start_padding_value;
    reg signed [31:0] start_output_zero_point, start_activation_min, start_activation_max;
    reg [3:0] start_epoch;
    reg [31:0] start_metadata;

    wire src_req_valid;
    reg src_req_ready;
    wire [31:0] src_req_addr;
    wire [7:0] src_req_pixel_idx;
    wire [3:0] src_req_tap_idx;
    wire src_req_first_tap, src_req_last_tap;
    wire [31:0] src_req_metadata;
    wire src_resp_valid;
    wire src_resp_ready;
    wire [127:0] src_resp_data;
    reg out_ready;
    wire out_valid;
    wire [127:0] out_data_vec;
    wire [511:0] out_raw_psum_vec;
    wire [7:0] out_pixel_idx, out_channel_base;
    wire [15:0] out_lane_mask;
    wire out_first, out_last;
    wire [31:0] out_metadata;
    wire done_valid;
    reg done_ready;
    wire [3:0] done_epoch;
    wire busy;
    wire [31:0] cycle_count, tap_count, source_word_count, source_stall_count;
    wire [31:0] output_stall_count, protocol_errors;

    reg [127:0] source_mem [0:SOURCE_WORDS-1];
    reg [127:0] expected_mem [0:OUTPUT_PIXELS-1];
    reg [511:0] expected_raw_mem [0:OUTPUT_PIXELS-1];
    reg [7:0] weights [0:143];
    reg [31:0] biases [0:15], multipliers [0:15];
    reg [7:0] shifts [0:15];

    reg pending_source;
    reg [31:0] pending_addr;
    reg [15:0] lfsr;
    integer errors, i, lane, checked, request_count, response_count;
    integer expected_mask;
    integer stable_req, stable_addr, stable_pixel, stable_tap, stable_output;
    reg [127:0] held_out;
    reg [511:0] held_raw;
    reg [7:0] held_idx;
    reg [15:0] held_mask;
    integer start_cycle, finish_cycle;

    edgembconv_hwacandidate_d4_dw16_stream_tile dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_kind(cfg_kind),
        .cfg_addr(cfg_addr), .cfg_data(cfg_data),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_in_w(start_in_w), .start_in_h(start_in_h),
        .start_out_w(start_out_w), .start_out_h(start_out_h),
        .start_stride(start_stride), .start_tile_x(start_tile_x),
        .start_tile_y(start_tile_y), .start_tile_w(start_tile_w),
        .start_tile_h(start_tile_h), .start_channel_base(start_channel_base),
        .start_channel_mask(start_channel_mask),
        .start_padding_value(start_padding_value),
        .start_output_zero_point(start_output_zero_point),
        .start_activation_min(start_activation_min),
        .start_activation_max(start_activation_max), .start_epoch(start_epoch),
        .start_metadata(start_metadata),
        .src_req_valid(src_req_valid), .src_req_ready(src_req_ready),
        .src_req_addr(src_req_addr), .src_req_pixel_idx(src_req_pixel_idx),
        .src_req_tap_idx(src_req_tap_idx), .src_req_first_tap(src_req_first_tap),
        .src_req_last_tap(src_req_last_tap), .src_req_metadata(src_req_metadata),
        .src_resp_valid(src_resp_valid), .src_resp_ready(src_resp_ready),
        .src_resp_data(src_resp_data), .out_ready(out_ready),
        .out_valid(out_valid), .out_data_vec(out_data_vec),
        .out_raw_psum_vec(out_raw_psum_vec), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_lane_mask(out_lane_mask),
        .out_first(out_first), .out_last(out_last), .out_metadata(out_metadata),
        .done_valid(done_valid), .done_ready(done_ready), .done_epoch(done_epoch),
        .busy(busy), .cycle_count(cycle_count), .tap_count(tap_count),
        .source_word_count(source_word_count),
        .source_stall_count(source_stall_count),
        .output_stall_count(output_stall_count), .protocol_errors(protocol_errors)
    );

    always #5 clk = ~clk;

    /* A worded synchronous BRAM model: the request is captured at one clock
     * edge and the registered response is visible in the following cycle,
     * held until the primitive accepts it. */
    assign src_resp_valid = pending_source;
    assign src_resp_data = (pending_addr < SOURCE_WORDS) ? source_mem[pending_addr] : 128'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 16'h4d31;
            pending_source <= 1'b0;
            pending_addr <= 0;
            request_count <= 0;
            response_count <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (src_resp_valid && src_resp_ready) begin
                pending_source <= 1'b0;
                response_count <= response_count + 1;
            end
            if (src_req_valid && src_req_ready) begin
                pending_source <= 1'b1;
                pending_addr <= src_req_addr;
                request_count <= request_count + 1;
            end
        end
    end

    always @(negedge clk) begin
        if (rst_n) begin
            src_req_ready <= (lfsr[2:0] != 3'b000);
            out_ready <= (lfsr[5:3] != 3'b000);
        end else begin
            src_req_ready <= 1'b1;
            out_ready <= 1'b1;
        end
    end

    task cfg_word;
        input integer kind;
        input integer addr;
        input [31:0] value;
        begin
            @(negedge clk);
            while (!cfg_ready) @(negedge clk);
            cfg_kind = kind[1:0]; cfg_addr = addr[7:0]; cfg_data = value;
            cfg_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0; cfg_kind = 0; cfg_addr = 0; cfg_data = 0;
        end
    endtask

    task load_case;
        input integer which;
        begin
            if (which == 0) begin
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_source_words.mem", source_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_expected.mem", expected_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_raw_psum.mem", expected_raw_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_weights.mem", weights);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_bias.mem", biases);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_multiplier.mem", multipliers);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb32_stride1_dw16_shift.mem", shifts);
            end else begin
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_source_words.mem", source_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_expected.mem", expected_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_raw_psum.mem", expected_raw_mem);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_weights.mem", weights);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_bias.mem", biases);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_multiplier.mem", multipliers);
                $readmemh("build/edgembconv_hwacandidate_d4_dw16_stream_vectors/mb16_down_stride2_dw16_shift.mem", shifts);
            end
            for (i = 0; i < 144; i = i + 1) cfg_word(0, i, {24'd0, weights[i]});
            for (i = 0; i < 16; i = i + 1) begin
                cfg_word(1, i, biases[i]);
                cfg_word(2, i, multipliers[i]);
                cfg_word(3, i, {24'd0, shifts[i]});
            end
        end
    endtask

    task run_case;
        input integer which;
        input integer mask_value;
        input integer epoch_value;
        begin
            load_case(which);
            start_channel_base = which == 0 ? 0 : 16;
            start_channel_mask = mask_value[15:0];
            start_stride = which == 0 ? 1 : 2;
            start_metadata = which == 0 ? 32'hd400_0010 : 32'hd400_0210;
            expected_mask = mask_value;
            @(negedge clk); while (!start_ready) @(negedge clk);
            start_epoch = epoch_value[3:0]; start_valid = 1'b1;
            @(posedge clk); @(negedge clk); start_valid = 1'b0;
            start_cycle = cycle_count; checked = 0; stable_req = 0; stable_output = 0;
            while (!done_valid) begin
                @(posedge clk);
                if (src_req_valid && !src_req_ready) begin
                    if (!stable_req) begin
                        stable_req = 1; stable_addr = src_req_addr;
                        stable_pixel = src_req_pixel_idx; stable_tap = src_req_tap_idx;
                    end else if (src_req_addr !== stable_addr ||
                                 src_req_pixel_idx !== stable_pixel ||
                                 src_req_tap_idx !== stable_tap) begin
                        $display("D4_DW16_REQUEST_CHANGED case=%0d", which);
                        errors = errors + 1;
                    end
                end else stable_req = 0;
                if (out_valid && !out_ready) begin
                    if (!stable_output) begin
                        held_idx = out_pixel_idx; held_out = out_data_vec;
                        held_raw = out_raw_psum_vec; held_mask = out_lane_mask;
                        stable_output = 1;
                    end else if (out_pixel_idx !== held_idx || out_data_vec !== held_out ||
                                 out_raw_psum_vec !== held_raw || out_lane_mask !== held_mask) begin
                        $display("D4_DW16_OUTPUT_CHANGED case=%0d", which);
                        errors = errors + 1;
                    end
                end else stable_output = 0;
                if (out_valid && out_ready) begin
                    if (out_pixel_idx !== checked[7:0] || out_metadata !== start_metadata ||
                        out_channel_base !== start_channel_base ||
                        out_lane_mask !== expected_mask[15:0] ||
                        out_first !== (checked == 0) || out_last !== (checked == 63)) begin
                        $display("D4_DW16_MISMATCH case=%0d pixel=%0d exp=%032x got=%032x raw_exp=%0128x raw_got=%0128x", which, checked, expected_mem[checked], out_data_vec, expected_raw_mem[checked], out_raw_psum_vec);
                        errors = errors + 1;
                    end
                    if (mask_value == 16'hffff) begin
                        if (out_data_vec !== expected_mem[checked] ||
                            out_raw_psum_vec !== expected_raw_mem[checked]) begin
                            $display("D4_DW16_ARITH_MISMATCH case=%0d pixel=%0d exp=%032x got=%032x raw_exp=%0128x raw_got=%0128x", which, checked, expected_mem[checked], out_data_vec, expected_raw_mem[checked], out_raw_psum_vec);
                            errors = errors + 1;
                        end
                    end else begin
                        for (lane = 0; lane < 16; lane = lane + 1) begin
                            if (lane < 12) begin
                                if (out_data_vec[(lane*8) +: 8] !== expected_mem[checked][(lane*8) +: 8] ||
                                    out_raw_psum_vec[(lane*32) +: 32] !== expected_raw_mem[checked][(lane*32) +: 32])
                                    errors = errors + 1;
                            end else if (out_data_vec[(lane*8) +: 8] !== 0 ||
                                         out_raw_psum_vec[(lane*32) +: 32] !== 0)
                                errors = errors + 1;
                        end
                    end
                    checked = checked + 1;
                end
            end
            finish_cycle = cycle_count;
            if (checked != OUTPUT_PIXELS || tap_count != OUTPUT_PIXELS * 9 ||
                done_epoch !== epoch_value[3:0] || protocol_errors != 0)
                errors = errors + 1;
            $display("D4_DW16 case=%0d name=%s stride=%0d outputs=%0d taps=%0d source_words=%0d cycles=%0d source_stalls=%0d output_stalls=%0d", which, which ? "mb16_down_stride2" : "mb32_stride1", start_stride, checked, tap_count, source_word_count, finish_cycle-start_cycle, source_stall_count, output_stall_count);
            @(posedge clk);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; cfg_valid = 0; cfg_kind = 0; cfg_addr = 0; cfg_data = 0;
        start_valid = 0; start_in_w = 32; start_in_h = 32; start_out_w = 32; start_out_h = 32;
        start_stride = 1; start_tile_x = 0; start_tile_y = 0; start_tile_w = 8; start_tile_h = 8;
        start_channel_base = 0; start_channel_mask = 16'hffff; start_padding_value = 0;
        start_output_zero_point = 0; start_activation_min = 0; start_activation_max = 127;
        start_epoch = 0; start_metadata = 0; done_ready = 1; src_req_ready = 1;
        out_ready = 1; errors = 0;
        repeat (5) @(posedge clk); rst_n = 1;
        run_case(0, 16'hffff, 1);
        run_case(1, 16'hffff, 2);
        /* A derived tail transaction proves masked lanes are zero and do not
         * leak bias/old products.  The source and parameters remain the real
         * mb16_down deployment vectors. */
        run_case(1, 16'h0fff, 3);
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_dw16_stream_tile cases=3 real_cases=2 tail_case=1");
        else begin
            $display("FAIL edgembconv_hwacandidate_d4_dw16_stream_tile errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
