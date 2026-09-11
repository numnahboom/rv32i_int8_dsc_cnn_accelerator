`timescale 1ns/1ps
`default_nettype none

/*
 * Full-layer retained DS1 composition regression.
 *
 * The DW and PW weights are deliberately zero, so every final quantizer
 * output has the independently predictable value 7 (the supplied final
 * output zero point).  The test still exercises every handshake: source
 * memory is delayed and randomly request-stalled, the four-byte sink
 * is randomly backpressured, and the exported PW lookup metadata is checked
 * while supplying the deterministic zero weight vector.
 */
module tb_ds1_retained_full_layer_orchestrator;
    localparam integer ADDR_WIDTH = 24;
    localparam integer EPOCH_WIDTH = 4;
    localparam integer TILE_WIDTH = 8;

    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;

    reg start_valid = 1'b0;
    wire start_ready;
    reg [ADDR_WIDTH-1:0] input_base_addr = 24'h0010_0000;
    reg [7:0] input_zero_point = 8'h80;
    reg [EPOCH_WIDTH-1:0] start_epoch = 4'h5;

    wire mem_req_valid;
    wire mem_req_ready;
    wire [ADDR_WIDTH-1:0] mem_req_addr;
    reg mem_resp_valid = 1'b0;
    reg [31:0] mem_resp_data = 32'd0;

    reg cfg_valid = 1'b0;
    wire cfg_ready;
    reg [3:0] cfg_tap_idx = 4'd0;
    reg signed [127:0] cfg_weight_vec = 128'sd0;
    reg signed [511:0] cfg_bias_vec = 512'sd0;
    reg signed [511:0] cfg_multiplier_vec = {16{32'sh7fff_ffff}};
    reg [95:0] cfg_shift_vec = 96'd0;
    reg [31:0] dw_output_zero_point = 32'd0;
    reg [31:0] dw_activation_min = -32'sd128;
    reg [31:0] dw_activation_max = 32'sd127;

    reg signed [63:0] pw_weight_vec = 64'sd0;
    wire weight_valid;
    wire [3:0] weight_k_index;
    wire [1:0] weight_cout_group;

    reg signed [255:0] final_bias_vec = 256'sd0;
    reg signed [255:0] final_multiplier_vec = {8{32'sh7fff_ffff}};
    reg [47:0] final_shift_vec = 48'd0;
    reg signed [31:0] final_output_zero_point_int32 = 32'sd7;
    reg signed [31:0] final_activation_min_int32 = -32'sd128;
    reg signed [31:0] final_activation_max_int32 = 32'sd127;

    wire out_valid_vec4;
    wire out_ready_vec4;
    wire signed [31:0] out_data_int8_vec4;
    wire [9:0] out_pixel_idx_vec4;
    wire [5:0] out_channel_idx_vec4;
    wire [15:0] out_byte_addr_vec4;
    wire [15:0] out_word_addr_vec4;
    wire [3:0] out_byte_en_vec4;
    wire error;
    wire busy;
    wire done;
    wire [7:0] overlap_count;
    wire [31:0] overlap_cycles;

    ds1_retained_full_layer_orchestrator #(
        .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(16),
        .EPOCH_WIDTH(EPOCH_WIDTH), .TILE_WIDTH(TILE_WIDTH), .FIFO_DEPTH(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .input_base_addr(input_base_addr),
        .input_zero_point(input_zero_point), .start_epoch(start_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_weight_vec(pw_weight_vec), .weight_valid(weight_valid),
        .weight_k_index(weight_k_index),
        .weight_cout_group(weight_cout_group),
        .final_bias_vec(final_bias_vec),
        .final_multiplier_vec(final_multiplier_vec),
        .final_shift_vec(final_shift_vec),
        .final_output_zero_point_int32(final_output_zero_point_int32),
        .final_activation_min_int32(final_activation_min_int32),
        .final_activation_max_int32(final_activation_max_int32),
        .out_valid_vec4(out_valid_vec4), .out_ready_vec4(out_ready_vec4),
        .out_data_int8_vec4(out_data_int8_vec4),
        .out_pixel_idx_vec4(out_pixel_idx_vec4),
        .out_channel_idx_vec4(out_channel_idx_vec4),
        .out_byte_addr_vec4(out_byte_addr_vec4),
        .out_word_addr_vec4(out_word_addr_vec4),
         .out_byte_en_vec4(out_byte_en_vec4),
         .error(error), .busy(busy), .done(done),
         .overlap_count(overlap_count), .overlap_cycles(overlap_cycles)
    );

    /* Deterministic pseudo-random backpressure and an eight-cycle source
     * response pipeline.  A response contains zero data because all DW
     * weights are zero; the request addresses are still checked below. */
    reg [31:0] lfsr = 32'h1ace_b00c;
    assign mem_req_ready = lfsr[0] | lfsr[3];
    assign out_ready_vec4 = lfsr[1] | lfsr[5];
    reg [7:0] response_valid_pipe = 8'd0;
    reg [ADDR_WIDTH-1:0] response_addr_pipe [0:7];
    integer pipe_i;
    integer mem_accepts = 0;
    integer mem_stalls = 0;
    integer input_backpressure_stalls = 0;
    integer source_address_errors = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'h1ace_b00c;
            response_valid_pipe <= 8'd0;
            mem_resp_valid <= 1'b0;
            mem_resp_data <= 32'd0;
            for (pipe_i = 0; pipe_i < 8; pipe_i = pipe_i + 1)
                response_addr_pipe[pipe_i] <= {ADDR_WIDTH{1'b0}};
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^
                    lfsr[1] ^ lfsr[0]};
            mem_resp_valid <= response_valid_pipe[7];
            mem_resp_data <= 32'd0;
            for (pipe_i = 7; pipe_i > 0; pipe_i = pipe_i - 1) begin
                response_valid_pipe[pipe_i] <= response_valid_pipe[pipe_i-1];
                response_addr_pipe[pipe_i] <= response_addr_pipe[pipe_i-1];
            end
            response_valid_pipe[0] <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                response_valid_pipe[0] <= 1'b1;
                response_addr_pipe[0] <= mem_req_addr;
                mem_accepts = mem_accepts + 1;
                if (mem_req_addr[1:0] != 2'b00 ||
                    mem_req_addr < input_base_addr ||
                    mem_req_addr >= (input_base_addr + 24'd16384))
                    source_address_errors = source_address_errors + 1;
            end
            if (mem_req_valid && !mem_req_ready)
                mem_stalls = mem_stalls + 1;
            if (dut.u_session.producer_req_valid &&
                !dut.u_session.producer_req_ready)
                input_backpressure_stalls = input_backpressure_stalls + 1;
        end
    end

    integer errors = 0;
    integer reported_errors = 0;
    integer output_count = 0;
    integer vec4_write_count = 0;
    integer output_stalls = 0;
    integer weight_cycles = 0;
    reg [32767:0] byte_seen = {32768{1'b0}};
    integer byte_i;
    integer byte_lane;
    integer expected_base;

    always @(posedge clk) begin
        if (!rst_n) begin
            byte_seen <= {32768{1'b0}};
        end else begin
            if (weight_valid) begin
                weight_cycles = weight_cycles + 1;
                if (weight_k_index > 4'd15 || weight_cout_group > 2'd3)
                    errors = errors + 1;
            end
            if (out_valid_vec4 && !out_ready_vec4)
                output_stalls = output_stalls + 1;
            if (out_valid_vec4 && out_ready_vec4) begin
                expected_base = (out_pixel_idx_vec4 * 16'd32) +
                                out_channel_idx_vec4;
                if ({1'b0, out_pixel_idx_vec4} >= 11'd1024 ||
                    out_channel_idx_vec4 >= 6'd32 ||
                    out_channel_idx_vec4[1:0] != 2'b00 ||
                    out_channel_idx_vec4 + 6'd3 >= 6'd32 ||
                    out_byte_addr_vec4 !== expected_base[15:0] ||
                    out_word_addr_vec4 !== (expected_base / 4) ||
                    out_byte_en_vec4 !== 4'b1111) begin
                    if (reported_errors < 8)
                        $display("OUTPUT_MISMATCH n=%0d pix=%0d ch=%0d addr=%0d word=%0d be=%b exp_addr=%0d",
                            output_count, out_pixel_idx_vec4,
                            out_channel_idx_vec4, out_byte_addr_vec4,
                            out_word_addr_vec4, out_byte_en_vec4,
                            expected_base);
                    errors = errors + 1;
                    reported_errors = reported_errors + 1;
                end
                for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                    if ($signed(out_data_int8_vec4[(byte_lane*8) +: 8]) !== 8'sd7) begin
                        if (reported_errors < 8)
                            $display("DATA_MISMATCH n=%0d byte=%0d got=%0d",
                                output_count, byte_lane,
                                $signed(out_data_int8_vec4[(byte_lane*8) +: 8]));
                        errors = errors + 1;
                        reported_errors = reported_errors + 1;
                    end
                    if ((expected_base + byte_lane) >= 32768 ||
                        byte_seen[expected_base + byte_lane]) begin
                        if (reported_errors < 8)
                            $display("DUPLICATE_ADDR n=%0d addr=%0d", output_count,
                                expected_base + byte_lane);
                        errors = errors + 1;
                        reported_errors = reported_errors + 1;
                    end
                    byte_seen[expected_base + byte_lane] <= 1'b1;
                end
                output_count = output_count + 1;
                vec4_write_count = vec4_write_count + 1;
            end
        end
    end

    task configure_dw;
        integer t;
        begin
            for (t = 0; t < 9; t = t + 1) begin
                @(negedge clk);
                cfg_tap_idx = t[3:0];
                cfg_valid = 1'b1;
                while (!cfg_ready) @(posedge clk);
                @(posedge clk);
                @(negedge clk);
                cfg_valid = 1'b0;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        configure_dw();
        @(negedge clk);
        start_valid = 1'b1;
        while (!start_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        start_valid = 1'b0;

        wait (done);
        /* Give the final output handshake and the done pulse one full edge
         * to settle before checking nonblocking counter updates. */
        @(posedge clk);
        #0;
        if (output_count != 8192 || vec4_write_count != 8192 ||
            dut.jobs_started_q !== 8'd64 ||
            dut.jobs_completed_q !== 8'd64 ||
            dut.bytes_emitted_q !== 16'd32768 ||
            dut.vec4_writes_q !== 16'd8192 ||
            dut.u_session.fill_count !== 32'd64 ||
            dut.u_session.dw_done_count !== 32'd64 ||
             dut.u_session.replay_release_count !== 32'd64 ||
             overlap_count < 8'd63 ||
             mem_accepts == 0 || input_backpressure_stalls == 0 ||
            weight_cycles == 0 || source_address_errors != 0 || errors != 0 ||
            error || dut.u_session.error ||
            dut.u_session.u_replay.sim_protocol_errors != 0 ||
            dut.u_session.u_dw.u_4x8.u_scratch0.sim_sequence_errors != 0 ||
            dut.u_session.u_dw.u_4x8.u_scratch1.sim_sequence_errors != 0) begin
            $display("FAIL tb_ds1_retained_full_layer_orchestrator done=%b vec4=%0d/%0d jobs=%0d/%0d fills=%0d dw=%0d releases=%0d bytes=%0d mem=%0d mem_stalls=%0d input_stalls=%0d out_stalls=%0d weights=%0d errors=%0d addr_errors=%0d adapter=%b replay=%0d scratch0=%0d scratch1=%0d",
                done, output_count, dut.vec4_writes_q, dut.jobs_started_q, dut.jobs_completed_q,
                dut.u_session.fill_count, dut.u_session.dw_done_count,
                dut.u_session.replay_release_count, dut.bytes_emitted_q,
                mem_accepts, mem_stalls, input_backpressure_stalls,
                output_stalls, weight_cycles, errors,
                source_address_errors, dut.u_session.error,
                dut.u_session.u_replay.sim_protocol_errors,
                dut.u_session.u_dw.u_4x8.u_scratch0.sim_sequence_errors,
                dut.u_session.u_dw.u_4x8.u_scratch1.sim_sequence_errors);
            $fatal(1);
        end
        for (byte_i = 0; byte_i < 32768; byte_i = byte_i + 1)
            if (!byte_seen[byte_i]) errors = errors + 1;
        if (errors != 0) begin
            $display("FAIL tb_ds1_retained_full_layer_orchestrator coverage_errors=%0d", errors);
            $fatal(1);
        end
            $display("PASS tb_ds1_retained_full_layer_orchestrator jobs=%0d fills=%0d dw=%0d releases=%0d overlap=%0d vec4_writes=%0d bytes=%0d mem_accepts=%0d mem_stalls=%0d input_stalls=%0d output_stalls=%0d weight_cycles=%0d cycles=%0d",
             dut.jobs_completed_q, dut.u_session.fill_count,
             dut.u_session.dw_done_count, dut.u_session.replay_release_count,
             overlap_count,
            vec4_write_count, dut.bytes_emitted_q, mem_accepts, mem_stalls,
            input_backpressure_stalls, output_stalls, weight_cycles,
            $time / 2);
        $finish;
    end

    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "WATCHDOG tb_ds1_retained_full_layer_orchestrator done=%b busy=%b outputs=%0d jobs=%0d/%0d state=%0d session_state=%0d phase=%0d",
               done, busy, output_count, dut.jobs_started_q,
               dut.jobs_completed_q, dut.state, dut.u_session.state,
               dut.u_session.phase);
    end
endmodule

`default_nettype wire
