`timescale 1ns/1ps
`default_nettype none

/* Differential integration test for the paired DW scratch bank and packed PW
 * row store.  The loader stream is the real 32-bit tile/K/half ABI; no scalar
 * dynamic weight address is driven by this test. */
module tb_dw_pw_pair_scratch_rowbank2_packed_consumer;
    localparam integer MAX_CIN = 128;
    localparam integer MAX_COUT = 16;
    localparam integer MAX_GROUPS = 16;
    localparam integer MAX_OUT = 32;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg dw_acquire_valid, dw_acquire_bank;
    reg [1:0] dw_acquire_session, dw_acquire_epoch;
    reg [4:0] dw_acquire_group_count;
    wire dw_acquire_ready;
    reg dw_write_valid, dw_write_bank, dw_write_half;
    reg [4:0] dw_write_group;
    reg [255:0] dw_write_data;
    reg [31:0] dw_write_lane_mask;
    wire dw_write_ready;
    reg dw_commit_valid, dw_commit_bank;
    reg [1:0] dw_commit_session, dw_commit_epoch;
    wire dw_commit_ready;

    reg pw_load_begin_valid;
    wire pw_load_begin_ready;
    reg [1:0] pw_load_epoch;
    reg [7:0] pw_load_cin;
    reg [8:0] pw_load_cout;
    reg pw_load_word_valid;
    wire pw_load_word_ready;
    reg [31:0] pw_load_word_data;
    reg pw_load_commit_valid;
    wire pw_load_commit_ready;
    wire pw_load_commit_reject, pw_load_extra_error, pw_load_active;
    wire pw_committed_valid;
    wire [1:0] pw_committed_epoch;
    wire [13:0] pw_expected_word_count, pw_load_word_count;
    wire [15:0] pw_packed_load_count;

    reg job_valid, job_bank, job_reverse_groups;
    reg [4:0] job_cout_tile;
    reg [1:0] job_session, job_epoch;
    reg [4:0] job_group_count;
    reg [5:0] job_pixel_base;
    reg [8:0] job_cout_base;
    reg [7:0] job_output_pixels;
    reg [8:0] job_output_channels;
    reg signed [255:0] job_bias_vec, job_multiplier_vec;
    reg [47:0] job_shift_vec;
    reg signed [31:0] job_zp, job_min, job_max;
    wire job_ready, out_valid, job_done, busy;
    reg out_ready;
    wire [2:0] out_row_idx;
    wire [1:0] out_beat_idx, out_lane_mask;
    wire [5:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire signed [15:0] out_data;
    wire [1:0] scratch_bank0_state, scratch_bank1_state;
    wire [15:0] packed_read_count, activation_accept_count,
                activation_stall_count;

    dw_pw_pair_scratch_rowbank2_packed_consumer #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT), .MAX_GROUPS(MAX_GROUPS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_session(dw_acquire_session),
        .dw_acquire_epoch(dw_acquire_epoch), .dw_acquire_group_count(dw_acquire_group_count),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_write_bank), .dw_write_group(dw_write_group),
        .dw_write_half(dw_write_half), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_session(dw_commit_session),
        .dw_commit_epoch(dw_commit_epoch),
        .pw_load_begin_valid(pw_load_begin_valid), .pw_load_begin_ready(pw_load_begin_ready),
        .pw_load_epoch(pw_load_epoch), .pw_load_cin(pw_load_cin), .pw_load_cout(pw_load_cout),
        .pw_load_word_valid(pw_load_word_valid), .pw_load_word_ready(pw_load_word_ready),
        .pw_load_word_data(pw_load_word_data), .pw_load_commit_valid(pw_load_commit_valid),
        .pw_load_commit_ready(pw_load_commit_ready), .pw_load_commit_reject(pw_load_commit_reject),
        .pw_load_extra_error(pw_load_extra_error), .pw_load_active(pw_load_active),
        .pw_committed_valid(pw_committed_valid), .pw_committed_epoch(pw_committed_epoch),
        .pw_expected_word_count(pw_expected_word_count), .pw_load_word_count(pw_load_word_count),
        .pw_packed_load_count(pw_packed_load_count),
        .job_valid(job_valid), .job_ready(job_ready), .job_cout_tile(job_cout_tile),
        .job_bank(job_bank), .job_session(job_session), .job_epoch(job_epoch),
        .job_group_count(job_group_count), .job_reverse_groups(job_reverse_groups),
        .job_pixel_base(job_pixel_base), .job_cout_base(job_cout_base),
        .job_output_pixels(job_output_pixels), .job_output_channels(job_output_channels),
        .job_bias_vec(job_bias_vec), .job_multiplier_vec(job_multiplier_vec),
        .job_shift_vec(job_shift_vec), .job_output_zero_point_int32(job_zp),
        .job_activation_min_int32(job_min), .job_activation_max_int32(job_max),
        .out_valid(out_valid), .out_ready(out_ready), .out_row_idx(out_row_idx),
        .out_beat_idx(out_beat_idx), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_lane_mask(out_lane_mask),
        .out_data(out_data), .job_done(job_done), .busy(busy),
        .scratch_bank0_state(scratch_bank0_state), .scratch_bank1_state(scratch_bank1_state),
        .packed_read_count(packed_read_count),
        .activation_accept_count(activation_accept_count),
        .activation_stall_count(activation_stall_count)
    );

    integer errors = 0;
    integer output_count = 0;
    integer expected_count = 0;
    integer cycle_count = 0;
    integer guard;
    integer ptotal_reg, ctotal_reg, pbase_reg, cbase_reg, cin_reg, case_reg;
    integer cfg_bias [0:7];
    integer cfg_mul [0:7];
    integer cfg_shift [0:7];
    integer cfg_zp, cfg_min, cfg_max;
    integer acc [0:63];
    reg [5:0] exp_pixel [0:MAX_OUT-1];
    reg [8:0] exp_cout [0:MAX_OUT-1];
    reg [2:0] exp_row [0:MAX_OUT-1];
    reg [1:0] exp_beat [0:MAX_OUT-1];
    reg [1:0] exp_mask [0:MAX_OUT-1];
    reg signed [15:0] exp_data [0:MAX_OUT-1];
    reg held_valid;
    reg [5:0] held_pixel;
    reg [8:0] held_cout;
    reg [2:0] held_row;
    reg [1:0] held_beat, held_mask;
    reg signed [15:0] held_data;

    function integer act_value;
        input integer ci, p, k;
        begin act_value = ((ci * 17 + p * 7 + k * 5 + 3) % 15) - 7; end
    endfunction
    function integer weight_value;
        input integer ci, k, c;
        begin weight_value = ((ci * 11 + k * 3 + c * 7 + 1) % 11) - 5; end
    endfunction
    function signed [7:0] rq_ref;
        input integer acc_i, bias_i, mul_i, shift_i;
        input integer zp_i, min_i, max_i;
        reg signed [32:0] sum;
        reg signed [64:0] product, fixed_mul, abs_value, rounded_abs, value;
        reg signed [64:0] offset;
        begin
            sum = acc_i + bias_i;
            product = $signed(sum) * $signed({{33{mul_i[31]}},mul_i});
            offset = 65'sd1 <<< 30;
            if (product >= 0) fixed_mul = (product + offset) >>> 31;
            else begin
                abs_value = -product;
                rounded_abs = (abs_value + offset) >>> 31;
                fixed_mul = -rounded_abs;
            end
            value = (fixed_mul >>> shift_i) + zp_i;
            if (value > 127) value = 127;
            else if (value < -128) value = -128;
            if (value < min_i) value = min_i;
            else if (value > max_i) value = max_i;
            rq_ref = value[7:0];
        end
    endfunction

    task automatic build_config;
        input integer ci;
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                cfg_bias[q] = ci * 9 + q * 13 - 27;
                cfg_mul[q] = 32'sh7fffffff;
                cfg_shift[q] = (ci + q) % 3;
                job_bias_vec[(q*32) +: 32] = cfg_bias[q];
                job_multiplier_vec[(q*32) +: 32] = cfg_mul[q];
                job_shift_vec[(q*6) +: 6] = cfg_shift[q];
            end
            cfg_zp = (ci % 3) - 1; cfg_min = -128; cfg_max = 127;
            job_zp = cfg_zp; job_min = cfg_min; job_max = cfg_max;
        end
    endtask

    task automatic build_expected;
        integer p, c, k, q, rr, bb, base, pl, cl, sum_i;
        reg signed [7:0] d0, d1;
        reg [1:0] m;
        begin
            pl = ptotal_reg - pbase_reg; if (pl > 8) pl = 8; if (pl < 0) pl = 0;
            cl = ctotal_reg - cbase_reg; if (cl > 8) cl = 8; if (cl < 0) cl = 0;
            for (p = 0; p < 64; p = p + 1) acc[p] = 0;
            for (p = 0; p < 8; p = p + 1)
                for (q = 0; q < 8; q = q + 1) begin
                    sum_i = 0;
                    for (k = 0; k < cin_reg; k = k + 1)
                        sum_i = sum_i + act_value(case_reg, pbase_reg+p, k) *
                                weight_value(case_reg, k, cbase_reg+q);
                    acc[p*8+q] = sum_i;
                end
            expected_count = 0;
            for (rr = 0; rr < 8; rr = rr + 1)
                for (bb = 0; bb < 4; bb = bb + 1) begin
                    base = rr*8 + bb*2;
                    d0 = rq_ref(acc[base], cfg_bias[bb*2], cfg_mul[bb*2],
                                cfg_shift[bb*2], cfg_zp, cfg_min, cfg_max);
                    d1 = rq_ref(acc[base+1], cfg_bias[bb*2+1], cfg_mul[bb*2+1],
                                cfg_shift[bb*2+1], cfg_zp, cfg_min, cfg_max);
                    m = 0;
                    if ((rr < pl) && (bb*2 < cl)) m[0] = 1'b1;
                    if ((rr < pl) && (bb*2+1 < cl)) m[1] = 1'b1;
                    exp_pixel[expected_count] = pbase_reg + rr;
                    exp_cout[expected_count] = cbase_reg + bb*2;
                    exp_row[expected_count] = rr;
                    exp_beat[expected_count] = bb;
                    exp_mask[expected_count] = m;
                    exp_data[expected_count] = {d1, d0};
                    expected_count = expected_count + 1;
                end
            output_count = 0;
        end
    endtask

    task automatic pulse_begin_load;
        input integer ci, co, ep;
        begin
            @(negedge clk); pw_load_epoch=ep; pw_load_cin=ci; pw_load_cout=co;
            pw_load_begin_valid=1'b1;
            while (!pw_load_begin_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); pw_load_begin_valid=1'b0;
        end
    endtask
    task automatic send_word;
        input [31:0] data_i;
        begin
            @(negedge clk); pw_load_word_data=data_i; pw_load_word_valid=1'b1;
            while (!pw_load_word_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); pw_load_word_valid=1'b0;
        end
    endtask
    task automatic load_weights;
        input integer ci, co, ep, ca;
        integer t, k, h, l, c;
        reg [31:0] word;
        begin
            pulse_begin_load(ci, co, ep);
            for (t=0; t<(co+7)/8; t=t+1)
                for (k=0; k<ci; k=k+1)
                    for (h=0; h<2; h=h+1) begin
                        word=0;
                        for (l=0; l<4; l=l+1) begin
                            c=t*8+h*4+l;
                            if (c < co) word[l*8 +: 8] = weight_value(ca,k,c);
                            else word[l*8 +: 8] = 0;
                        end
                        send_word(word);
                    end
            @(negedge clk); pw_load_commit_valid=1'b1;
            while (!pw_load_commit_ready) @(posedge clk);
            @(posedge clk); @(negedge clk); pw_load_commit_valid=1'b0;
            if (!pw_committed_valid || pw_committed_epoch != ep[1:0]) begin
                $display("FAIL packed weight commit ep=%0d valid=%b got=%0d", ep,
                         pw_committed_valid, pw_committed_epoch); errors=errors+1;
            end
        end
    endtask

    task automatic pulse_acquire;
        input integer bank_i, session_i, epoch_i, groups_i;
        reg fired;
        begin
            dw_acquire_bank=bank_i; dw_acquire_session=session_i; dw_acquire_epoch=epoch_i;
            dw_acquire_group_count=groups_i;
            @(negedge clk); dw_acquire_valid=1'b1; fired=0;
            while (!fired) begin @(posedge clk); if (dw_acquire_ready) fired=1; end
            @(negedge clk); dw_acquire_valid=1'b0;
        end
    endtask
    task automatic pulse_write_half;
        input integer bank_i, group_i, half_i, ci, ca;
        integer p, ch, gp, gk, bubble;
        reg fired;
        begin
            dw_write_bank=bank_i; dw_write_group=group_i; dw_write_half=half_i;
            dw_write_data=0; dw_write_lane_mask=0;
            for (p=0;p<4;p=p+1) for (ch=0;ch<8;ch=ch+1) begin
                gp = half_i ? p+4 : p; gk=group_i*8+ch;
                dw_write_data[(p*8+ch)*8 +: 8] = act_value(ca,pbase_reg+gp,gk);
                if ((pbase_reg+gp<ptotal_reg) && (gk<ci))
                    dw_write_lane_mask[p*8+ch]=1'b1;
            end
            bubble=(ca+group_i+half_i)%3; repeat (bubble) @(posedge clk);
            @(negedge clk); dw_write_valid=1'b1; fired=0;
            while (!fired) begin @(posedge clk); if (dw_write_ready) fired=1; end
            @(negedge clk); dw_write_valid=1'b0;
        end
    endtask
    task automatic pulse_commit;
        input integer bank_i, session_i, epoch_i;
        reg fired;
        begin
            dw_commit_bank=bank_i; dw_commit_session=session_i; dw_commit_epoch=epoch_i;
            @(negedge clk); dw_commit_valid=1'b1; fired=0;
            while (!fired) begin @(posedge clk); if (dw_commit_ready) fired=1; end
            @(negedge clk); dw_commit_valid=1'b0;
        end
    endtask
    task automatic pulse_job;
        input integer tile_i, bank_i, session_i, epoch_i, groups_i, reverse_i;
        reg fired;
        begin
            job_cout_tile=tile_i; job_bank=bank_i; job_session=session_i; job_epoch=epoch_i;
            job_group_count=groups_i; job_reverse_groups=reverse_i;
            @(negedge clk); job_valid=1'b1; fired=0;
            while (!fired) begin @(posedge clk); if (job_ready) fired=1; end
            @(negedge clk); job_valid=1'b0;
        end
    endtask
    task automatic run_job;
        input integer ci, co, ep, bank_i, session_i, case_i, pbase_i, cbase_i, reverse_i;
        integer g;
        begin
            cin_reg=ci; ctotal_reg=co; ptotal_reg=17; pbase_reg=pbase_i;
            cbase_reg=cbase_i; case_reg=case_i;
            job_pixel_base=pbase_i; job_cout_base=cbase_i;
            job_output_pixels=17; job_output_channels=co;
            build_config(case_i); build_expected();
            pulse_acquire(bank_i,session_i,ep,(ci+7)/8);
            for (g=0;g<(ci+7)/8;g=g+1) begin
                pulse_write_half(bank_i,g,(g&1)&&reverse_i,ci,case_i);
                pulse_write_half(bank_i,g,((g&1)&&reverse_i)?0:1,ci,case_i);
            end
            pulse_commit(bank_i,session_i,ep);
            pulse_job(cbase_i/8,bank_i,session_i,ep,(ci+7)/8,reverse_i);
            guard=0;
            while (!job_done && guard < 200000) begin @(negedge clk); guard=guard+1; end
            if (!job_done || output_count != expected_count) begin
                $display("FAIL packed job ci=%0d case=%0d p=%0d c=%0d out=%0d/%0d done=%b guard=%0d",
                         ci,case_i,pbase_i,cbase_i,output_count,expected_count,job_done,guard);
                errors=errors+1; $fatal(1);
            end
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n) out_ready=1'b1;
        else begin
            cycle_count=cycle_count+1;
            out_ready=!((cycle_count%17==3)||(cycle_count%29==8)||(cycle_count%41==19));
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (held_valid) begin
                if (!out_valid || out_pixel_idx!==held_pixel || out_channel_base!==held_cout ||
                    out_row_idx!==held_row || out_beat_idx!==held_beat ||
                    out_lane_mask!==held_mask || out_data!==held_data) begin
                    $display("FAIL packed unstable stalled output"); errors=errors+1;
                end
                if (out_ready) held_valid=0;
            end
            if (out_valid && !out_ready) begin
                held_valid=1; held_pixel=out_pixel_idx; held_cout=out_channel_base;
                held_row=out_row_idx; held_beat=out_beat_idx;
                held_mask=out_lane_mask; held_data=out_data;
            end
            if (out_valid && out_ready) begin
                if (output_count >= expected_count) begin errors=errors+1; $display("FAIL extra output"); end
                else begin
                    if (out_pixel_idx!==exp_pixel[output_count] || out_channel_base!==exp_cout[output_count] ||
                        out_row_idx!==exp_row[output_count] || out_beat_idx!==exp_beat[output_count] ||
                        out_lane_mask!==exp_mask[output_count]) begin
                        $display("FAIL packed TAG n=%0d got p=%0d c=%0d r=%0d b=%0d m=%b exp p=%0d c=%0d r=%0d b=%0d m=%b",
                                 output_count,out_pixel_idx,out_channel_base,out_row_idx,out_beat_idx,out_lane_mask,
                                 exp_pixel[output_count],exp_cout[output_count],exp_row[output_count],exp_beat[output_count],exp_mask[output_count]);
                        errors=errors+1;
                    end
                    if ((out_lane_mask[0] && out_data[7:0]!==exp_data[output_count][7:0]) ||
                        (out_lane_mask[1] && out_data[15:8]!==exp_data[output_count][15:8])) begin
                        $display("FAIL packed DATA n=%0d got=%h exp=%h m=%b",output_count,out_data,exp_data[output_count],out_lane_mask); errors=errors+1;
                    end
                end
                output_count=output_count+1;
            end
        end
    end

    integer load_case_idx;
    initial begin
        dw_acquire_valid=0; dw_acquire_bank=0; dw_acquire_session=0; dw_acquire_epoch=0; dw_acquire_group_count=0;
        dw_write_valid=0; dw_write_bank=0; dw_write_half=0; dw_write_group=0; dw_write_data=0; dw_write_lane_mask=0;
        dw_commit_valid=0; dw_commit_bank=0; dw_commit_session=0; dw_commit_epoch=0;
        pw_load_begin_valid=0; pw_load_epoch=0; pw_load_cin=0; pw_load_cout=0; pw_load_word_valid=0;
        pw_load_word_data=0; pw_load_commit_valid=0;
        job_valid=0; job_cout_tile=0; job_bank=0; job_session=0; job_epoch=0; job_group_count=0;
        job_reverse_groups=0; job_pixel_base=0; job_cout_base=0; job_output_pixels=17; job_output_channels=13;
        job_bias_vec=0; job_multiplier_vec=0; job_shift_vec=0; job_zp=0; job_min=-128; job_max=127;
        out_ready=1; held_valid=0; cycle_count=0;
        repeat (4) @(posedge clk); @(negedge clk); rst_n=1'b1;

        /* Each load is tile-major/K-minor and each job changes session,
         * bank, tails, and group order. */
        load_weights(16,13,1,0);
        run_job(16,13,1,0,1,0,0,0,0);
        load_weights(48,13,2,1);
        run_job(48,13,2,1,2,1,8,8,1);
        load_weights(128,13,3,0);
        run_job(128,13,3,0,3,2,16,0,1);

        while (busy) @(posedge clk);
        if (errors != 0) begin $display("FAIL packed consumer errors=%0d",errors); $fatal(1); end
        $display("PASS packed pair consumer jobs=3 outputs=%0d cycles=%0d packed_words=%0d packed_reads=%0d",
                 output_count,cycle_count,pw_packed_load_count,packed_read_count);
        $finish;
    end
endmodule
`default_nettype wire
