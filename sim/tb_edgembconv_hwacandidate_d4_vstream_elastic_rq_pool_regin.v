`timescale 1ns/1ps
`default_nettype none

/*
 * Contract test for the registered-input pool shell.  The first burst proves
 * that a ready output permits a continuous II=1 PW acceptance stream.  A
 * following RQ burst changes mode only after the old pipeline drains; tags
 * and mode are checked at the output boundary to catch any operand/context
 * skew across the added input register.
 */
module tb_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin;
    reg clk, rst_n, mode_rq, valid_in, ready_out;
    reg signed [127:0] rq_acc_vec, rq_multiplier_vec;
    reg [23:0] rq_shift_vec;
    reg signed [127:0] rq_zero_point_vec, rq_min_vec, rq_max_vec;
    reg [127:0] pw_act_vec, pw_wgt_vec;
    reg [31:0] metadata_in;
    wire ready_in, valid_out, mode_rq_out;
    wire [255:0] pw_product_vec;
    wire signed [255:0] rq_product_vec;
    wire signed [31:0] rq_result_vec;
    wire [31:0] metadata_out;

    integer i, errors, tick, accepted_total, produced_total;
    integer pw_accept_count, rq_accept_count, pw_first_tick, pw_last_tick;
    integer pw_gap_count;
    reg [31:0] expected_metadata [0:63];
    reg expected_mode [0:63];

    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin dut (
        .clk(clk), .rst_n(rst_n), .mode_rq(mode_rq), .valid_in(valid_in),
        .ready_in(ready_in), .rq_acc_vec(rq_acc_vec),
        .rq_multiplier_vec(rq_multiplier_vec), .rq_shift_vec(rq_shift_vec),
        .rq_zero_point_vec(rq_zero_point_vec), .rq_min_vec(rq_min_vec),
        .rq_max_vec(rq_max_vec), .pw_act_vec(pw_act_vec),
        .pw_wgt_vec(pw_wgt_vec), .metadata_in(metadata_in),
        .valid_out(valid_out), .ready_out(ready_out),
        .mode_rq_out(mode_rq_out), .pw_product_vec(pw_product_vec),
        .rq_product_vec(rq_product_vec), .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out));

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick = 0;
            accepted_total = 0;
            produced_total = 0;
            pw_accept_count = 0;
            rq_accept_count = 0;
            pw_first_tick = -1;
            pw_last_tick = -1;
            pw_gap_count = 0;
        end else begin
            tick = tick + 1;
            if (valid_in && ready_in) begin
                expected_metadata[accepted_total] = metadata_in;
                expected_mode[accepted_total] = mode_rq;
                if (mode_rq) begin
                    rq_accept_count = rq_accept_count + 1;
                end else begin
                    if (pw_first_tick < 0)
                        pw_first_tick = tick;
                    else if (tick != pw_last_tick + 1)
                        pw_gap_count = pw_gap_count + 1;
                    pw_last_tick = tick;
                    pw_accept_count = pw_accept_count + 1;
                end
                accepted_total = accepted_total + 1;
            end
            if (valid_out && ready_out) begin
                if (produced_total >= accepted_total) begin
                    $display("POOL_REGIN_EXTRA_OUTPUT index=%0d",produced_total);
                    errors = errors + 1;
                end else begin
                    if (metadata_out !== expected_metadata[produced_total] ||
                        mode_rq_out !== expected_mode[produced_total]) begin
                        $display("POOL_REGIN_TAG_MISMATCH index=%0d exp_meta=%08x got_meta=%08x exp_mode=%0d got_mode=%0d",produced_total,expected_metadata[produced_total],metadata_out,expected_mode[produced_total],mode_rq_out);
                        errors = errors + 1;
                    end
                end
                produced_total = produced_total + 1;
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        mode_rq = 0;
        valid_in = 0;
        ready_out = 1;
        rq_acc_vec = 0;
        rq_multiplier_vec = 0;
        rq_shift_vec = 0;
        rq_zero_point_vec = 0;
        rq_min_vec = 0;
        rq_max_vec = 0;
        pw_act_vec = 128'h0807060504030201_0807060504030201;
        pw_wgt_vec = 128'h0101010101010101_0101010101010101;
        metadata_in = 0;
        errors = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;

        /* A continuous PW burst.  Metadata is changed only at a falling
         * edge after the preceding request was accepted, so the source obeys
         * the same stable-while-stalled contract as a real producer. */
        @(negedge clk);
        mode_rq = 0;
        valid_in = 1;
        metadata_in = 32'h0000_0000;
        for (i = 0; i < 32; i = i + 1) begin
            @(posedge clk);
            if (ready_in && (i < 31)) begin
                @(negedge clk);
                metadata_in = i + 1;
            end
        end
        @(negedge clk);
        valid_in = 0;

        while (produced_total < 32) begin
            @(posedge clk);
            if (tick > 2000)
                $fatal(1,"POOL_REGIN_TIMEOUT_PW accepted=%0d produced=%0d",accepted_total,produced_total);
        end
        if (pw_accept_count != 32 || pw_gap_count != 0 ||
            pw_last_tick - pw_first_tick != 31) begin
            $display("POOL_REGIN_II_FAIL accepts=%0d gaps=%0d first=%0d last=%0d",pw_accept_count,pw_gap_count,pw_first_tick,pw_last_tick);
            errors = errors + 1;
        end

        /* Change mode while the old pool is emptying.  The registered shell
         * may accept one RQ token early, but must preserve its tag and mode. */
        @(negedge clk);
        mode_rq = 1;
        valid_in = 1;
        metadata_in = 32'h0000_0100;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            if (ready_in && (i < 7)) begin
                @(negedge clk);
                metadata_in = 32'h0000_0101 + i;
            end
        end
        @(negedge clk);
        valid_in = 0;

        while (produced_total < 40) begin
            @(posedge clk);
            if (tick > 4000)
                $fatal(1,"POOL_REGIN_TIMEOUT_RQ accepted=%0d produced=%0d",accepted_total,produced_total);
        end
        if (accepted_total != 40 || produced_total != 40 ||
            pw_accept_count != 32 || rq_accept_count != 8)
            errors = errors + 1;

        $display("POOL_REGIN_STATS accepted=%0d produced=%0d pw=%0d rq=%0d ii1_gaps=%0d cycles=%0d errors=%0d",accepted_total,produced_total,pw_accept_count,rq_accept_count,pw_gap_count,tick,errors);
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin ii=1 tag_mode_exact");
        else
            $fatal(1,"POOL_REGIN_FAIL errors=%0d",errors);
        $finish;
    end
endmodule

`default_nettype wire
