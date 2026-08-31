`timescale 1ns/1ps
`default_nettype none

/* Differential protocol test for the packed row-store feeder.  The weight
 * pattern intentionally differs between lanes 0..3 and 4..7 so both 32-bit
 * write halves are observed at the row-bank output. */
module tb_pw_packed_rowstore_feeder;
    reg clk, rst_n;
    reg load_begin_valid;
    wire load_begin_ready;
    reg [1:0] load_epoch;
    reg [7:0] load_cin;
    reg [8:0] load_cout;
    reg load_word_valid;
    wire load_word_ready;
    reg [31:0] load_word_data;
    reg load_commit_valid;
    wire load_commit_ready;
    wire load_active, committed_valid;
    wire [1:0] committed_epoch;
    wire [13:0] expected_word_count, load_word_count;
    wire [15:0] packed_load_count;
    wire load_commit_reject, load_extra_error;

    reg job_valid;
    wire job_ready;
    reg [4:0] job_cout_tile;
    reg [1:0] job_job_epoch;
    reg [4:0] job_group_count;
    reg job_reverse_groups;
    reg [5:0] job_pixel_base;
    reg [8:0] job_cout_base;
    reg [7:0] job_output_pixels;
    reg [8:0] job_output_channels;
    reg signed [255:0] job_bias_vec, job_multiplier_vec;
    reg [47:0] job_shift_vec;
    reg signed [31:0] job_zp, job_min, job_max;
    wire job_reject_stale;
    reg group_cmd_valid;
    wire group_cmd_ready;
    reg [4:0] group_cmd_index;
    reg act_valid;
    wire act_ready;
    reg [7:0] act_pixel_mask, act_cout_mask;
    reg signed [63:0] act_vec;
    reg out_ready;
    wire out_valid;
    wire [2:0] out_row_idx;
    wire [1:0] out_beat_idx, out_lane_mask;
    wire [5:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire signed [15:0] out_data;
    wire job_done, busy;
    wire [15:0] packed_read_count, activation_accept_count,
                 activation_stall_count;

    pw_packed_rowstore_feeder #(.MAX_CIN(128), .MAX_COUT(256)) dut (
        .clk(clk), .rst_n(rst_n),
        .load_begin_valid(load_begin_valid), .load_begin_ready(load_begin_ready),
        .load_epoch(load_epoch), .load_cin(load_cin), .load_cout(load_cout),
        .load_word_valid(load_word_valid), .load_word_ready(load_word_ready),
        .load_word_data(load_word_data), .load_commit_valid(load_commit_valid),
        .load_commit_ready(load_commit_ready), .load_commit_reject(load_commit_reject),
        .load_extra_error(load_extra_error), .load_active(load_active),
        .committed_valid(committed_valid), .committed_epoch(committed_epoch),
        .expected_word_count(expected_word_count), .load_word_count(load_word_count),
        .packed_load_count(packed_load_count),
        .job_valid(job_valid), .job_ready(job_ready), .job_cout_tile(job_cout_tile),
        .job_epoch(job_job_epoch), .job_group_count(job_group_count),
        .job_reverse_groups(job_reverse_groups), .job_pixel_base(job_pixel_base),
        .job_cout_base(job_cout_base), .job_output_pixels(job_output_pixels),
        .job_output_channels(job_output_channels), .job_bias_vec(job_bias_vec),
        .job_multiplier_vec(job_multiplier_vec), .job_shift_vec(job_shift_vec),
        .job_output_zero_point_int32(job_zp), .job_activation_min_int32(job_min),
        .job_activation_max_int32(job_max), .job_reject_stale(job_reject_stale),
        .group_cmd_valid(group_cmd_valid), .group_cmd_ready(group_cmd_ready),
        .group_cmd_index(group_cmd_index), .act_valid(act_valid), .act_ready(act_ready),
        .act_pixel_mask(act_pixel_mask), .act_cout_mask(act_cout_mask),
        .act_vec(act_vec), .out_ready(out_ready), .out_valid(out_valid),
        .out_row_idx(out_row_idx), .out_beat_idx(out_beat_idx),
        .out_pixel_idx(out_pixel_idx), .out_channel_base(out_channel_base),
        .out_lane_mask(out_lane_mask), .out_data(out_data), .job_done(job_done),
        .busy(busy), .packed_read_count(packed_read_count),
        .activation_accept_count(activation_accept_count),
        .activation_stall_count(activation_stall_count)
    );

    always #5 clk = ~clk;

    integer errors, output_count, expected_outputs;
    integer current_cin, current_cout, current_pbase, current_cbase;
    integer current_pl, current_cl, current_reverse;
    integer stale_seen, missing_seen, extra_seen;
    integer expected_reads, expected_accepts;
    integer cyc, issue_dbg;

    always @(negedge clk) begin
        if (!rst_n) out_ready <= 1'b1;
        else begin
            cyc = cyc + 1;
            /* Deterministic output backpressure, including long enough runs
             * to exercise the row-bank's held-valid contract. */
            out_ready <= ((cyc % 19) == 4 || (cyc % 31) == 9) ? 1'b0 : 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (load_commit_reject) missing_seen = missing_seen + 1;
            if (load_extra_error) extra_seen = extra_seen + 1;
            if (job_reject_stale) stale_seen = stale_seen + 1;
            if (out_valid && out_ready) begin
                if (output_count >= expected_outputs) begin
                    $display("unexpected output %0d", output_count);
                    errors = errors + 1;
                end else begin
                    if (out_row_idx !== output_count/4 % 8 ||
                        out_beat_idx !== output_count % 4 ||
                        out_pixel_idx !== current_pbase + out_row_idx ||
                        out_channel_base !== current_cbase + out_beat_idx*2) begin
                        $display("TAG mismatch n=%0d p=%0d c=%0d r=%0d b=%0d",
                                 output_count, out_pixel_idx, out_channel_base,
                                 out_row_idx, out_beat_idx);
                        if (errors < 12) $display("TAG mismatch n=%0d got p=%0d c=%0d r=%0d b=%0d mask=%b exp p=%0d c=%0d r=%0d b=%0d",
                                 output_count, out_pixel_idx, out_channel_base,
                                 out_row_idx, out_beat_idx, out_lane_mask,
                                 current_pbase + (output_count/4 % 8),
                                 current_cbase + (output_count%4)*2,
                                 output_count/4 % 8, output_count%4);
                        errors = errors + 1;
                    end
                    if (out_lane_mask[0] !== ((out_row_idx < current_pl) &&
                                               (out_beat_idx*2 < current_cl))) begin
                        if (errors < 12) $display("MASK0 mismatch n=%0d got=%b p=%0d r=%0d b=%0d", output_count, out_lane_mask, out_pixel_idx, out_row_idx, out_beat_idx);
                        errors = errors + 1;
                    end
                    if (out_lane_mask[1] !== ((out_row_idx < current_pl) &&
                                               (out_beat_idx*2+1 < current_cl))) begin
                        if (errors < 12) $display("MASK1 mismatch n=%0d got=%b p=%0d r=%0d b=%0d", output_count, out_lane_mask, out_pixel_idx, out_row_idx, out_beat_idx);
                        errors = errors + 1;
                    end
                    if (out_lane_mask[0] &&
                        out_data[7:0] !== ((current_cin*(out_beat_idx*2+1)) > 127 ? 8'sd127 :
                                           current_cin*(out_beat_idx*2+1))) begin
                        if (errors < 12) $display("DATA0 mismatch n=%0d got=%h exp=%0d mask=%b", output_count, out_data, ((current_cin*(out_beat_idx*2+1)) > 127 ? 127 : current_cin*(out_beat_idx*2+1)), out_lane_mask);
                        errors = errors + 1;
                    end
                    if (out_lane_mask[1] &&
                        out_data[15:8] !== ((current_cin*(out_beat_idx*2+2)) > 127 ? 8'sd127 :
                                           current_cin*(out_beat_idx*2+2))) begin
                        if (errors < 12) $display("DATA1 mismatch n=%0d got=%h exp=%0d mask=%b", output_count, out_data, ((current_cin*(out_beat_idx*2+2)) > 127 ? 127 : current_cin*(out_beat_idx*2+2)), out_lane_mask);
                        errors = errors + 1;
                    end
                end
                output_count = output_count + 1;
            end
        end
    end

    task automatic pulse_begin;
        input integer cin_i, cout_i, epoch_i;
        begin
            @(negedge clk);
            load_epoch = epoch_i; load_cin = cin_i; load_cout = cout_i;
            load_begin_valid = 1'b1;
            while (!load_begin_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); load_begin_valid = 1'b0;
        end
    endtask

    task automatic send_word;
        input [31:0] data_i;
        begin
            @(negedge clk); load_word_data = data_i; load_word_valid = 1'b1;
            while (!load_word_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); load_word_valid = 1'b0;
        end
    endtask

    task automatic load_case;
        input integer cin_i, cout_i, epoch_i, missing_i, extra_i;
        integer nw, wi;
        reg [31:0] word;
        begin
            pulse_begin(cin_i, cout_i, epoch_i);
            nw = 2*cin_i*((cout_i+7)/8);
            for (wi = 0; wi < nw-missing_i; wi = wi + 1) begin
                /* lanes 0..3 or 4..7; the upper/lower-half distinction is
                 * visible in the output because each lane has weight lane+1. */
                word = (wi[0] ? 32'h08070605 : 32'h04030201);
                send_word(word);
            end
            if (extra_i != 0) begin
                @(negedge clk); load_word_data = 32'heeddccbb;
                load_word_valid = 1'b1;
                if (load_word_ready) begin
                    $display("extra word was incorrectly accepted"); errors=errors+1;
                end
                @(posedge clk); @(negedge clk); load_word_valid = 1'b0;
            end
        end
    endtask

    task automatic commit_case;
        begin
            @(negedge clk); load_commit_valid = 1'b1;
            @(posedge clk);
            if (!load_commit_ready) begin
                /* Caller may intentionally test a missing-word rejection. */
            end
            @(negedge clk); load_commit_valid = 1'b0;
        end
    endtask

    task automatic send_job;
        input integer cin_i, cout_i, epoch_i, tile_i, pbase_i, cbase_i, rev_i;
        integer g, k, p_lanes, c_lanes;
        integer read0, acc0;
        begin
            current_cin=cin_i; current_cout=cout_i; current_pbase=pbase_i;
            current_cbase=cbase_i; current_pl=8;
            if (pbase_i+8 > 17) current_pl=17-pbase_i;
            current_cl=8; if (cbase_i+8 > cout_i) current_cl=cout_i-cbase_i;
            expected_outputs=32; output_count=0;
            read0=packed_read_count; acc0=activation_accept_count;
            @(negedge clk);
            job_cout_tile=tile_i; job_job_epoch=epoch_i;
            job_group_count=(cin_i+7)/8; job_reverse_groups=rev_i;
            job_pixel_base=pbase_i; job_cout_base=cbase_i;
            job_output_pixels=17; job_output_channels=cout_i;
            job_bias_vec=0; job_multiplier_vec=0;
            for (m=0; m<8; m=m+1)
                job_multiplier_vec[(m*32)+:32]=32'h7fffffff;
            job_shift_vec=0; job_zp=0; job_min=-128; job_max=127;
            job_valid=1'b1;
            while (!job_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); job_valid=1'b0;
            for (g=0; g<(cin_i+7)/8; g=g+1) begin
                @(negedge clk); group_cmd_index=g; group_cmd_valid=1'b1;
                while (!group_cmd_ready) @(posedge clk);
                @(posedge clk); @(negedge clk); group_cmd_valid=1'b0;
                for (k=0; k<8; k=k+1) begin
                    @(negedge clk);
                    act_pixel_mask=(current_pl==8)?8'hff:(1<<current_pl);
                    if (current_pl != 8) act_pixel_mask=(1<<current_pl)-1;
                    act_cout_mask=(current_cl==8)?8'hff:(1<<current_cl)-1;
                    act_vec=64'h0101010101010101; act_valid=1'b1;
                    while (!act_ready) @(posedge clk);
                    @(posedge clk); @(negedge clk); act_valid=1'b0;
                end
            end
            while (!job_done) @(posedge clk);
            if ((packed_read_count-read0) != cin_i ||
                (activation_accept_count-acc0) != cin_i) begin
                $display("counter mismatch cin=%0d read=%0d accept=%0d", cin_i,
                         packed_read_count-read0, activation_accept_count-acc0);
                errors=errors+1;
            end
        end
    endtask

    integer m;
    initial begin
        clk=0; rst_n=0; load_begin_valid=0; load_epoch=0; load_cin=0; load_cout=0;
        load_word_valid=0; load_word_data=0; load_commit_valid=0;
        job_valid=0; job_cout_tile=0; job_job_epoch=0; job_group_count=0;
        job_reverse_groups=0; job_pixel_base=0; job_cout_base=0;
        job_output_pixels=17; job_output_channels=0; job_bias_vec=0;
        job_multiplier_vec=0; job_shift_vec=0; job_zp=0; job_min=-128; job_max=127;
        group_cmd_valid=0; group_cmd_index=0; act_valid=0; act_pixel_mask=0;
        act_cout_mask=0; act_vec=0; out_ready=1;
        errors=0; output_count=0; expected_outputs=0; cyc=0; issue_dbg=0;
        missing_seen=0; extra_seen=0; stale_seen=0;
        repeat (5) @(posedge clk); rst_n=1;

        /* Missing and extra word checks are performed on the first load. */
        load_case(16,13,1,1,0); commit_case();
        if (!load_commit_reject) begin end
        send_word(32'h08070605); /* complete the deliberately short load */
        @(negedge clk); load_word_data=32'heeddccbb; load_word_valid=1'b1;
        @(posedge clk); @(negedge clk); load_word_valid=1'b0;
        @(negedge clk); load_commit_valid=1'b1;
        while (!load_commit_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); load_commit_valid=1'b0;
        send_job(16,13,1,0,0,0,0);
        send_job(16,13,1,1,0,8,0);
        send_job(16,13,1,0,8,0,1);
        send_job(16,13,1,1,8,8,1);

        load_case(48,256,2,0,0);
        @(negedge clk); load_commit_valid=1'b1;
        while (!load_commit_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); load_commit_valid=1'b0;
        /* Stale epoch must not start a job. */
        @(negedge clk); job_job_epoch=3; job_cout_tile=0; job_group_count=6;
        job_valid=1'b1; @(posedge clk); @(negedge clk); job_valid=1'b0;
        send_job(48,256,2,0,0,0,1);
        send_job(48,256,2,31,8,248,1);

        load_case(128,13,3,0,0);
        @(negedge clk); load_commit_valid=1'b1;
        while (!load_commit_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); load_commit_valid=1'b0;
        send_job(128,13,3,0,0,0,1);
        send_job(128,13,3,1,8,8,1);

        while (busy) @(posedge clk);
        if (missing_seen == 0 || extra_seen == 0 || stale_seen == 0) begin
            $display("FAIL protocol checks missing=%0d extra=%0d stale=%0d",
                     missing_seen, extra_seen, stale_seen); $fatal;
        end
        if (errors != 0) begin
            $display("FAIL tb_pw_packed_rowstore_feeder errors=%0d", errors); $fatal;
        end
        $display("PASS tb_pw_packed_rowstore_feeder outputs=%0d cycles=%0d loads=%0d reads=%0d",
                 output_count, cyc, packed_load_count, packed_read_count);
        $finish;
    end
endmodule
`default_nettype wire
