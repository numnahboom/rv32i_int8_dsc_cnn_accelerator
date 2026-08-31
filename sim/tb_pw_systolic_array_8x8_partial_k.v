`timescale 1ns/1ps
`default_nettype none

/*
 * Tagged partial-K contract test for the 8x4 physical replay fabric.
 * Groups are intentionally ended with legacy k_last asserted on the
 * non-final groups; only last_k is allowed to release the reduction.  The
 * expected result is the complete 8x8 dot product, so a clear/seed/fence
 * error is visible in every lane rather than only in a final quantized byte.
 */
module tb_pw_systolic_array_8x8_partial_k;
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
    integer case_idx;
    integer k;
    integer lane;
    integer row;
    integer col;
    integer cin;
    integer group_size;
    integer group_base;
    integer group_len;
    integer group_id;
    integer expected [0:63];
    integer actual;

    pw_systolic_array_8x8 dut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k),
        .k_group(k_group), .k_count(k_count),
        .clear_acc(clear_acc), .k_last(k_last),
        .act_vec(act_vec), .wgt_vec(wgt_vec),
        .ready_out(ready_out), .valid_out(valid_out), .psum_out(psum_out)
    );

    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    function integer act_value;
        input integer which_case;
        input integer kk;
        input integer ll;
        begin
            if (which_case == 0)
                act_value = ((kk * 3 + ll * 5 + 7) % 31) - 15;
            else
                act_value = ((kk * 7 + ll * 3 + 11) % 41) - 20;
        end
    endfunction

    function integer wgt_value;
        input integer which_case;
        input integer kk;
        input integer ll;
        begin
            if (which_case == 0)
                wgt_value = ((kk * 5 + ll * 7 + 3) % 17) - 8;
            else
                wgt_value = ((kk * 11 + ll * 5 + 9) % 23) - 11;
        end
    endfunction

    task feed_token;
        input integer which_case;
        input integer kk;
        input integer gbase;
        input integer glen;
        begin
            @(negedge clk);
            act_vec = 64'sd0;
            wgt_vec = 64'sd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                act_vec[(lane*8) +: 8] = act_value(which_case, kk, lane);
                wgt_vec[(lane*8) +: 8] = wgt_value(which_case, kk, lane);
            end
            first_k = (kk == 0);
            /* last_k is the whole-reduction fence, not the end of a group. */
            last_k = (kk == (cin - 1));
            k_group = kk / group_size;
            k_count = glen;
            /* Deliberately adversarial legacy flags: the tagged contract
             * must win, including at a non-final group boundary. */
            clear_acc = (kk == 0) || (kk == group_size);
            k_last = last_k || (((kk + 1) < cin) &&
                                (((kk + 1) % group_size) == 0));
            if ($test$plusargs("TRACE_PW_PARTIAL"))
                $display("TB_DRIVE kk=%0d first=%b last=%b group=%0d count=%0d",
                         kk, first_k, last_k, k_group, k_count);
            valid_in = 1'b1;
            while (!ready_in)
                @(negedge clk);
            @(posedge clk);
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

    task run_case;
        input integer which_case;
        begin
            if (which_case == 0) begin
                cin = 32;
                group_size = 7;
            end else begin
                cin = 48;
                group_size = 16;
            end
            for (row = 0; row < 8; row = row + 1)
                for (col = 0; col < 8; col = col + 1)
                    expected[row*8 + col] = 0;

            for (k = 0; k < cin; k = k + 1) begin
                group_base = (k / group_size) * group_size;
                group_len = cin - group_base;
                if (group_len > group_size)
                    group_len = group_size;
                for (row = 0; row < 8; row = row + 1)
                    for (col = 0; col < 8; col = col + 1)
                        expected[row*8 + col] = expected[row*8 + col] +
                            act_value(which_case, k, row) *
                            wgt_value(which_case, k, col);
                feed_token(which_case, k, group_base, group_len);
            end

            while (!valid_out)
                @(posedge clk);
            ready_out = 1'b0;
            repeat (3) begin
                @(posedge clk);
                if (!valid_out)
                    errors = errors + 1;
                for (lane = 0; lane < 64; lane = lane + 1) begin
                    actual = $signed(psum_out[(lane*32) +: 32]);
                    if (actual !== expected[lane]) begin
                        $display("MISMATCH case=%0d lane=%0d expected=%0d actual=%0d",
                                 which_case, lane, expected[lane], actual);
                        errors = errors + 1;
                    end
                end
            end
            if (dut.sim_token_errors != 0) begin
                $display("TOKEN_ASSERT_ERRORS case=%0d count=%0d",
                         which_case, dut.sim_token_errors);
                errors = errors + dut.sim_token_errors;
            end
            ready_out = 1'b1;
            @(posedge clk);
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
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        run_case(0);
        run_case(1);
        if (errors == 0)
            $display("PASS tb_pw_systolic_array_8x8_partial_k cases=2 checks=128");
        else begin
            $display("FAIL tb_pw_systolic_array_8x8_partial_k errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
