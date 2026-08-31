`timescale 1ns/1ps
`default_nettype none

module tb_mac16_stream_adapters;
    reg clk, rst_n;
    reg stem_valid, stem_first, stem_last, stem_ready_out;
    reg [7:0] stem_idx; reg [15:0] stem_mask;
    reg signed [7:0] stem_act; reg signed [127:0] stem_weight;
    wire stem_ready, stem_valid_out;
    wire [7:0] stem_idx_out; wire [15:0] stem_mask_out;
    wire signed [511:0] stem_sum_out;
    reg dw_valid, dw_first, dw_last, dw_ready_out;
    reg [7:0] dw_idx; reg [15:0] dw_mask;
    reg signed [127:0] dw_act, dw_weight;
    wire dw_ready, dw_valid_out;
    wire [7:0] dw_idx_out; wire [15:0] dw_mask_out;
    wire signed [511:0] dw_sum_out;
    integer lane, k, errors, outputs_seen, got;
    integer expected [0:15];

    mac16_stream_shared_wrapper dut (
        .clk(clk), .rst_n(rst_n),
        .stem_valid_in(stem_valid), .stem_ready_in(stem_ready),
        .stem_first_token(stem_first), .stem_last_token(stem_last),
        .stem_token_idx(stem_idx), .stem_lane_mask(stem_mask),
        .stem_act_scalar(stem_act), .stem_weight_vec(stem_weight),
        .stem_ready_out(stem_ready_out), .stem_valid_out(stem_valid_out),
        .stem_token_idx_out(stem_idx_out), .stem_lane_mask_out(stem_mask_out),
        .stem_sum_out(stem_sum_out),
        .dw_valid_in(dw_valid), .dw_ready_in(dw_ready),
        .dw_first_token(dw_first), .dw_last_token(dw_last),
        .dw_token_idx(dw_idx), .dw_lane_mask(dw_mask),
        .dw_act_vec(dw_act), .dw_weight_vec(dw_weight),
        .dw_ready_out(dw_ready_out), .dw_valid_out(dw_valid_out),
        .dw_token_idx_out(dw_idx_out), .dw_lane_mask_out(dw_mask_out),
        .dw_sum_out(dw_sum_out)
    );

    always #5 clk = ~clk;

    function integer sval;
        input integer cid, kk, ll;
        begin sval = ((kk * 29 + ll * 7 + cid * 13) % 61) - 30; end
    endfunction
    function integer dval;
        input integer cid, kk, ll;
        begin dval = ((kk * 17 + ll * 23 + cid * 11) % 67) - 33; end
    endfunction
    function integer extreme;
        input integer kk, ll;
        begin extreme = (((kk + ll) % 2) == 0) ? 127 : -128; end
    endfunction

    task feed_stem;
        input integer cid, kk, count; input [15:0] mask;
        begin
            @(negedge clk);
            stem_act = (cid == 3) ? extreme(kk, 0) : sval(cid, kk, 0);
            stem_weight = 128'sd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                stem_weight[(lane*8) +: 8] =
                    (cid == 3) ? extreme(kk, lane) : sval(cid, kk, lane);
            stem_idx = kk; stem_first = (kk == 0); stem_last = (kk == count - 1);
            stem_mask = mask; stem_valid = 1'b1;
            while (!stem_ready) @(negedge clk);
            @(posedge clk); @(negedge clk);
            stem_valid = 1'b0; stem_first = 1'b0; stem_last = 1'b0;
            stem_idx = 0; stem_mask = 0;
            if ((kk % 3) == 1) repeat (2) @(posedge clk);
        end
    endtask

    task feed_dw;
        input integer cid, kk, count; input [15:0] mask;
        begin
            @(negedge clk); dw_act = 128'sd0; dw_weight = 128'sd0;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                dw_act[(lane*8) +: 8] = (cid == 3) ? extreme(kk, lane) : dval(cid, kk, lane);
                dw_weight[(lane*8) +: 8] =
                    (cid == 3) ? extreme(kk, lane + 1) : dval(cid, kk, lane + 1);
            end
            dw_idx = kk; dw_first = (kk == 0); dw_last = (kk == count - 1);
            dw_mask = mask; dw_valid = 1'b1;
            while (!dw_ready) @(negedge clk);
            @(posedge clk); @(negedge clk);
            dw_valid = 1'b0; dw_first = 1'b0; dw_last = 1'b0;
            dw_idx = 0; dw_mask = 0;
            if ((kk % 4) == 2) repeat (3) @(posedge clk);
        end
    endtask

    task check_stem;
        input [15:0] mask; input integer idx;
        begin
            while (!stem_valid_out) begin @(posedge clk); #1; end
            if (stem_idx_out !== idx) begin $display("BAD STEM IDX %0d %0d", stem_idx_out, idx); errors = errors + 1; end
            if (stem_mask_out !== mask || dw_valid_out) begin $display("BAD STEM ROUTE mask=%h other=%b", stem_mask_out, dw_valid_out); errors = errors + 1; end
            outputs_seen = outputs_seen + 1; stem_ready_out = 1'b0;
            repeat (3) begin
                @(posedge clk); #1;
                if (!stem_valid_out) begin $display("STEM lost output hold"); errors = errors + 1; end
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    got = $signed(stem_sum_out[(lane*32) +: 32]);
                    if (got !== expected[lane]) begin $display("BAD STEM SUM l=%0d got=%0d exp=%0d", lane, got, expected[lane]); errors = errors + 1; end
                    if (!mask[lane] && got != 0) begin $display("BAD STEM MASK l=%0d got=%0d", lane, got); errors = errors + 1; end
                end
            end
            stem_ready_out = 1'b1; @(posedge clk); #1;
            if (stem_valid_out) begin $display("STEM output did not clear"); errors = errors + 1; end
        end
    endtask

    task check_dw;
        input [15:0] mask; input integer idx;
        begin
            while (!dw_valid_out) begin @(posedge clk); #1; end
            if (dw_idx_out !== idx) begin $display("BAD DW IDX %0d %0d", dw_idx_out, idx); errors = errors + 1; end
            if (dw_mask_out !== mask || stem_valid_out) begin $display("BAD DW ROUTE mask=%h other=%b", dw_mask_out, stem_valid_out); errors = errors + 1; end
            outputs_seen = outputs_seen + 1; dw_ready_out = 1'b0;
            repeat (3) begin
                @(posedge clk); #1;
                if (!dw_valid_out) begin $display("DW lost output hold"); errors = errors + 1; end
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    got = $signed(dw_sum_out[(lane*32) +: 32]);
                    if (got !== expected[lane]) begin $display("BAD DW SUM l=%0d got=%0d exp=%0d", lane, got, expected[lane]); errors = errors + 1; end
                    if (!mask[lane] && got != 0) begin $display("BAD DW MASK l=%0d got=%0d", lane, got); errors = errors + 1; end
                end
            end
            dw_ready_out = 1'b1; @(posedge clk); #1;
            if (dw_valid_out) begin $display("DW output did not clear"); errors = errors + 1; end
        end
    endtask

    task run_stem;
        input integer cid, count; input [15:0] mask;
        begin
            outputs_seen = 0;
            for (lane = 0; lane < 16; lane = lane + 1) expected[lane] = 0;
            for (k = 0; k < count; k = k + 1) begin
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (mask[lane]) expected[lane] = expected[lane] +
                        ((cid == 3) ? extreme(k, 0) : sval(cid, k, 0)) *
                        ((cid == 3) ? extreme(k, lane) : sval(cid, k, lane));
                feed_stem(cid, k, count, mask);
            end
            check_stem(mask, count - 1);
            if (outputs_seen != 1) errors = errors + 1;
        end
    endtask

    task run_dw;
        input integer cid, count; input [15:0] mask;
        begin
            outputs_seen = 0;
            for (lane = 0; lane < 16; lane = lane + 1) expected[lane] = 0;
            for (k = 0; k < count; k = k + 1) begin
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (mask[lane]) expected[lane] = expected[lane] +
                        ((cid == 3) ? extreme(k, lane) : dval(cid, k, lane)) *
                        ((cid == 3) ? extreme(k, lane + 1) : dval(cid, k, lane + 1));
                feed_dw(cid, k, count, mask);
            end
            check_dw(mask, count - 1);
            if (outputs_seen != 1) errors = errors + 1;
        end
    endtask

    task run_mid_change;
        integer cid;
        reg [15:0] smask;
        reg [15:0] dmask;
        begin
            cid = 2; smask = 16'h00ff; dmask = 16'h8001; outputs_seen = 0;
            for (lane = 0; lane < 16; lane = lane + 1) expected[lane] = 0;
            for (k = 0; k < 3; k = k + 1)
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (smask[lane]) expected[lane] = expected[lane] +
                        sval(cid, k, 0) * sval(cid, k, lane);
            feed_stem(cid, 0, 3, smask);
            /* While Stem token 1 is active, present a complete one-token DW
             * operation.  The selector must flag it and keep it buffered for
             * the subsequent idle handoff. */
            @(negedge clk);
            stem_act = sval(cid, 1, 0); stem_weight = 128'sd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                stem_weight[(lane*8) +: 8] = sval(cid, 1, lane);
            stem_idx = 1; stem_first = 0; stem_last = 0; stem_mask = smask;
            dw_act = 128'sd0; dw_weight = 128'sd0;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                dw_act[(lane*8) +: 8] = dval(cid, 0, lane);
                dw_weight[(lane*8) +: 8] = dval(cid, 0, lane + 1);
            end
            dw_idx = 0; dw_first = 1; dw_last = 1; dw_mask = dmask;
            stem_valid = 1; dw_valid = 1;
            while (!stem_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); stem_valid = 0;
            /* Keep the unselected DW source asserted through the next active
             * cycle so the simulation assertion observes the attempted mode. */
            @(posedge clk); @(negedge clk); dw_valid = 0;
            feed_stem(cid, 2, 3, smask);
            check_stem(smask, 2);
            for (lane = 0; lane < 16; lane = lane + 1)
                expected[lane] = dmask[lane] ? dval(cid, 0, lane) *
                    dval(cid, 0, lane + 1) : 0;
            check_dw(dmask, 0);
            if (outputs_seen != 2) errors = errors + 1;
        end
    endtask

    initial begin
        repeat (10000) @(posedge clk); $display("FAIL watchdog"); $fatal;
    end
    initial begin
        clk = 0; rst_n = 0; stem_valid = 0; stem_first = 0; stem_last = 0;
        stem_idx = 0; stem_mask = 0; stem_act = 0; stem_weight = 0; stem_ready_out = 1;
        dw_valid = 0; dw_first = 0; dw_last = 0; dw_idx = 0; dw_mask = 0;
        dw_act = 0; dw_weight = 0; dw_ready_out = 1; errors = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        run_stem(0, 9, 16'hffff);
        run_dw(1, 7, 16'h0f3f);
        run_mid_change();
        run_stem(3, 3, 16'h00ff);
        if (dut.mode_change_errors == 0) errors = errors + 1;
        if (errors == 0) $display("PASS tb_mac16_stream_adapters shared_core cases=5 checks=240");
        else begin $display("FAIL tb_mac16_stream_adapters errors=%0d", errors); $fatal; end
        $finish;
    end
endmodule

`default_nettype wire
