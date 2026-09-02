`timescale 1ns/1ps
`default_nettype none

/* Functional/throughput gate for the D4 elastic RQ stream.  The source
 * records are the real D4 RQ export used by the existing pool contract.  Each
 * of the five records is reused only to make a 16-beat contiguous stream;
 * every expected value and context remains independently scoreboarded. */
module tb_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool;
    localparam integer REAL_N = 5;
    localparam integer BURST_N = 16;
    localparam integer STALL_N = 32;
    reg clk, rst_n, valid_in, ready_out;
    reg signed [127:0] rq_acc_vec, rq_multiplier_vec;
    reg [23:0] rq_shift_vec;
    reg signed [127:0] rq_zero_point_vec, rq_min_vec, rq_max_vec;
    reg [31:0] metadata_in;
    wire ready_in, valid_out;
    wire signed [255:0] rq_product_vec;
    wire signed [31:0] rq_result_vec;
    wire [31:0] metadata_out;

    reg [127:0] acc_mem [0:REAL_N-1];
    reg [127:0] mul_mem [0:REAL_N-1];
    reg [23:0] shift_mem [0:REAL_N-1];
    reg [127:0] zp_mem [0:REAL_N-1];
    reg [127:0] min_mem [0:REAL_N-1];
    reg [127:0] max_mem [0:REAL_N-1];
    reg [255:0] product_mem [0:REAL_N-1];
    reg [31:0] result_mem [0:REAL_N-1];

    integer errors, cycle_count, accepted_count, produced_count;
    integer q_head, q_tail, source_index;
    reg hold_valid;
    integer expected_index [0:127];
    reg [31:0] prng;
    reg signed [255:0] held_product;
    reg signed [31:0] held_result;
    reg [31:0] held_metadata;
    reg snap_in_valid, snap_in_ready, snap_out_valid, snap_out_ready;
    reg signed [255:0] snap_product;
    reg signed [31:0] snap_result;
    reg [31:0] snap_metadata;
    integer snap_source_index;

    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .metadata_in(metadata_in), .valid_out(valid_out), .ready_out(ready_out),
        .rq_product_vec(rq_product_vec), .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle_count = cycle_count + 1;
    task clear_input;
        begin
            valid_in = 1'b0; rq_acc_vec = 128'sd0; rq_multiplier_vec = 128'sd0;
            rq_shift_vec = 24'd0; rq_zero_point_vec = 128'sd0;
            rq_min_vec = 128'sd0; rq_max_vec = 128'sd0; metadata_in = 32'd0;
        end
    endtask

    /* One-at-a-time randomized gate.  Holding valid_in until the saved
     * ready_in handshake creates genuine input backpressure, while the
     * independent ready_out sequence exercises the elastic output chain.
     * Handshake data is always sampled at the falling edge preceding its
     * rising-edge transfer. */
    task run_random_single;
        input integer n;
        integer guard;
        reg in_done;
        reg out_done;
        reg ov;
        reg ordy;
        reg signed [255:0] op;
        reg signed [31:0] orr;
        reg [31:0] om;
        begin
            @(negedge clk);
            valid_in = 1'b1;
            drive_record(n);
            random_ready();
            in_done = 0;
            guard = 0;
            while (!in_done && guard < 1000) begin
                snap_in_valid = valid_in;
                snap_in_ready = ready_in;
                @(posedge clk);
                if (snap_in_valid && snap_in_ready) begin
                    accepted_count = accepted_count + 1;
                    in_done = 1;
                end
                @(negedge clk);
                if (in_done)
                    valid_in = 1'b0;
                random_ready();
                guard = guard + 1;
            end
            if (!in_done) begin
                $display("VSTREAM_INPUT_TIMEOUT n=%0d", n);
                errors = errors + 1;
            end

            out_done = 0;
            hold_valid = 0;
            guard = 0;
            while (!out_done && guard < 2000) begin
                random_ready();
                ov = valid_out;
                ordy = ready_out;
                op = rq_product_vec;
                orr = rq_result_vec;
                om = metadata_out;
                @(posedge clk);
                if (ov && ordy) begin
                    if (op !== product_mem[n % REAL_N] ||
                        orr !== result_mem[n % REAL_N] ||
                        om !== (32'hd4001000 + n)) begin
                        $display("VSTREAM_MISMATCH n=%0d cycle=%0d meta=%h/%h product=%h/%h result=%h/%h",
                                 n, cycle_count, om, 32'hd4001000+n,
                                 op, product_mem[n % REAL_N], orr,
                                 result_mem[n % REAL_N]);
                        errors = errors + 1;
                    end
                    produced_count = produced_count + 1;
                    out_done = 1;
                end else if (ov && !ordy) begin
                    if (!hold_valid) begin
                        held_product = op;
                        held_result = orr;
                        held_metadata = om;
                        hold_valid = 1;
                    end else if (op !== held_product || orr !== held_result ||
                                 om !== held_metadata) begin
                        $display("VSTREAM_OUTPUT_MOVED_WHILE_STALLED n=%0d cycle=%0d", n, cycle_count);
                        errors = errors + 1;
                    end
                end else begin
                    hold_valid = 0;
                end
                @(negedge clk);
                guard = guard + 1;
            end
            if (!out_done) begin
                $display("VSTREAM_OUTPUT_TIMEOUT n=%0d", n);
                errors = errors + 1;
            end
            ready_out = 1'b1;
        end
    endtask

    task drive_record;
        input integer n;
        begin
            rq_acc_vec = acc_mem[n % REAL_N];
            rq_multiplier_vec = mul_mem[n % REAL_N];
            rq_shift_vec = shift_mem[n % REAL_N];
            rq_zero_point_vec = zp_mem[n % REAL_N];
            rq_min_vec = min_mem[n % REAL_N];
            rq_max_vec = max_mem[n % REAL_N];
            metadata_in = 32'hd4001000 + n;
        end
    endtask

    task random_ready;
        begin
            prng = prng ^ (prng << 13);
            prng = prng ^ (prng >> 17);
            prng = prng ^ (prng << 5);
            ready_out = prng[0];
            /* Allow ready_in's combinational dependency on ready_out to
             * settle before taking the falling-edge handshake snapshot. */
            #1;
        end
    endtask

    task check_snapshot;
        integer n;
        begin
            if (snap_out_valid && snap_out_ready) begin
                if (q_head >= q_tail) begin
                    $display("VSTREAM_UNEXPECTED_OUTPUT cycle=%0d", cycle_count);
                    errors = errors + 1;
                end else begin
                    n = expected_index[q_head];
                    q_head = q_head + 1;
                    if (snap_product !== product_mem[n % REAL_N] ||
                        snap_result !== result_mem[n % REAL_N] ||
                        snap_metadata !== (32'hd4001000 + n)) begin
                        $display("VSTREAM_MISMATCH n=%0d cycle=%0d meta=%h/%h product=%h/%h result=%h/%h",
                                 n, cycle_count, snap_metadata, 32'hd4001000+n,
                                 snap_product, product_mem[n % REAL_N],
                                 snap_result, result_mem[n % REAL_N]);
                        errors = errors + 1;
                    end
                    produced_count = produced_count + 1;
                end
            end
            if (snap_out_valid && !snap_out_ready) begin
                if (!hold_valid) begin
                    held_product = snap_product;
                    held_result = snap_result;
                    held_metadata = snap_metadata;
                    hold_valid = 1;
                end else if (snap_product !== held_product ||
                             snap_result !== held_result ||
                             snap_metadata !== held_metadata) begin
                    $display("VSTREAM_OUTPUT_MOVED_WHILE_STALLED cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
            end else begin
                hold_valid = 0;
            end
        end
    endtask

    task run_phase;
        input integer total;
        input integer randomized;
        integer guard, accepted_start, first_accept, last_accept;
        begin
            accepted_start = accepted_count;
            source_index = 0;
            clear_input();
            if (randomized == 0) ready_out = 1'b1;
            @(negedge clk);
            valid_in = 1'b1;
            drive_record(source_index);
            if (randomized != 0) random_ready();
            guard = 0; first_accept = -1; last_accept = -1;
            while (guard < 10000 && (source_index < total || q_head < q_tail || valid_out)) begin
                /* Snapshot signals at the falling edge.  The snapshot is the
                 * handshake/data presented to the following rising edge;
                 * sampling after that edge would see a simultaneously
                 * replaced elastic output. */
                snap_in_valid = valid_in;
                snap_in_ready = ready_in;
                snap_out_valid = valid_out;
                snap_out_ready = ready_out;
                snap_product = rq_product_vec;
                snap_result = rq_result_vec;
                snap_metadata = metadata_out;
                snap_source_index = source_index;
                @(posedge clk);
                @(negedge clk);
                check_snapshot();
                if (snap_in_valid && snap_in_ready) begin
                    if (first_accept < 0) first_accept = cycle_count;
                    last_accept = cycle_count;
                    expected_index[q_tail] = snap_source_index;
                    q_tail = q_tail + 1;
                    accepted_count = accepted_count + 1;
                    source_index = source_index + 1;
                    if (source_index < total) drive_record(source_index);
                    else clear_input();
                end
                if (randomized != 0) random_ready();
                guard = guard + 1;
            end
            if (guard >= 10000) begin
                $display("VSTREAM_TIMEOUT phase=%0d source=%0d accepted=%0d produced=%0d queue=%0d",
                         randomized, source_index, accepted_count, produced_count, q_tail-q_head);
                errors = errors + 1;
            end
            if (randomized == 0) begin
                $display("VSTREAM_BURST accepted=%0d first_cycle=%0d last_cycle=%0d",
                         accepted_count-accepted_start, first_accept, last_accept);
                if (last_accept-first_accept+1 != total)
                    errors = errors + 1;
            end
            ready_out = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    /* Continuous stream under independent output stalls.  The saved
     * falling-edge snapshot is the sole source of both handshake events, so
     * source records are advanced exactly once and never changed during a
     * rising-edge transfer. */
    task run_random_stream;
        input integer total;
        integer guard;
        reg have_snapshot;
        begin
            source_index = 0;
            clear_input();
            @(negedge clk);
            valid_in = 1'b1;
            drive_record(source_index);
            random_ready();
            snap_in_valid = valid_in;
            snap_in_ready = ready_in;
            snap_out_valid = valid_out;
            snap_out_ready = ready_out;
            snap_product = rq_product_vec;
            snap_result = rq_result_vec;
            snap_metadata = metadata_out;
            snap_source_index = source_index;
            have_snapshot = 1;
            guard = 0;
            while (guard < 10000) begin
                @(posedge clk);
                @(negedge clk);
                if (have_snapshot) begin
                    check_snapshot();
                    if (snap_in_valid && snap_in_ready) begin
                        expected_index[q_tail] = snap_source_index;
                        q_tail = q_tail + 1;
                        accepted_count = accepted_count + 1;
                        source_index = source_index + 1;
                    end
                end
                if (source_index < total) begin
                    valid_in = 1'b1;
                    drive_record(source_index);
                end else begin
                    clear_input();
                end
                random_ready();
                snap_in_valid = valid_in;
                snap_in_ready = ready_in;
                snap_out_valid = valid_out;
                snap_out_ready = ready_out;
                snap_product = rq_product_vec;
                snap_result = rq_result_vec;
                snap_metadata = metadata_out;
                snap_source_index = source_index;
                have_snapshot = 1;
                guard = guard + 1;
                if (source_index >= total && q_head >= q_tail &&
                    !snap_out_valid && !valid_in)
                    break;
            end
            if (guard >= 10000) begin
                $display("VSTREAM_TIMEOUT continuous_random source=%0d accepted=%0d produced=%0d queue=%0d",
                         source_index, accepted_count, produced_count, q_tail-q_head);
                errors = errors + 1;
            end
            ready_out = 1'b1;
            @(negedge clk);
            if (have_snapshot)
                check_snapshot();
        end
    endtask

    initial begin
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_acc.mem", acc_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_multiplier.mem", mul_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_shift.mem", shift_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_zero_point.mem", zp_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_minimum.mem", min_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_maximum.mem", max_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_product.mem", product_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_expected.mem", result_mem);
        clk = 0; rst_n = 0; errors = 0; cycle_count = 0;
        accepted_count = 0; produced_count = 0; q_head = 0; q_tail = 0;
        prng = 32'hd4c0ffee; hold_valid = 0; clear_input(); ready_out = 1;
        repeat (3) @(posedge clk);
        rst_n = 1;
        run_phase(BURST_N, 0);
        run_random_stream(STALL_N);
        if (accepted_count != BURST_N + STALL_N ||
            produced_count != BURST_N + STALL_N)
            errors = errors + 1;
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_vstream_elastic_rq_pool dsp_count=16 contiguous_ii=1 random_backpressure=checked transactions=%0d", accepted_count);
        else begin
            $display("FAIL edgembconv_hwacandidate_d4_vstream_elastic_rq_pool errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
