`timescale 1ns/1ps
`default_nettype none

/* Exact, independent protocol scoreboard for the single 16-DSP D4 pool. */
module tb_edgembconv_hwacandidate_d4_dsp_pool;
    localparam integer PW_N = 3;
    localparam integer RQ_N = 5;
    reg clk, rst_n, mode_rq, valid_in, ready_out;
    reg [127:0] pw_act_vec, pw_wgt_vec;
    reg signed [127:0] rq_acc_vec, rq_multiplier_vec;
    reg [23:0] rq_shift_vec;
    reg signed [127:0] rq_zero_point_vec, rq_min_vec, rq_max_vec;
    reg [31:0] metadata_in;
    wire ready_in, valid_out, mode_rq_out;
    wire [255:0] pw_product_vec;
    wire signed [31:0] rq_product0, rq_product1, rq_product2, rq_product3;
    wire signed [255:0] rq_product_vec;
    wire signed [31:0] rq_result_vec;
    wire [31:0] metadata_out;

    reg [127:0] pw_act_mem [0:PW_N-1];
    reg [127:0] pw_wgt_mem [0:PW_N-1];
    reg [255:0] pw_expected_mem [0:PW_N-1];
    reg [31:0] pw_metadata_mem [0:PW_N-1];
    reg [127:0] rq_acc_mem [0:RQ_N-1];
    reg [127:0] rq_multiplier_mem [0:RQ_N-1];
    reg [23:0] rq_shift_mem [0:RQ_N-1];
    reg [127:0] rq_zp_mem [0:RQ_N-1];
    reg [127:0] rq_min_mem [0:RQ_N-1];
    reg [127:0] rq_max_mem [0:RQ_N-1];
    reg [255:0] rq_product_mem [0:RQ_N-1];
    reg [31:0] rq_expected_mem [0:RQ_N-1];

    integer errors, accepted_pw, accepted_rq, i, hold;
    integer pw_hold_cycles, rq_hold_cycles;
    integer cycle_counter, accepted_cycle, visible_cycle;
    reg [31:0] stall_prng;
    reg [255:0] held_pw;
    reg [255:0] held_rq_product;
    reg [31:0] held_rq_result;
    reg [31:0] held_metadata;

    edgembconv_hwacandidate_d4_dsp_pool dut (
        .clk(clk), .rst_n(rst_n), .mode_rq(mode_rq), .valid_in(valid_in),
        .ready_in(ready_in), .pw_act_vec(pw_act_vec), .pw_wgt_vec(pw_wgt_vec),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .metadata_in(metadata_in), .ready_out(ready_out),
        .valid_out(valid_out), .mode_rq_out(mode_rq_out),
        .pw_product_vec(pw_product_vec), .rq_product0(rq_product0),
        .rq_product1(rq_product1), .rq_product2(rq_product2),
        .rq_product3(rq_product3), .rq_product_vec(rq_product_vec),
        .rq_result_vec(rq_result_vec), .metadata_out(metadata_out)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle_counter = cycle_counter + 1;

    task clear_input;
        begin
            valid_in = 1'b0; mode_rq = 1'b0;
            pw_act_vec = 128'd0; pw_wgt_vec = 128'd0;
            rq_acc_vec = 128'sd0; rq_multiplier_vec = 128'sd0;
            rq_shift_vec = 24'd0; rq_zero_point_vec = 128'sd0;
            rq_min_vec = 128'sd0; rq_max_vec = 128'sd0;
            metadata_in = 32'd0;
        end
    endtask

    /* Deterministic pseudo-random ready pattern so every regression exercises
     * a reproducible but non-periodic backpressure choice. */
    task next_stall;
        output integer result;
        begin
            stall_prng = stall_prng ^ (stall_prng << 13);
            stall_prng = stall_prng ^ (stall_prng >> 17);
            stall_prng = stall_prng ^ (stall_prng << 5);
            result = stall_prng[0] ? 1 : 0;
        end
    endtask

    task send_pw;
        input integer n;
        input integer stall_output;
        begin
            @(negedge clk);
            mode_rq = 1'b0; valid_in = 1'b1;
            pw_act_vec = pw_act_mem[n]; pw_wgt_vec = pw_wgt_mem[n];
            metadata_in = pw_metadata_mem[n];
            while (!ready_in) @(negedge clk);
            @(posedge clk); #1; accepted_pw = accepted_pw + 1;
            accepted_cycle = cycle_counter;
            clear_input();
            /* The physical pool now has a registered DSP output capture
             * boundary.  Wait on ready/valid rather than assuming the old
             * one-clock observable latency. */
            ready_out = (stall_output == 0);
            while (!valid_out) @(negedge clk);
            visible_cycle = cycle_counter;
            if (stall_output != 0) begin
                held_pw = pw_product_vec;
                held_metadata = metadata_out;
                pw_hold_cycles = 1 + ((n * 3 + 1) % 4);
                repeat (pw_hold_cycles) begin
                    @(posedge clk); #1;
                    if (!valid_out || mode_rq_out || metadata_out !== held_metadata ||
                        pw_product_vec !== held_pw)
                        errors = errors + 1;
                end
                @(negedge clk);
                ready_out = 1'b1;
            end
            if (!valid_out || mode_rq_out || metadata_out !== pw_metadata_mem[n] ||
                pw_product_vec !== pw_expected_mem[n]) begin
                $display("D4_DSP_POOL_PW_MISMATCH n=%0d valid=%b mode=%b meta=%h/%h got=%h exp=%h",
                         n, valid_out, mode_rq_out, metadata_out, pw_metadata_mem[n],
                         pw_product_vec, pw_expected_mem[n]);
                errors = errors + 1;
            end
            $display("D4_DSP_POOL_PW n=%0d latency_cycles=%0d output_stall=%0d",
                     n, visible_cycle - accepted_cycle, stall_output);
            @(posedge clk);
        end
    endtask

    task send_rq;
        input integer n;
        input integer stall_output;
        begin
            @(negedge clk);
            mode_rq = 1'b1; valid_in = 1'b1;
            rq_acc_vec = rq_acc_mem[n]; rq_multiplier_vec = rq_multiplier_mem[n];
            rq_shift_vec = rq_shift_mem[n]; rq_zero_point_vec = rq_zp_mem[n];
            rq_min_vec = rq_min_mem[n]; rq_max_vec = rq_max_mem[n];
            metadata_in = 32'hd4001000 + n;
            while (!ready_in) @(negedge clk);
            @(posedge clk); #1; accepted_rq = accepted_rq + 1;
            accepted_cycle = cycle_counter;
            clear_input();
            /* Hold the result while the multi-cycle RQ pipeline drains; it
             * would otherwise be consumed on the first clock after valid. */
            ready_out = 1'b0;
            if (stall_output != 0) begin
                while (!valid_out) @(negedge clk);
                visible_cycle = cycle_counter;
                #1;
                held_rq_product = rq_product_vec;
                held_rq_result = rq_result_vec;
                held_metadata = metadata_out;
                rq_hold_cycles = 1 + ((n * 5 + 2) % 4);
                for (hold = 0; hold < rq_hold_cycles; hold = hold + 1) begin
                    @(posedge clk); #1;
                    if (ready_in || !valid_out || rq_product_vec !== held_rq_product ||
                        rq_result_vec !== held_rq_result || metadata_out !== held_metadata)
                        errors = errors + 1;
                end
                @(negedge clk);
                ready_out = 1'b1;
            end
            if (stall_output == 0) begin
                while (!valid_out) @(negedge clk);
                visible_cycle = cycle_counter;
            end
            if (!valid_out || !mode_rq_out || metadata_out !== (32'hd4001000 + n) ||
                rq_product_vec !== rq_product_mem[n] ||
                rq_result_vec !== rq_expected_mem[n]) begin
                $display("D4_DSP_POOL_RQ_MISMATCH n=%0d valid=%b mode=%b meta=%h/%h product=%h/%h result=%h/%h",
                         n, valid_out, mode_rq_out, metadata_out, (32'hd4001000 + n),
                         rq_product_vec, rq_product_mem[n], rq_result_vec, rq_expected_mem[n]);
                errors = errors + 1;
            end
            $display("D4_DSP_POOL_RQ n=%0d latency_cycles=%0d output_stall=%0d",
                     n, visible_cycle - accepted_cycle, stall_output);
            ready_out = 1'b1;
            @(posedge clk);
        end
    endtask

    initial begin
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_act.mem", pw_act_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_wgt.mem", pw_wgt_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_expected.mem", pw_expected_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_metadata.mem", pw_metadata_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_acc.mem", rq_acc_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_multiplier.mem", rq_multiplier_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_shift.mem", rq_shift_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_zero_point.mem", rq_zp_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_minimum.mem", rq_min_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_maximum.mem", rq_max_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_product.mem", rq_product_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_expected.mem", rq_expected_mem);
        clk = 1'b0; rst_n = 1'b0; ready_out = 1'b1; errors = 0;
        cycle_counter = 0;
        stall_prng = 32'hd4c0ffee;
        accepted_pw = 0; accepted_rq = 0; clear_input();
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        /* Consecutive PW transactions exercise all sixteen DSPs as products.
         * The final PW transaction is followed immediately by an RQ request,
         * proving mode changes only at the accepted-result boundary. */
        next_stall(i); send_pw(0, i);
        next_stall(i); send_pw(1, i);
        next_stall(i); send_rq(0, i);
        next_stall(i); send_pw(2, i);
        next_stall(i); send_rq(1, i);
        next_stall(i); send_rq(2, i);
        next_stall(i); send_rq(3, i);
        next_stall(i); send_rq(4, i);

        if (accepted_pw != PW_N || accepted_rq != RQ_N)
            errors = errors + 1;
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_dsp_pool physical_dsp_contract=16 pw_records=%0d rq_records=%0d random_backpressure=checked", accepted_pw, accepted_rq);
        else begin
            $display("FAIL edgembconv_hwacandidate_d4_dsp_pool errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
