`timescale 1ns/1ps
`default_nettype none

module tb_pw_direct_8x8_dsp;
    reg clk, rst_n, valid_in, first_k, last_k, ready_out;
    reg [7:0] k_idx, pixel_mask, cout_mask;
    reg signed [63:0] act_vec, wgt_vec;
    wire ready_in, valid_out;
    wire signed [2047:0] psum_out;
    wire [63:0] lane_mask_out;

    integer errors;
    integer p_total, cout_total, p_base, c_base, p_lanes, c_lanes;
    integer cin, k, i, j, lane, block_idx;
    integer expected [0:63];
    integer actual;
    reg [63:0] expected_mask;
    reg signed [31:0] held_psum [0:63];
    reg [63:0] held_mask;

    pw_direct_8x8_dsp dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .pixel_mask(pixel_mask), .cout_mask(cout_mask),
        .act_vec(act_vec), .wgt_vec(wgt_vec), .ready_out(ready_out),
        .valid_out(valid_out), .psum_out(psum_out),
        .lane_mask_out(lane_mask_out)
    );

    always #5 clk <= ~clk;

    function integer act_value;
        input integer kk;
        input integer pp;
        input integer bb;
        begin
            act_value = ((kk * 13 + pp * 7 + bb * 3 + 19) % 61) - 30;
        end
    endfunction

    function integer wgt_value;
        input integer kk;
        input integer cc;
        input integer bb;
        begin
            wgt_value = ((kk * 17 + cc * 5 + bb * 11 + 23) % 47) - 23;
        end
    endfunction

    task feed_token;
        input integer kk;
        begin
            @(negedge clk);
            act_vec = 64'sd0;
            wgt_vec = 64'sd0;
            for (i = 0; i < 8; i = i + 1)
                act_vec[(i*8) +: 8] = act_value(kk, p_base + i, block_idx);
            for (j = 0; j < 8; j = j + 1)
                wgt_vec[(j*8) +: 8] = wgt_value(kk, c_base + j, block_idx);
            first_k = (kk == 0);
            last_k = (kk == (cin - 1));
            k_idx = kk;
            pixel_mask = (p_lanes == 8) ? 8'hff : ((1 << p_lanes) - 1);
            cout_mask = (c_lanes == 8) ? 8'hff : ((1 << c_lanes) - 1);
            valid_in = 1'b1;
            while (!ready_in)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            valid_in = 1'b0;
            first_k = 1'b0;
            last_k = 1'b0;
            k_idx = 8'd0;
            pixel_mask = 8'd0;
            cout_mask = 8'd0;
            /* Exercise source bubbles without changing the accepted token
             * sequence. */
            if ((kk % 5) == 3)
                repeat (2) @(posedge clk);
        end
    endtask

    task run_block;
        begin
            expected_mask = 64'd0;
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    expected[i*8+j] = 0;
                    expected_mask[i*8+j] = (i < p_lanes) && (j < c_lanes);
                end

            for (k = 0; k < cin; k = k + 1) begin
                for (i = 0; i < 8; i = i + 1)
                    for (j = 0; j < 8; j = j + 1)
                        if ((i < p_lanes) && (j < c_lanes))
                            expected[i*8+j] = expected[i*8+j] +
                                act_value(k, p_base+i, block_idx) *
                                wgt_value(k, c_base+j, block_idx);
                feed_token(k);
                if ((k < (cin - 1)) && valid_out)
                    errors = errors + 1;
            end

            while (!valid_out)
                @(posedge clk);
            ready_out = 1'b0;
            held_mask = lane_mask_out;
            for (lane = 0; lane < 64; lane = lane + 1)
                held_psum[lane] = $signed(psum_out[(lane*32) +: 32]);
            repeat (3) begin
                @(posedge clk);
                if (!valid_out || lane_mask_out !== held_mask)
                    errors = errors + 1;
                for (lane = 0; lane < 64; lane = lane + 1)
                    if ($signed(psum_out[(lane*32) +: 32]) !== held_psum[lane])
                        errors = errors + 1;
            end
            for (lane = 0; lane < 64; lane = lane + 1) begin
                actual = $signed(psum_out[(lane*32) +: 32]);
                if (actual !== expected[lane] ||
                    lane_mask_out[lane] !== expected_mask[lane]) begin
                    $display("MISMATCH P=%0d Cout=%0d block=%0d lane=%0d exp=%0d got=%0d mask=%b/%b",
                             p_total, cout_total, block_idx, lane,
                             expected[lane], actual,
                             expected_mask[lane], lane_mask_out[lane]);
                    errors = errors + 1;
                end
            end
            ready_out = 1'b1;
            @(posedge clk);
            if (valid_out)
                errors = errors + 1;
            if (dut.sim_protocol_errors != 0)
                errors = errors + dut.sim_protocol_errors;
        end
    endtask

    task run_case;
        input integer pcount;
        input integer ccount;
        input integer cin_arg;
        begin
            p_total = pcount;
            cout_total = ccount;
            cin = cin_arg;
            for (p_base = 0; p_base < p_total; p_base = p_base + 8) begin
                p_lanes = p_total - p_base;
                if (p_lanes > 8) p_lanes = 8;
                for (c_base = 0; c_base < cout_total; c_base = c_base + 8) begin
                    c_lanes = cout_total - c_base;
                    if (c_lanes > 8) c_lanes = 8;
                    block_idx = (p_base / 8) * 8 + (c_base / 8);
                    run_block();
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        first_k = 1'b0;
        last_k = 1'b0;
        k_idx = 8'd0;
        pixel_mask = 8'd0;
        cout_mask = 8'd0;
        act_vec = 64'sd0;
        wgt_vec = 64'sd0;
        ready_out = 1'b1;
        errors = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        run_case(1, 8, 32);
        run_case(8, 16, 48);
        run_case(17, 13, 32);

        if (errors == 0)
            $display("PASS tb_pw_direct_8x8_dsp cases=3 blocks=11 checks=704");
        else begin
            $display("FAIL tb_pw_direct_8x8_dsp errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
