`timescale 1ns/1ps
`default_nettype none

module tb_ds1_retained_session_wrapper #(
    parameter integer TB_MICROGROUPS_PER_START = 2
);
    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    reg start_valid = 0; wire start_ready;
    reg [23:0] input_base_addr = 24'h0010_0000;
    reg [5:0] global_y = 6'd1, global_x = 6'd1;
    reg [7:0] input_zero_point = 8'h80;
    reg [3:0] start_epoch = 4'h5; reg [7:0] start_tile = 8'h20;
    wire mem_req_valid; reg mem_req_ready = 1; wire [23:0] mem_req_addr;
    reg mem_resp_valid = 0; reg [31:0] mem_resp_data = 0;
    reg cfg_valid = 0; wire cfg_ready; reg [3:0] cfg_tap_idx = 0;
    reg signed [127:0] cfg_weight_vec = 0;
    reg signed [511:0] cfg_bias_vec = 0, cfg_multiplier_vec = 0;
    reg [95:0] cfg_shift_vec = 0;
    reg [31:0] dw_output_zero_point = 32'd0;
    reg [31:0] dw_activation_min = 32'h8000_0000;
    reg [31:0] dw_activation_max = 32'h7fff_ffff;
    reg signed [63:0] pw_weight_vec = 0;
    wire weight_valid;
    wire [3:0] weight_k_index;
    wire [1:0] weight_cout_group;
    wire out_valid; reg out_ready = 1; wire out_row_idx; wire [1:0] out_cout_group;
    wire signed [2047:0] out_psum;
    wire [1:0] state; wire [1:0] microgroup; wire [31:0] fill_count;
    wire [31:0] dw_done_count, replay_release_count; wire error, busy, done;

    ds1_retained_session_wrapper #(
        .MICROGROUPS_PER_START(TB_MICROGROUPS_PER_START)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
        .input_base_addr(input_base_addr), .global_y(global_y), .global_x(global_x),
        .input_zero_point(input_zero_point), .start_epoch(start_epoch), .start_tile(start_tile),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_weight_vec(pw_weight_vec), .out_valid(out_valid), .out_ready(out_ready),
        .weight_valid(weight_valid), .weight_k_index(weight_k_index),
        .weight_cout_group(weight_cout_group),
        .out_row_idx(out_row_idx), .out_cout_group(out_cout_group), .out_psum(out_psum),
        .state(state), .microgroup(microgroup), .fill_count(fill_count),
        .dw_done_count(dw_done_count), .replay_release_count(replay_release_count),
        .error(error), .busy(busy), .done(done)
    );

    /* Two-cycle in-order source memory.  Requests are deliberately stalled
     * on a repeatable pattern and responses encode their translated address. */
    reg qv0 = 0, qv1 = 0; reg [23:0] qa0 = 0, qa1 = 0;
    integer cycles = 0, errors = 0, outputs = 0, expected_job = 0;
    integer fill_observed = 0, dw_observed = 0, release_observed = 0;
    integer mem_accepts = 0, mem_stalls = 0, source_stalls = 0, output_stalls = 0;
    integer weight_cycles = 0;
    integer req_group, req_word, req_pixel, req_sy, req_sx, expected_addr;
    reg hold_active = 0, hold_row = 0; reg [1:0] hold_group = 0;
    reg signed [2047:0] hold_psum = 0;
    integer i;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (!rst_n) begin
            mem_resp_valid <= 0; mem_resp_data <= 0; mem_req_ready <= 1;
            qv0 <= 0; qv1 <= 0;
        end else begin
            mem_resp_valid <= qv0;
            mem_resp_data <= {8'h00, qa0};
            qv0 <= qv1; qa0 <= qa1; qv1 <= 0;
            mem_req_ready <= ((cycles % 7) != 3);
            if (mem_req_valid && mem_req_ready) begin
                req_group = mem_accepts / 160;
                req_word = mem_accepts % 160;
                req_pixel = req_word / 4;
                req_sy = req_pixel / 10;
                req_sx = req_pixel % 10;
                expected_addr = input_base_addr +
                    ((((global_y + req_group*2 - 1 + req_sy) * 32) +
                      (global_x - 1 + req_sx)) * 16) +
                    ((req_word % 4) * 4);
                if (mem_req_addr !== expected_addr[23:0]) errors = errors + 1;
                mem_accepts = mem_accepts + 1;
                qv1 <= 1; qa1 <= mem_req_addr;
            end
            if (mem_req_valid && !mem_req_ready) mem_stalls = mem_stalls + 1;
            if (dut.producer_req_valid && !dut.producer_req_ready)
                source_stalls = source_stalls + 1;
            if (weight_valid) begin
                weight_cycles = weight_cycles + 1;
                if (weight_k_index > 4'd15 || weight_cout_group > 2'd3)
                    errors = errors + 1;
            end
        end
    end

    /* Hold the result interface down on selected cycles.  The held payload
     * and both tags must remain unchanged until the handshake. */
    always @* begin
        out_ready = ((cycles % 13) != 4) && ((cycles % 17) != 9);
        pw_weight_vec = 64'sd1;
        for (i = 0; i < 8; i = i + 1)
            pw_weight_vec[(i*8) +: 8] = 8'sd1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            hold_active <= 0;
        end else begin
            if (hold_active) begin
                if (!out_valid || out_row_idx !== hold_row ||
                    out_cout_group !== hold_group || out_psum !== hold_psum)
                    errors = errors + 1;
            end
            if (out_valid && !out_ready) begin
                output_stalls = output_stalls + 1;
                hold_active <= 1; hold_row <= out_row_idx;
                hold_group <= out_cout_group; hold_psum <= out_psum;
            end else hold_active <= 0;
            if (out_valid && out_ready) begin
                if (out_row_idx !== (expected_job / 4) ||
                    out_cout_group !== (expected_job % 4))
                    errors = errors + 1;
                outputs = outputs + 1;
                expected_job = expected_job + 1;
            end
            if (replay_release_count != release_observed) begin
                release_observed = replay_release_count;
                expected_job = 0;
            end
            if (fill_count > fill_observed) fill_observed = fill_count;
            if (dw_done_count > dw_observed) dw_observed = dw_done_count;
            if (replay_release_count > release_observed)
                release_observed = replay_release_count;
        end
    end

    task configure;
        integer t, l;
        begin
            for (t = 0; t < 9; t = t + 1) begin
                @(negedge clk); cfg_tap_idx = t; cfg_weight_vec = 0;
                cfg_bias_vec = 0; cfg_multiplier_vec = 0; cfg_shift_vec = 0;
                for (l = 0; l < 16; l = l + 1) begin
                    cfg_weight_vec[l*8 +: 8] = 8'sd1;
                    cfg_bias_vec[l*32 +: 32] = 0;
                    cfg_multiplier_vec[l*32 +: 32] = 32'sh7fff_ffff;
                end
                cfg_valid = 1;
                while (!cfg_ready) @(posedge clk);
                @(posedge clk); @(negedge clk); cfg_valid = 0;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1; configure();
        @(negedge clk); start_valid = 1;
        while (!start_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); start_valid = 0;
        while (!done && cycles < 300000) @(posedge clk);
        if (!done || fill_count !== TB_MICROGROUPS_PER_START ||
            dw_done_count !== TB_MICROGROUPS_PER_START ||
            replay_release_count !== TB_MICROGROUPS_PER_START ||
            outputs !== (TB_MICROGROUPS_PER_START * 8) ||
            mem_accepts !== (TB_MICROGROUPS_PER_START * 160) ||
            errors != 0 || error ||
            source_stalls == 0 ||
            ((TB_MICROGROUPS_PER_START != 1) && output_stalls == 0) ||
            weight_cycles == 0 || dut.u_replay.sim_protocol_errors != 0) begin
            $display("FAIL tb_ds1_retained_session_wrapper done=%b microgroups=%0d fills=%0d dw=%0d releases=%0d outputs=%0d weights=%0d errors=%0d adapter_error=%b replay_errors=%0d cycles=%0d state=%0d phase=%0d", done, TB_MICROGROUPS_PER_START, fill_count, dw_done_count, replay_release_count, outputs, weight_cycles, errors, error, dut.u_replay.sim_protocol_errors, cycles, state, dut.phase);
            $fatal(1);
        end
            $display("PASS tb_ds1_retained_session_wrapper microgroups=%0d fills=%0d dw_done=%0d outputs=%0d releases=%0d weights=%0d cycles=%0d mem_accepts=%0d mem_stalls=%0d source_stalls=%0d output_stalls=%0d", TB_MICROGROUPS_PER_START, fill_count, dw_done_count, outputs, replay_release_count, weight_cycles, cycles, mem_accepts, mem_stalls, source_stalls, output_stalls);
        $finish;
    end
    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule

`default_nettype wire
