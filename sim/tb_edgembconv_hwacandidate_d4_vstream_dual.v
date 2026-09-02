`timescale 1ns/1ps
`default_nettype none

/* Shared-DSP dual-mode contract: PW16 and RQ4 use the same accepted-token
 * stream and are checked with independent real D4 vector memories. */
module tb_edgembconv_hwacandidate_d4_vstream_dual;
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
    wire signed [255:0] rq_product_vec;
    wire signed [31:0] rq_result_vec;
    wire [31:0] metadata_out;

    reg [127:0] pw_act_mem [0:PW_N-1];
    reg [127:0] pw_wgt_mem [0:PW_N-1];
    reg [255:0] pw_expected_mem [0:PW_N-1];
    reg [127:0] rq_acc_mem [0:RQ_N-1];
    reg [127:0] rq_mul_mem [0:RQ_N-1];
    reg [23:0] rq_shift_mem [0:RQ_N-1];
    reg [127:0] rq_zp_mem [0:RQ_N-1];
    reg [127:0] rq_min_mem [0:RQ_N-1];
    reg [127:0] rq_max_mem [0:RQ_N-1];
    reg [255:0] rq_product_mem [0:RQ_N-1];
    reg [31:0] rq_result_mem [0:RQ_N-1];

    reg [0:0] exp_mode [0:127];
    integer exp_index [0:127];
    integer q_head, q_tail, source_index, errors, cycle_count;
    reg [31:0] prng;
    reg snap_in_valid, snap_in_ready, snap_in_mode;
    reg snap_out_valid, snap_out_ready, snap_out_mode;
    reg [31:0] snap_metadata;
    reg [255:0] snap_pw_product, snap_rq_product;
    reg [31:0] snap_rq_result;
    integer snap_source_index;

    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool dut (
        .clk(clk), .rst_n(rst_n), .mode_rq(mode_rq), .valid_in(valid_in),
        .ready_in(ready_in), .pw_act_vec(pw_act_vec), .pw_wgt_vec(pw_wgt_vec),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .metadata_in(metadata_in), .valid_out(valid_out), .ready_out(ready_out),
        .mode_rq_out(mode_rq_out), .pw_product_vec(pw_product_vec),
        .rq_product_vec(rq_product_vec), .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle_count = cycle_count + 1;

    task clear_input;
        begin
            valid_in = 1'b0; mode_rq = 1'b1; metadata_in = 32'd0;
            pw_act_vec = 128'd0; pw_wgt_vec = 128'd0;
            rq_acc_vec = 128'sd0; rq_multiplier_vec = 128'sd0;
            rq_shift_vec = 24'd0; rq_zero_point_vec = 128'sd0;
            rq_min_vec = 128'sd0; rq_max_vec = 128'sd0;
        end
    endtask

    task drive_pw;
        input integer n;
        begin
            mode_rq = 1'b0; valid_in = 1'b1;
            pw_act_vec = pw_act_mem[n % PW_N];
            pw_wgt_vec = pw_wgt_mem[n % PW_N];
            metadata_in = 32'ha0000000 + n;
        end
    endtask

    task drive_rq;
        input integer n;
        begin
            mode_rq = 1'b1; valid_in = 1'b1;
            rq_acc_vec = rq_acc_mem[n % RQ_N];
            rq_multiplier_vec = rq_mul_mem[n % RQ_N];
            rq_shift_vec = rq_shift_mem[n % RQ_N];
            rq_zero_point_vec = rq_zp_mem[n % RQ_N];
            rq_min_vec = rq_min_mem[n % RQ_N];
            rq_max_vec = rq_max_mem[n % RQ_N];
            metadata_in = 32'hb0000000 + n;
        end
    endtask

    task random_ready;
        begin
            prng = prng ^ (prng << 13);
            prng = prng ^ (prng >> 17);
            prng = prng ^ (prng << 5);
            ready_out = prng[0];
            #1;
        end
    endtask

    task check_output;
        integer n;
        begin
            if (snap_out_valid && snap_out_ready) begin
                if (q_head >= q_tail) begin
                    $display("DUAL_UNEXPECTED_OUTPUT cycle=%0d", cycle_count);
                    errors = errors + 1;
                end else begin
                    n = exp_index[q_head];
                    if (snap_out_mode !== exp_mode[q_head]) begin
                        $display("DUAL_MODE_ORDER_ERROR cycle=%0d", cycle_count);
                        errors = errors + 1;
                    end
                    if (exp_mode[q_head] == 1'b0) begin
                        if (snap_metadata !== (32'ha0000000 + n) ||
                            snap_pw_product !== pw_expected_mem[n % PW_N]) begin
                            $display("DUAL_PW_MISMATCH n=%0d cycle=%0d", n, cycle_count);
                            errors = errors + 1;
                        end
                    end else if (snap_metadata !== (32'hb0000000 + n) ||
                                 snap_rq_product !== rq_product_mem[n % RQ_N] ||
                                 snap_rq_result !== rq_result_mem[n % RQ_N]) begin
                        $display("DUAL_RQ_MISMATCH n=%0d cycle=%0d", n, cycle_count);
                        errors = errors + 1;
                    end
                    q_head = q_head + 1;
                end
            end
        end
    endtask

    /* One falling-edge snapshot represents the following rising-edge
     * handshake.  The one-time #1 settle also prevents a ready_out transition
     * from being sampled before ready_in's combinational fence updates. */
    task tick;
        begin
            #1;
            snap_in_valid = valid_in; snap_in_ready = ready_in;
            snap_in_mode = mode_rq; snap_source_index = source_index;
            snap_out_valid = valid_out; snap_out_ready = ready_out;
            snap_out_mode = mode_rq_out; snap_metadata = metadata_out;
            snap_pw_product = pw_product_vec; snap_rq_product = rq_product_vec;
            snap_rq_result = rq_result_vec;
            @(posedge clk);
            @(negedge clk);
            check_output();
            if (snap_in_valid && snap_in_ready) begin
                exp_mode[q_tail] = snap_in_mode;
                exp_index[q_tail] = snap_source_index;
                q_tail = q_tail + 1;
            end
        end
    endtask

    task run_phase;
        input integer phase_mode;
        input integer total;
        input integer randomized;
        integer guard, first_accept, last_accept;
        begin
            source_index = 0; first_accept = -1; last_accept = -1;
            clear_input();
            @(negedge clk);
            if (phase_mode == 0) drive_pw(0); else drive_rq(0);
            guard = 0;
            while (guard < 10000 && (source_index < total || q_head < q_tail || valid_out)) begin
                if (source_index < total) begin
                    if (phase_mode == 0) drive_pw(source_index);
                    else drive_rq(source_index);
                end else clear_input();
                if (randomized != 0) random_ready(); else begin ready_out = 1'b1; #1; end
                tick();
                if (snap_in_valid && snap_in_ready) begin
                    if (first_accept < 0) first_accept = cycle_count;
                    last_accept = cycle_count;
                    source_index = source_index + 1;
                end
                guard = guard + 1;
            end
            if (guard >= 10000) begin
                $display("DUAL_TIMEOUT mode=%0d source=%0d queue=%0d", phase_mode, source_index, q_tail-q_head);
                errors = errors + 1;
            end
            ready_out = 1'b1; clear_input(); #1;
            if (randomized == 0 && last_accept-first_accept+1 != total) begin
                $display("DUAL_II_ERROR mode=%0d", phase_mode);
                errors = errors + 1;
            end
            /* Give mode_active its documented empty-cycle fence. */
            tick();
        end
    endtask

    /* Hold a new mode against an occupied output, prove it cannot be
     * accepted, then release the output and prove ordered PW->RQ or RQ->PW. */
    task run_pending_switch;
        input integer old_mode;
        integer guard, blocked, tx_count;
        begin
            source_index = 0; tx_count = 0; clear_input(); ready_out = 1'b0; #1;
            if (old_mode == 0) drive_pw(0); else drive_rq(0);
            tick();
            if (!(snap_in_valid && snap_in_ready)) begin
                $display("DUAL_SEED_NOT_ACCEPTED mode=%0d", old_mode);
                errors = errors + 1;
            end else tx_count = 1;
            if (old_mode == 0) drive_rq(0); else drive_pw(0);
            blocked = 0;
            for (guard = 0; guard < 5; guard = guard + 1) begin
                ready_out = 1'b0; #1; tick();
                if (snap_in_ready) blocked = 1;
            end
            if (blocked != 0) begin
                $display("DUAL_MODE_SWITCH_EARLY_ACCEPT old_mode=%0d", old_mode);
                errors = errors + 1;
            end
            ready_out = 1'b1; #1;
            guard = 0;
            while (guard < 1000 && (tx_count < 2 || q_head < q_tail || valid_out)) begin
                if (tx_count < 2) begin
                    if (old_mode == 0) drive_rq(0); else drive_pw(0);
                end else clear_input();
                tick();
                if (snap_in_valid && snap_in_ready) tx_count = tx_count + 1;
                guard = guard + 1;
            end
            if (guard >= 1000) begin
                $display("DUAL_SWITCH_TIMEOUT old_mode=%0d", old_mode);
                errors = errors + 1;
            end
            ready_out = 1'b1; clear_input(); #1; tick();
        end
    endtask

    initial begin
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_act.mem", pw_act_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_wgt.mem", pw_wgt_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_pw_expected.mem", pw_expected_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_acc.mem", rq_acc_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_multiplier.mem", rq_mul_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_shift.mem", rq_shift_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_zero_point.mem", rq_zp_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_minimum.mem", rq_min_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_maximum.mem", rq_max_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_product.mem", rq_product_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_expected.mem", rq_result_mem);
        clk = 0; rst_n = 0; errors = 0; cycle_count = 0;
        q_head = 0; q_tail = 0; prng = 32'hd4c0ffee;
        clear_input(); ready_out = 1'b1;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        run_phase(0, 16, 0);
        run_phase(1, 32, 1);
        run_phase(0, 32, 1);
        run_pending_switch(0);
        run_pending_switch(1);
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_vstream_dual dsp_count=16 pw_ii=1 rq_ii=1 mode_fence=random_backpressure=checked");
        else begin
            $display("FAIL edgembconv_hwacandidate_d4_vstream_dual errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
