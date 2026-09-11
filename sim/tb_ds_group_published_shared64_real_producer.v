`timescale 1ns/1ps
`default_nettype none

/*
 * DS1 real-producer integration proof.  The external feature map is all ones
 * and the nine DW taps/PW rows are unit weights, making the independent
 * reference a 3x3 valid-neighbour count followed by the sweep's fixed 1/2
 * output requantization.  The source channel still exercises the real
 * pixel-major feature-word address protocol and delayed responses.
 */
module tb_ds_group_published_shared64_real_producer;
    reg clk = 0;
    always #1 clk = ~clk;
    reg rst_n = 0;

    reg start_valid = 0;
    wire start_ready;
    reg [10:0] start_pixels = 1024;
    reg [7:0] start_cin = 16;
    reg [8:0] start_cout = 32;
    reg start_bank = 0;
    reg [1:0] start_session = 0;
    reg [3:0] start_epoch = 1;

    reg weight_load_valid = 0;
    wire weight_load_ready;
    reg [4:0] weight_load_tile = 0;
    reg [7:0] weight_load_k = 0;
    reg signed [63:0] weight_load_vec = 0;

    wire result_valid;
    reg result_ready = 1;
    wire [10:0] result_pixel_idx;
    wire [8:0] result_channel_base;
    wire [3:0] result_lane_mask;
    wire signed [31:0] result_data;
    wire done, error;
    wire [31:0] total_cycles, dw_writes, descriptors, pw_tokens;
    wire [31:0] output_writes, output_groups, preload_rows;
    wire [31:0] producer_jobs, producer_stream_beats;

    reg cfg_valid = 0;
    wire cfg_ready;
    reg [3:0] cfg_tap_idx = 0;
    reg signed [127:0] cfg_weight_vec = 0;
    reg signed [511:0] cfg_bias_vec = 0;
    reg signed [511:0] cfg_multiplier_vec = 0;
    reg [95:0] cfg_shift_vec = 0;
    wire mem_req_valid;
    reg mem_req_ready = 1;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 0;
    reg [31:0] mem_resp_data = 0;

    ds_group_published_shared64_real_producer dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid),
        .start_ready(start_ready), .start_pixels(start_pixels),
        .start_cin(start_cin), .start_cout(start_cout), .start_bank(start_bank),
        .start_session(start_session), .start_epoch(start_epoch),
        .weight_load_valid(weight_load_valid), .weight_load_ready(weight_load_ready),
        .weight_load_tile(weight_load_tile), .weight_load_k(weight_load_k),
        .weight_load_vec(weight_load_vec), .result_valid(result_valid),
        .result_ready(result_ready), .result_pixel_idx(result_pixel_idx),
        .result_channel_base(result_channel_base),
        .result_lane_mask(result_lane_mask), .result_data(result_data),
        .done(done), .error(error), .perf_total_cycles(total_cycles),
        .perf_dw_writes(dw_writes), .perf_group_descriptors(descriptors),
        .perf_pw_tokens(pw_tokens), .perf_output_writes(output_writes),
        .perf_output_groups(output_groups), .perf_preload_rows(preload_rows),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .perf_producer_jobs(producer_jobs),
        .perf_producer_stream_beats(producer_stream_beats)
    );

    /* Three-cycle, in-order feature SRAM response with request bubbles. */
    reg response_valid_q [0:2];
    reg [31:0] response_data_q [0:2];
    integer qi;
    integer source_cycles = 0;
    always @(posedge clk) begin
        source_cycles <= source_cycles + 1;
        if (!rst_n) begin
            mem_resp_valid <= 0;
            mem_resp_data <= 0;
            mem_req_ready <= 1;
            for (qi = 0; qi < 3; qi = qi + 1) begin
                response_valid_q[qi] <= 0;
                response_data_q[qi] <= 0;
            end
        end else begin
            mem_resp_valid <= response_valid_q[0];
            mem_resp_data <= response_data_q[0];
            for (qi = 0; qi < 2; qi = qi + 1) begin
                response_valid_q[qi] <= response_valid_q[qi+1];
                response_data_q[qi] <= response_data_q[qi+1];
            end
            response_valid_q[2] <= 0;
            response_data_q[2] <= 32'h01010101;
            mem_req_ready <= ((source_cycles % 17) != 5);
            if (mem_req_valid && mem_req_ready)
                response_valid_q[2] <= 1;
        end
    end

    integer errors = 0;
    integer result_checks = 0;
    integer overlap_cycles = 0;
    integer dw_stalls = 0;
    integer pw_stalls = 0;
    integer row_idx, col_idx, physical_y, physical_x, dy, dx;
    integer neighbours, expected_byte, got_byte;
    integer stream_order_count = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.u_sweep.dw_fire && dut.u_sweep.u_shared_ds.input_fire)
                overlap_cycles = overlap_cycles + 1;
            if (dut.u_sweep.dw_valid && !dut.u_sweep.dw_ready)
                dw_stalls = dw_stalls + 1;
            if (dut.u_sweep.pw_token_valid && !dut.u_sweep.core_ready)
                pw_stalls = pw_stalls + 1;
            /* The direct producer emits the historical pixel-major stream
             * contract: pixel -> group -> half.  Check the public record
             * labels at every accepted beat; the value checks below still
             * cover the end-to-end arithmetic result. */
            if (dut.stream4_valid && dut.stream4_ready) begin
                integer local_beat, expected_group, expected_row;
                integer expected_col, expected_half, expected_pixel;
                local_beat = stream_order_count % 128;
                expected_pixel = local_beat / 4;
                expected_group = (local_beat % 4) / 2;
                expected_row = expected_pixel / 8;
                expected_col = expected_pixel % 8;
                expected_half = local_beat % 2;
                if (dut.stream4_pixel !== expected_pixel[5:0] ||
                    dut.stream4_lane_base !== ((expected_group * 2) + expected_half)) begin
                    errors = errors + 1;
                    if (errors < 8)
                        $display("STREAM_ORDER_MISMATCH beat=%0d pixel=%0d/%0d lane=%0d/%0d",
                                 stream_order_count, dut.stream4_pixel, expected_pixel,
                                 dut.stream4_lane_base,
                                 (expected_group * 2) + expected_half);
                end
                stream_order_count = stream_order_count + 1;
            end
        end
        if (rst_n && result_valid && result_ready) begin
            row_idx = result_pixel_idx >> 3;
            col_idx = result_pixel_idx & 7;
            physical_y = ((row_idx >> 2) >> 3) * 4 + (row_idx & 3);
            physical_x = ((row_idx >> 2) & 7) * 8 + col_idx;
            neighbours = 0;
            for (dy = -1; dy <= 1; dy = dy + 1)
                for (dx = -1; dx <= 1; dx = dx + 1)
                    if ((physical_y + dy >= 0) && (physical_y + dy < 32) &&
                        (physical_x + dx >= 0) && (physical_x + dx < 32))
                        neighbours = neighbours + 1;
            expected_byte = neighbours * 8;
            for (qi = 0; qi < 4; qi = qi + 1) begin
                if (!result_lane_mask[qi]) begin
                    errors = errors + 1;
                    if (errors < 8) $display("BAD_RESULT_MASK pixel=%0d base=%0d mask=%h",
                                             result_pixel_idx, result_channel_base,
                                             result_lane_mask);
                end else begin
                    got_byte = $signed(result_data[qi*8 +: 8]);
                    if (got_byte != expected_byte) begin
                        errors = errors + 1;
                        if (errors < 8) $display("RESULT_MISMATCH pixel=%0d lane=%0d got=%0d exp=%0d",
                                                 result_pixel_idx,
                                                 result_channel_base + qi,
                                                 got_byte, expected_byte);
                    end
                    result_checks = result_checks + 1;
                end
            end
        end
    end

    task configure_dw;
        integer t, l;
        begin
            for (t = 0; t < 9; t = t + 1) begin
                @(negedge clk);
                cfg_tap_idx = t;
                cfg_weight_vec = 0;
                cfg_bias_vec = 0;
                cfg_multiplier_vec = 0;
                cfg_shift_vec = 0;
                for (l = 0; l < 16; l = l + 1) begin
                    cfg_weight_vec[l*8 +: 8] = 8'sd1;
                    cfg_multiplier_vec[l*32 +: 32] = 32'sh7fff_ffff;
                end
                cfg_valid = 1;
                while (!cfg_ready) @(posedge clk);
                @(posedge clk);
                @(negedge clk);
                cfg_valid = 0;
            end
        end
    endtask

    task load_pw_weights;
        integer tile, k, lane;
        begin
            for (tile = 0; tile < 4; tile = tile + 1)
                for (k = 0; k < 16; k = k + 1) begin
                    weight_load_vec = 0;
                    for (lane = 0; lane < 8; lane = lane + 1)
                        weight_load_vec[lane*8 +: 8] = 8'sd1;
                    @(negedge clk);
                    weight_load_tile = tile;
                    weight_load_k = k;
                    weight_load_valid = 1;
                    while (!weight_load_ready) @(posedge clk);
                    @(posedge clk);
                    @(negedge clk);
                    weight_load_valid = 0;
                end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        configure_dw();
        load_pw_weights();
        @(negedge clk);
        start_valid = 1;
        while (!start_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        start_valid = 0;
        while (!done) @(posedge clk);
        if (error) errors = errors + 1;
        if (dw_writes !== 4096) errors = errors + 1;
        if (descriptors !== 256) errors = errors + 1;
        if (pw_tokens !== 8192) errors = errors + 1;
        if (output_writes !== 8192) errors = errors + 1;
        if (output_groups !== 512) errors = errors + 1;
        if (producer_jobs !== 32) errors = errors + 1;
        if (producer_stream_beats !== 4096) errors = errors + 1;
        if (result_checks !== 32768) errors = errors + 1;
        if (errors == 0)
            $display("PASS real_producer_shared64 DS1 cycles=%0d dw=%0d desc=%0d pw=%0d out=%0d jobs=%0d beats=%0d overlap=%0d dw_stalls=%0d pw_stalls=%0d",
                     total_cycles, dw_writes, descriptors, pw_tokens,
                     output_writes, producer_jobs, producer_stream_beats,
                     overlap_cycles, dw_stalls, pw_stalls);
        else begin
            $display("FAIL real_producer_shared64 DS1 errors=%0d cycles=%0d dw=%0d desc=%0d pw=%0d out=%0d jobs=%0d beats=%0d checks=%0d overlap=%0d dw_stalls=%0d pw_stalls=%0d",
                     errors, total_cycles, dw_writes, descriptors, pw_tokens,
                     output_writes, producer_jobs, producer_stream_beats,
                     result_checks, overlap_cycles, dw_stalls, pw_stalls);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat (4000000) @(posedge clk);
        $fatal(1, "REAL_PRODUCER_SHARED64_WATCHDOG state=%0d sched=%0d macro=%0d cycles=%0d dw=%0d desc=%0d pw=%0d out=%0d jobs=%0d beats=%0d",
               dut.u_sweep.state, dut.sched_state, dut.macro_q, total_cycles,
               dw_writes, descriptors, pw_tokens, output_writes,
               producer_jobs, producer_stream_beats);
    end
endmodule
`default_nettype wire
