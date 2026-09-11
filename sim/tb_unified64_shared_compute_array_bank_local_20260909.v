`timescale 1ns/1ps
`default_nettype none

/*
 * Direct shared-array differential regression for the bank-local completion
 * candidate.  It deliberately drives the public arithmetic ABI, so it can
 * cover partial-K lengths that the C0 sweep does not instantiate directly.
 * Two blocks are sent back-to-back for every case; the sink applies both
 * pseudo-random stalls and one long stall on a final beat.  Every accepted
 * output byte, mask, tag, and coordinate is checked against the integer
 * accumulation reference.
 */
module tb_unified64_shared_compute_array_bank_local_20260909;
    reg clk;
    reg rst_n;
    reg mode_stem;
    reg valid_in;
    wire ready_in;
    reg first_k;
    reg last_k;
    reg [7:0] k_idx;
    reg signed [63:0] act_vec;
    reg signed [127:0] wgt_vec16;
    reg [7:0] pixel_mask;
    reg [15:0] cout_mask;
    reg [10:0] pixel_base;
    reg [8:0] spatial_tag;
    reg [8:0] cout_base;
    reg signed [511:0] bias_vec;
    reg signed [511:0] multiplier_vec;
    reg [95:0] shift_vec;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    reg ready_out;
    wire valid_out;
    wire [10:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire [3:0] out_lane_mask;
    wire signed [31:0] out_data;
    wire [8:0] out_spatial_tag;
    wire [2:0] out_inner_pixel;
    wire busy;
    wire [31:0] metric_token_count, metric_masked_mac_count, metric_commit_count;

    unified64_shared_compute_array dut (
        .clk(clk), .rst_n(rst_n), .mode_stem(mode_stem),
        .valid_in(valid_in), .ready_in(ready_in), .first_k(first_k),
        .last_k(last_k), .k_idx(k_idx), .act_vec(act_vec),
        .wgt_vec16(wgt_vec16), .pixel_mask(pixel_mask),
        .cout_mask(cout_mask), .pixel_base(pixel_base),
        .spatial_tag(spatial_tag), .cout_base(cout_base),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32), .ready_out(ready_out),
        .valid_out(valid_out), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_lane_mask(out_lane_mask),
        .out_data(out_data), .out_spatial_tag(out_spatial_tag),
        .out_inner_pixel(out_inner_pixel), .busy(busy),
        .metric_token_count(metric_token_count),
        .metric_masked_mac_count(metric_masked_mac_count),
        .metric_commit_count(metric_commit_count)
    );

    integer exp_sum [0:1][0:15][0:15];
    integer seen [0:1][0:15][0:3];
    integer block_pixel_base [0:1];
    integer block_cout_base [0:1];
    integer block_tag [0:1];
    integer case_mode;
    integer case_k;
    integer case_tag_base;
    integer expected_outputs;
    integer output_count;
    integer errors;
    integer total_errors;
    integer case_active;
    integer sink_cycle;
    integer long_stall_count;
    integer final_stall_used;
    integer stall_hold;
    reg [8:0] hold_spatial_tag;
    reg [10:0] hold_pixel_idx;
    reg [8:0] hold_channel_base;
    reg [3:0] hold_lane_mask;
    reg signed [31:0] hold_data;

    integer i, j, q, b, p, c, k, timeout;

    always #1 clk = ~clk;

    function integer signed test_act;
        input integer block_idx;
        input integer kk;
        input integer pp;
        input integer stem;
        integer z;
        begin
            z = (block_idx * 5 + kk * 3 + pp * 2 + stem) & 3;
            if (z == 0) test_act = -1;
            else if (z == 1) test_act = 1;
            else test_act = 0;
        end
    endfunction

    function integer signed test_wgt;
        input integer block_idx;
        input integer kk;
        input integer cc;
        input integer stem;
        integer z;
        begin
            z = (block_idx * 7 + kk * 5 + cc * 3 + stem * 2) & 3;
            if (z == 0) test_wgt = -1;
            else if (z == 1) test_wgt = 1;
            else test_wgt = 0;
        end
    endfunction

    function integer signed quant_half;
        input integer x;
        integer ax;
        begin
            if (x < 0) begin
                ax = -x;
                quant_half = -((ax + 1) / 2);
            end else begin
                quant_half = (x + 1) / 2;
            end
            if (quant_half > 127) quant_half = 127;
            if (quant_half < -128) quant_half = -128;
        end
    endfunction

    wire output_is_last = valid_out &&
        (out_inner_pixel == (case_mode ? 3 : 7)) &&
        ((out_channel_base - block_cout_base[0] == (case_mode ? 12 : 4)) ||
         (out_channel_base - block_cout_base[1] == (case_mode ? 12 : 4)));

    /* Sink control is changed only on a falling edge.  Thus the ready/valid
     * contract is stable for every sampled rising edge. */
    always @(negedge clk) begin
        if (!rst_n) begin
            ready_out <= 1'b1;
            sink_cycle <= 0;
            long_stall_count <= 0;
        end else if (!case_active) begin
            ready_out <= 1'b1;
            sink_cycle <= 0;
            long_stall_count <= 0;
        end else begin
            sink_cycle <= sink_cycle + 1;
            if (long_stall_count > 0) begin
                ready_out <= 1'b0;
                long_stall_count <= long_stall_count - 1;
            end else if (!final_stall_used && output_is_last) begin
                ready_out <= 1'b0;
                long_stall_count <= 23;
                final_stall_used <= 1;
            end else begin
                ready_out <= ((sink_cycle % 17) != 3) &&
                             ((sink_cycle % 29) != 11) &&
                             ((sink_cycle % 31) != 19);
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            stall_hold = 0;
        end else if (case_active) begin
            if (valid_out && !ready_out) begin
                if (!stall_hold) begin
                    stall_hold = 1;
                    hold_spatial_tag = out_spatial_tag;
                    hold_pixel_idx = out_pixel_idx;
                    hold_channel_base = out_channel_base;
                    hold_lane_mask = out_lane_mask;
                    hold_data = out_data;
                end else if ((out_spatial_tag !== hold_spatial_tag) ||
                             (out_pixel_idx !== hold_pixel_idx) ||
                             (out_channel_base !== hold_channel_base) ||
                             (out_lane_mask !== hold_lane_mask) ||
                             (out_data !== hold_data)) begin
                    $display("FAIL STALL_UNSTABLE tag=%0d/%0d pixel=%0d/%0d cout=%0d/%0d mask=%h/%h data=%h/%h",
                             out_spatial_tag, hold_spatial_tag, out_pixel_idx,
                             hold_pixel_idx, out_channel_base,
                             hold_channel_base, out_lane_mask, hold_lane_mask,
                             out_data, hold_data);
                    errors = errors + 1;
                end
            end else begin
                stall_hold = 0;
            end

            if (valid_out && ready_out) begin
                integer bi, row, grp, lane, got, want;
                bi = -1;
                for (q = 0; q < 2; q = q + 1)
                    if (out_spatial_tag == block_tag[q]) bi = q;
                if ((bi < 0) || (out_inner_pixel >= (case_mode ? 4 : 8))) begin
                    $display("FAIL OUTPUT_TAG tag=%0d inner=%0d mode=%0d",
                             out_spatial_tag, out_inner_pixel, case_mode);
                    errors = errors + 1;
                end else begin
                    row = out_inner_pixel;
                    if (out_pixel_idx !== block_pixel_base[bi] + row) begin
                        $display("FAIL OUTPUT_PIXEL tag=%0d got=%0d exp=%0d",
                                 out_spatial_tag, out_pixel_idx,
                                 block_pixel_base[bi] + row);
                        errors = errors + 1;
                    end
                    if (out_channel_base < block_cout_base[bi] ||
                        ((out_channel_base - block_cout_base[bi]) % 4) != 0) begin
                        $display("FAIL OUTPUT_CHANNEL tag=%0d cout=%0d base=%0d",
                                 out_spatial_tag, out_channel_base,
                                 block_cout_base[bi]);
                        errors = errors + 1;
                    end else begin
                        grp = (out_channel_base - block_cout_base[bi]) / 4;
                        if (grp >= (case_mode ? 4 : 2)) begin
                            $display("FAIL OUTPUT_GROUP tag=%0d grp=%0d",
                                     out_spatial_tag, grp);
                            errors = errors + 1;
                        end else if (out_lane_mask !== 4'hf) begin
                            $display("FAIL OUTPUT_MASK tag=%0d mask=%h",
                                     out_spatial_tag, out_lane_mask);
                            errors = errors + 1;
                        end else if (seen[bi][row][grp] != 0) begin
                            $display("FAIL OUTPUT_DUP tag=%0d row=%0d grp=%0d",
                                     out_spatial_tag, row, grp);
                            errors = errors + 1;
                        end else begin
                            seen[bi][row][grp] = 1;
                            for (lane = 0; lane < 4; lane = lane + 1) begin
                                got = $signed(out_data[(lane*8) +: 8]);
                                want = quant_half(exp_sum[bi][row][grp*4+lane]);
                                if (got != want) begin
                                    $display("FAIL OUTPUT_DATA tag=%0d row=%0d grp=%0d lane=%0d got=%0d exp=%0d acc=%0d",
                                             out_spatial_tag, row, grp, lane,
                                             got, want,
                                             exp_sum[bi][row][grp*4+lane]);
                                    errors = errors + 1;
                                end
                            end
                            output_count = output_count + 1;
                        end
                    end
                end
            end
        end
    end

    task automatic drive_block;
        input integer block_idx;
        integer kk, pp, cc, av, wv;
        begin
            for (kk = 0; kk < case_k; kk = kk + 1) begin
                act_vec = 64'sd0;
                wgt_vec16 = 128'sd0;
                for (pp = 0; pp < (case_mode ? 4 : 8); pp = pp + 1) begin
                    av = test_act(block_idx, kk, pp, case_mode);
                    act_vec[(pp*8) +: 8] = av;
                end
                for (cc = 0; cc < (case_mode ? 16 : 8); cc = cc + 1) begin
                    wv = test_wgt(block_idx, kk, cc, case_mode);
                    wgt_vec16[(cc*8) +: 8] = wv;
                    exp_sum[block_idx][0][cc] = exp_sum[block_idx][0][cc] +
                                                 test_act(block_idx, kk, 0, case_mode) * wv;
                end
                for (pp = 1; pp < (case_mode ? 4 : 8); pp = pp + 1)
                    for (cc = 0; cc < (case_mode ? 16 : 8); cc = cc + 1)
                        exp_sum[block_idx][pp][cc] = exp_sum[block_idx][pp][cc] +
                            test_act(block_idx, kk, pp, case_mode) *
                            test_wgt(block_idx, kk, cc, case_mode);
                first_k = (kk == 0);
                last_k = (kk == case_k - 1);
                k_idx = kk[7:0];
                mode_stem = case_mode;
                pixel_mask = case_mode ? 8'h0f : 8'hff;
                cout_mask = case_mode ? 16'hffff : 16'h00ff;
                pixel_base = block_pixel_base[block_idx];
                spatial_tag = block_tag[block_idx];
                cout_base = block_cout_base[block_idx];
                valid_in = 1'b1;
                /* Sample ready at a falling edge, then consume exactly one
                 * rising-edge handshake.  Looking at ready after that edge
                 * would observe the DUT's next-state deassertion and count
                 * the same token twice in a K=1 block. */
                while (!ready_in)
                    @(negedge clk);
                @(posedge clk);
                @(negedge clk);
            end
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
        end
    endtask

    task automatic run_case;
        input integer cid;
        input integer k_len;
        input integer stem;
        integer wait_cycles;
        begin
            case_active = 0;
            rst_n = 1'b0;
            valid_in = 1'b0;
            repeat (5) @(posedge clk);
            case_mode = stem;
            case_k = k_len;
            case_tag_base = cid * 4;
            expected_outputs = 2 * (stem ? 4 * 4 : 8 * 2);
            output_count = 0;
            errors = 0;
            sink_cycle = 0;
            long_stall_count = 0;
            final_stall_used = 0;
            stall_hold = 0;
            for (b = 0; b < 2; b = b + 1) begin
                block_tag[b] = case_tag_base + b + 1;
                block_pixel_base[b] = cid * 64 + b * 16;
                block_cout_base[b] = stem ? (b * 16) : (b * 8);
                for (p = 0; p < 16; p = p + 1)
                    for (c = 0; c < 16; c = c + 1) begin
                        exp_sum[b][p][c] = 0;
                        for (q = 0; q < 4; q = q + 1)
                            seen[b][p][q] = 0;
                    end
            end
            bias_vec = 512'sd0;
            multiplier_vec = 512'sd0;
            shift_vec = 96'd0;
            for (c = 0; c < (stem ? 16 : 8); c = c + 1)
                multiplier_vec[(c*32) +: 32] = 32'sh40000000;
            output_zero_point_int32 = 0;
            activation_min_int32 = -128;
            activation_max_int32 = 127;
            rst_n = 1'b1;
            case_active = 1;
            @(negedge clk);
            drive_block(0);
            drive_block(1);
            valid_in = 1'b0;
            wait_cycles = 0;
            while ((output_count < expected_outputs || busy) &&
                   (wait_cycles < 100000)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles >= 100000) begin
                $display("FAIL CASE_TIMEOUT cid=%0d k=%0d stem=%0d out=%0d/%0d busy=%0d",
                         cid, k_len, stem, output_count, expected_outputs, busy);
                errors = errors + 1;
            end
            for (b = 0; b < 2; b = b + 1)
                for (p = 0; p < (stem ? 4 : 8); p = p + 1)
                    for (q = 0; q < (stem ? 4 : 2); q = q + 1)
                        if (seen[b][p][q] != 1) begin
                            $display("FAIL CASE_LEDGER cid=%0d k=%0d stem=%0d block=%0d row=%0d grp=%0d seen=%0d",
                                     cid, k_len, stem, b, p, q, seen[b][p][q]);
                            errors = errors + 1;
                        end
            if (errors == 0)
                $display("PASS ARRAY_CASE cid=%0d k=%0d stem=%0d outputs=%0d tokens=%0d commits=%0d stalls_final=%0d",
                         cid, k_len, stem, output_count,
                         metric_token_count, metric_commit_count,
                         final_stall_used);
            else
                $display("FAIL ARRAY_CASE cid=%0d k=%0d stem=%0d errors=%0d outputs=%0d/%0d",
                         cid, k_len, stem, errors, output_count, expected_outputs);
            total_errors = total_errors + errors;
            case_active = 0;
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        mode_stem = 1'b0;
        valid_in = 1'b0;
        first_k = 1'b0;
        last_k = 1'b0;
        k_idx = 0;
        act_vec = 0;
        wgt_vec16 = 0;
        pixel_mask = 0;
        cout_mask = 0;
        pixel_base = 0;
        spatial_tag = 0;
        cout_base = 0;
        bias_vec = 0;
        multiplier_vec = 0;
        shift_vec = 0;
        output_zero_point_int32 = 0;
        activation_min_int32 = -128;
        activation_max_int32 = 127;
        ready_out = 1'b1;
        case_active = 0;
        errors = 0;
        total_errors = 0;
        repeat (2) @(posedge clk);
        run_case(0, 1, 0);
        run_case(1, 16, 0);
        run_case(2, 64, 0);
        run_case(3, 128, 0);
        run_case(4, 256, 0);
        run_case(5, 1, 1);
        run_case(6, 16, 1);
        run_case(7, 64, 1);
        run_case(8, 128, 1);
        run_case(9, 256, 1);
        $display("ARRAY_BANK_LOCAL_SUMMARY cases=10 errors=%0d", total_errors);
        if (total_errors == 0)
            $finish;
        else
            $fatal(1, "array bank-local regression failed");
    end

    initial begin
        repeat (3000000) @(posedge clk);
        $fatal(1, "array bank-local global watchdog");
    end
endmodule

`default_nettype wire
