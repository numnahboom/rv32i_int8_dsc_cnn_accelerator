`timescale 1ns/1ps
`default_nettype none

/*
 * Independent reference regression for the tagged partial-K block.
 * P and Cout are harness dimensions: each 8-pixel x 8-cout block is issued
 * independently, and the final Cout tail is masked by the harness.  This is
 * intentional because the RTL ABI is one fixed 8x8 block; no tail lane is
 * allowed to become a hidden computation shortcut.
 */
module tb_pw_systolic_array_8x8_partial_k_random;
    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg first_k;
    reg last_k;
    reg [7:0] k_group;
    reg [7:0] k_count;
    reg clear_acc;
    reg k_last;
    reg signed [63:0] act_vec;
    reg signed [63:0] wgt_vec;
    reg ready_out;
    wire valid_out;
    wire signed [2047:0] psum_out;

    integer errors;
    integer blocks;
    integer outputs;
    integer valid_checks;
    integer ci;
    integer pi;
    integer cb;
    integer k;
    integer row;
    integer col;
    integer lane;
    integer cin_cfg;
    integer p_cfg;
    integer cout_cfg;
    integer group_cfg;
    integer group_base;
    integer glen;
    integer expected [0:63];
    integer actual;
    integer hold_cycles;
    integer seed;

    pw_systolic_array_8x8 dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k),
        .k_group(k_group), .k_count(k_count),
        .clear_acc(clear_acc), .k_last(k_last),
        .act_vec(act_vec), .wgt_vec(wgt_vec),
        .ready_out(ready_out), .valid_out(valid_out), .psum_out(psum_out)
    );

    always #5 clk = ~clk;

    function integer av;
        input integer p;
        input integer kk;
        input integer rr;
        begin
            av = (((p + 3) * (kk + 5) + rr * 11 + 7) % 37) - 18;
        end
    endfunction

    function integer wv;
        input integer b;
        input integer kk;
        input integer cc;
        begin
            wv = (((b + 5) * (kk + 3) + cc * 13 + 2) % 29) - 14;
        end
    endfunction

    task feed_token;
        input integer block_id;
        input integer pixel_id;
        input integer kk;
        begin
            /* Random bubbles exercise token stability and exactly-once
             * acceptance without changing the held token's metadata. */
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
            k_group = 8'd0;
            k_count = 8'd0;
            clear_acc = 1'b0;
            k_last = 1'b0;
            repeat ((block_id + pixel_id + kk) % 3) @(negedge clk);
            /* Put the token on the interface only at a falling edge.  The
             * following rising edge is then the sole possible transfer edge,
             * avoiding a testbench race that can otherwise count one held
             * valid token twice under Verilator scheduling. */
            @(negedge clk);
            act_vec = 64'sd0;
            wgt_vec = 64'sd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                act_vec[(lane*8) +: 8] = av(pixel_id, kk, lane);
                wgt_vec[(lane*8) +: 8] = wv(block_id, kk, lane);
            end
            group_base = (kk / group_cfg) * group_cfg;
            glen = cin_cfg - group_base;
            if (glen > group_cfg)
                glen = group_cfg;
            first_k = (kk == 0);
            last_k = (kk == (cin_cfg - 1));
            k_group = kk / group_cfg;
            k_count = glen;
            /* Deliberately assert legacy fences at every group boundary. */
            clear_acc = (kk == 0) || (kk == group_cfg);
            k_last = last_k || (((kk + 1) < cin_cfg) &&
                                (((kk + 1) % group_cfg) == 0));
            if ($test$plusargs("TRACE_PW_PARTIAL"))
                $display("TB_TOKEN t=%0t block=%0d p=%0d kk=%0d first=%b last=%b group=%0d count=%0d",
                         $time,
                         block_id, pixel_id, kk, first_k, last_k,
                         k_group, k_count);
            valid_in = 1'b1;
            while (1) begin
                @(posedge clk);
                if (ready_in)
                    break;
            end
            @(negedge clk);
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
            k_group = 8'd0;
            k_count = 8'd0;
            clear_acc = 1'b0;
            k_last = 1'b0;
        end
    endtask

    task run_block;
        input integer block_id;
        input integer pixel_id;
        input integer valid_cout;
        begin
            for (row = 0; row < 8; row = row + 1)
                for (col = 0; col < 8; col = col + 1)
                    expected[row*8 + col] = 0;
            for (k = 0; k < cin_cfg; k = k + 1) begin
                for (row = 0; row < 8; row = row + 1)
                    for (col = 0; col < 8; col = col + 1)
                        expected[row*8 + col] = expected[row*8 + col] +
                            av(pixel_id, k, row) * wv(block_id, k, col);
                feed_token(block_id, pixel_id, k);
            end
            /* Deassert ready before waiting: otherwise the DUT may legally
             * consume the output on the same edge on which the wait observes
             * valid_out, making the stability check race the consumer. */
            ready_out = 1'b0;
            while (!valid_out)
                @(posedge clk);
            /* Hold output under backpressure and prove bit-for-bit stability. */
            hold_cycles = (block_id + pixel_id) % 4 + 1;
            repeat (hold_cycles) begin
                @(posedge clk);
                if (!valid_out)
                    errors = errors + 1;
                for (row = 0; row < 8; row = row + 1)
                    for (col = 0; col < valid_cout; col = col + 1) begin
                        lane = row * 8 + col;
                        actual = $signed(psum_out[(lane*32) +: 32]);
                        if (actual !== expected[lane])
                            errors = errors + 1;
                        valid_checks = valid_checks + 1;
                    end
            end
            /* Check all lanes for full Cout blocks; tail checks below are the
             * masked acceptance boundary for non-aligned Cout. */
            for (row = 0; row < 8; row = row + 1)
                for (col = 0; col < valid_cout; col = col + 1) begin
                    lane = row * 8 + col;
                    actual = $signed(psum_out[(lane*32) +: 32]);
                    if (actual !== expected[lane])
                        errors = errors + 1;
                    valid_checks = valid_checks + 1;
                end
            ready_out = 1'b1;
            @(posedge clk);
            outputs = outputs + 1;
        end
    endtask

    task run_config;
        input integer c_in;
        input integer pixels;
        input integer c_out;
        input integer g_size;
        begin
            cin_cfg = c_in;
            p_cfg = pixels;
            cout_cfg = c_out;
            group_cfg = g_size;
            for (pi = 0; pi < p_cfg; pi = pi + 1)
                for (cb = 0; cb < cout_cfg; cb = cb + 8)
                    run_block((pi * 7) + cb, pi,
                              ((cout_cfg - cb) >= 8) ? 8 : (cout_cfg - cb));
            blocks = blocks + p_cfg * ((cout_cfg + 7) / 8);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        first_k = 1'b0;
        last_k = 1'b0;
        k_group = 8'd0;
        k_count = 8'd0;
        clear_acc = 1'b0;
        k_last = 1'b0;
        act_vec = 64'sd0;
        wgt_vec = 64'sd0;
        ready_out = 1'b1;
        errors = 0;
        blocks = 0;
        outputs = 0;
        valid_checks = 0;
        seed = 32'h13579bdf;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        run_config(32, 1, 8, 7);
        run_config(48, 8, 16, 13);
        run_config(32, 17, 13, 16);

        if (dut.sim_token_errors != 0)
            errors = errors + dut.sim_token_errors;
        if (outputs != blocks)
            errors = errors + 1;
        if (errors == 0)
            $display("PASS tb_pw_systolic_array_8x8_partial_k_random blocks=%0d outputs=%0d valid_lane_checks=%0d",
                     blocks, outputs, valid_checks);
        else begin
            $display("FAIL tb_pw_systolic_array_8x8_partial_k_random blocks=%0d outputs=%0d errors=%0d",
                     blocks, outputs, errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
