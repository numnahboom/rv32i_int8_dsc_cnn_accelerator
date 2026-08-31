`timescale 1ns/1ps
`default_nettype none

/* Differential protocol test for the non-production paired-half consumer. */
module tb_dw_pw_pair_scratch_rowbank2_consumer;
    localparam integer MAX_CIN = 48;
    localparam integer MAX_COUT = 16;
    localparam integer MAX_GROUPS = 6;
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
    reg pw_weight_wr_en;
    reg [15:0] pw_weight_wr_idx;
    reg signed [7:0] pw_weight_wr_data;
    reg job_valid, job_bank, job_reverse_groups;
    reg [1:0] job_session, job_epoch;
    reg [4:0] job_group_count;
    reg [5:0] job_pixel_base;
    reg [8:0] job_cout_base;
    reg [7:0] job_output_pixels;
    reg [8:0] job_output_channels;
    reg signed [255:0] job_bias_vec, job_multiplier_vec;
    reg [47:0] job_shift_vec;
    reg signed [31:0] job_output_zero_point_int32;
    reg signed [31:0] job_activation_min_int32;
    reg signed [31:0] job_activation_max_int32;
    wire job_ready, out_valid, job_done, busy;
    reg out_ready;
    wire [2:0] out_row_idx;
    wire [1:0] out_beat_idx, out_lane_mask;
    wire [5:0] out_pixel_idx;
    wire [8:0] out_channel_base;
    wire signed [15:0] out_data;
    wire [1:0] scratch_bank0_state, scratch_bank1_state;

    dw_pw_pair_scratch_rowbank2_consumer #(
        .MAX_CIN(MAX_CIN), .MAX_COUT(MAX_COUT), .MAX_GROUPS(MAX_GROUPS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_session(dw_acquire_session),
        .dw_acquire_epoch(dw_acquire_epoch),
        .dw_acquire_group_count(dw_acquire_group_count),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_write_bank), .dw_write_group(dw_write_group),
        .dw_write_half(dw_write_half), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_session(dw_commit_session),
        .dw_commit_epoch(dw_commit_epoch),
        .pw_weight_wr_en(pw_weight_wr_en), .pw_weight_wr_idx(pw_weight_wr_idx),
        .pw_weight_wr_data(pw_weight_wr_data),
        .job_valid(job_valid), .job_ready(job_ready), .job_bank(job_bank),
        .job_session(job_session), .job_epoch(job_epoch),
        .job_group_count(job_group_count),
        .job_reverse_groups(job_reverse_groups), .job_pixel_base(job_pixel_base),
        .job_cout_base(job_cout_base), .job_output_pixels(job_output_pixels),
        .job_output_channels(job_output_channels), .job_bias_vec(job_bias_vec),
        .job_multiplier_vec(job_multiplier_vec), .job_shift_vec(job_shift_vec),
        .job_output_zero_point_int32(job_output_zero_point_int32),
        .job_activation_min_int32(job_activation_min_int32),
        .job_activation_max_int32(job_activation_max_int32),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_row_idx(out_row_idx), .out_beat_idx(out_beat_idx),
        .out_pixel_idx(out_pixel_idx), .out_channel_base(out_channel_base),
        .out_lane_mask(out_lane_mask), .out_data(out_data),
        .job_done(job_done), .busy(busy),
        .scratch_bank0_state(scratch_bank0_state),
        .scratch_bank1_state(scratch_bank1_state)
    );

    integer errors = 0;
    integer output_count = 0;
    integer expected_count = 0;
    integer cycle_count = 0;
    integer guard;
    integer ptotal_reg, ctotal_reg, pbase_reg;
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
        input integer case_i, pixel_i, k_i;
        begin
            act_value = ((case_i * 19 + pixel_i * 23 + k_i * 29 + 17) % 127) - 63;
        end
    endfunction

    function integer weight_value;
        input integer case_i, k_i, channel_i;
        begin
            if (case_i == 0)
                weight_value = 0;
            else
                weight_value = ((case_i * 31 + k_i * 37 + channel_i * 41 + 11) % 63) - 31;
        end
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
            if (product >= 0)
                fixed_mul = (product + offset) >>> 31;
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
        input integer case_i;
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                cfg_bias[q] = ((case_i * 733 + q * 419 + 97) % 4001) - 2000;
                case ((case_i + q) % 7)
                    0: cfg_mul[q] = 32'sh7fffffff;
                    1: cfg_mul[q] = -32'sh40000000;
                    2: cfg_mul[q] = 32'sh40000000;
                    3: cfg_mul[q] = 32'sh20000000;
                    4: cfg_mul[q] = -32'sh20000000;
                    5: cfg_mul[q] = 32'sh60000000;
                    default: cfg_mul[q] = -32'sh60000000;
                endcase
                cfg_shift[q] = (case_i * 3 + q * 2) % 7;
                job_bias_vec[(q*32) +: 32] = cfg_bias[q];
                job_multiplier_vec[(q*32) +: 32] = cfg_mul[q];
                job_shift_vec[(q*6) +: 6] = cfg_shift[q];
            end
            case (case_i % 4)
                0: begin cfg_zp = 0;  cfg_min = -128; cfg_max = 127; end
                1: begin cfg_zp = 17; cfg_min = -100; cfg_max = 100; end
                2: begin cfg_zp = -23; cfg_min = -64; cfg_max = 63; end
                default: begin cfg_zp = 3; cfg_min = -127; cfg_max = 126; end
            endcase
            job_output_zero_point_int32 = cfg_zp;
            job_activation_min_int32 = cfg_min;
            job_activation_max_int32 = cfg_max;
        end
    endtask

    task automatic build_expected;
        input integer case_i;
        input integer cin_i, ptotal_i, ctotal_i, pbase_i, cbase_i;
        integer p, c, k, q, rr, bb, base;
        integer sum_i;
        integer p_lanes, c_lanes;
        reg signed [7:0] d0, d1;
        reg [1:0] m;
        begin
            p_lanes = ptotal_i - pbase_i;
            if (p_lanes > 8) p_lanes = 8;
            if (p_lanes < 0) p_lanes = 0;
            c_lanes = ctotal_i - cbase_i;
            if (c_lanes > 8) c_lanes = 8;
            if (c_lanes < 0) c_lanes = 0;
            for (p = 0; p < 64; p = p + 1)
                acc[p] = 0;
            for (p = 0; p < 8; p = p + 1)
                for (q = 0; q < 8; q = q + 1) begin
                    sum_i = 0;
                    for (k = 0; k < cin_i; k = k + 1)
                        sum_i = sum_i + act_value(case_i, pbase_i+p, k) *
                                weight_value(case_i, k, cbase_i+q);
                    acc[p*8+q] = sum_i;
                end
            expected_count = 0;
            for (rr = 0; rr < 8; rr = rr + 1)
                for (bb = 0; bb < 4; bb = bb + 1) begin
                    base = rr*8 + bb*2;
                    d0 = rq_ref(acc[base], cfg_bias[bb*2], cfg_mul[bb*2],
                                cfg_shift[bb*2], cfg_zp, cfg_min, cfg_max);
                    d1 = rq_ref(acc[base+1], cfg_bias[bb*2+1],
                                cfg_mul[bb*2+1], cfg_shift[bb*2+1],
                                cfg_zp, cfg_min, cfg_max);
                    m = 2'b0;
                    if ((rr < p_lanes) && (bb*2 < c_lanes)) m[0] = 1'b1;
                    if ((rr < p_lanes) && (bb*2+1 < c_lanes)) m[1] = 1'b1;
                    exp_pixel[expected_count] = pbase_i + rr;
                    exp_cout[expected_count] = cbase_i + bb*2;
                    exp_row[expected_count] = rr;
                    exp_beat[expected_count] = bb;
                    exp_mask[expected_count] = m;
                    exp_data[expected_count] = {d1, d0};
                    expected_count = expected_count + 1;
                end
            output_count = 0;
        end
    endtask

    task automatic pulse_acquire;
        input integer bank_i, session_i, epoch_i, groups_i;
        reg fired;
        begin
            dw_acquire_bank = bank_i[0];
            dw_acquire_session = session_i[1:0];
            dw_acquire_epoch = epoch_i[1:0];
            dw_acquire_group_count = groups_i[4:0];
            @(negedge clk); dw_acquire_valid = 1'b1; fired = 1'b0;
            while (!fired) begin
                @(posedge clk);
                if (dw_acquire_ready) fired = 1'b1;
            end
            @(negedge clk); dw_acquire_valid = 1'b0;
        end
    endtask

    task automatic pulse_write_half;
        input integer bank_i, group_i, half_i, cin_i, case_i;
        integer p, ch, global_p, global_k;
        integer bubble;
        reg fired;
        begin
            dw_write_bank = bank_i[0];
            dw_write_group = group_i[4:0];
            dw_write_half = half_i[0];
            dw_write_data = 256'd0;
            dw_write_lane_mask = 32'd0;
            for (p = 0; p < 4; p = p + 1)
                for (ch = 0; ch < 8; ch = ch + 1) begin
                    global_p = half_i ? (p + 4) : p;
                    global_k = group_i * 8 + ch;
                    dw_write_data[(p*8+ch)*8 +: 8] =
                        act_value(case_i, pbase_reg + global_p, global_k);
                    if ((pbase_reg + global_p < ptotal_reg) &&
                        (global_k < cin_i))
                        dw_write_lane_mask[p*8+ch] = 1'b1;
                end
            bubble = (case_i + group_i + half_i) % 3;
            repeat (bubble) @(posedge clk);
            @(negedge clk); dw_write_valid = 1'b1; fired = 1'b0;
            while (!fired) begin
                @(posedge clk);
                if (dw_write_ready) fired = 1'b1;
            end
            @(negedge clk); dw_write_valid = 1'b0;
        end
    endtask

    task automatic pulse_commit;
        input integer bank_i, session_i, epoch_i;
        reg fired;
        begin
            dw_commit_bank = bank_i[0];
            dw_commit_session = session_i[1:0];
            dw_commit_epoch = epoch_i[1:0];
            @(negedge clk); dw_commit_valid = 1'b1; fired = 1'b0;
            while (!fired) begin
                @(posedge clk);
                if (dw_commit_ready) fired = 1'b1;
            end
            @(negedge clk); dw_commit_valid = 1'b0;
        end
    endtask

    task automatic pulse_job;
        input integer bank_i, session_i, epoch_i, groups_i, reverse_i;
        reg fired;
        begin
            job_bank = bank_i[0]; job_session = session_i[1:0];
            job_epoch = epoch_i[1:0]; job_group_count = groups_i[4:0];
            job_reverse_groups = reverse_i[0];
            @(negedge clk); job_valid = 1'b1; fired = 1'b0;
            while (!fired) begin
                @(posedge clk);
                if (job_ready) fired = 1'b1;
            end
            @(negedge clk); job_valid = 1'b0;
        end
    endtask

    task automatic load_weights;
        input integer case_i;
        integer c, k, addr;
        begin
            for (c = 0; c < MAX_COUT; c = c + 1)
                for (k = 0; k < MAX_CIN; k = k + 1) begin
                    addr = c * MAX_CIN + k;
                    pw_weight_wr_idx = addr[15:0];
                    pw_weight_wr_data = weight_value(case_i, k, c);
                    @(negedge clk); pw_weight_wr_en = 1'b1;
                    @(posedge clk);
                    @(negedge clk); pw_weight_wr_en = 1'b0;
                end
        end
    endtask

    task automatic run_job;
        input integer case_i, bank_i, session_i, epoch_i;
        input integer cin_i, ptotal_i, ctotal_i, pbase_i, cbase_i;
        input integer reverse_i, half_swap_i;
        integer g;
        begin
            ptotal_reg = ptotal_i; ctotal_reg = ctotal_i; pbase_reg = pbase_i;
            load_weights(case_i);
            build_config(case_i);
            build_expected(case_i, cin_i, ptotal_i, ctotal_i, pbase_i, cbase_i);
            pulse_acquire(bank_i, session_i, epoch_i, (cin_i+7)/8);
            for (g = 0; g < (cin_i+7)/8; g = g + 1) begin
                if (half_swap_i && ((g & 1) != 0)) begin
                    pulse_write_half(bank_i, g, 1, cin_i, case_i);
                    pulse_write_half(bank_i, g, 0, cin_i, case_i);
                end else begin
                    pulse_write_half(bank_i, g, 0, cin_i, case_i);
                    pulse_write_half(bank_i, g, 1, cin_i, case_i);
                end
            end
            pulse_commit(bank_i, session_i, epoch_i);
            pulse_job(bank_i, session_i, epoch_i, (cin_i+7)/8, reverse_i);
            guard = 0;
            while (!job_done && guard < 100000) begin
                @(negedge clk); guard = guard + 1;
            end
            if (!job_done || output_count != expected_count) begin
                $display("FAIL job case=%0d bank=%0d cin=%0d p=%0d c=%0d outputs=%0d/%0d done=%b guard=%0d",
                         case_i, bank_i, cin_i, ptotal_i, ctotal_i,
                         output_count, expected_count, job_done, guard);
                errors = errors + 1;
                $fatal(1);
            end
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n)
            out_ready = 1'b1;
        else begin
            cycle_count = cycle_count + 1;
            out_ready = !((cycle_count % 19 == 3) ||
                          (cycle_count % 19 == 4) ||
                          (cycle_count % 31 == 9));
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (held_valid) begin
                if (!out_valid || out_pixel_idx !== held_pixel ||
                    out_channel_base !== held_cout || out_row_idx !== held_row ||
                    out_beat_idx !== held_beat || out_lane_mask !== held_mask ||
                    out_data !== held_data) begin
                    $display("FAIL unstable stalled output");
                    errors = errors + 1;
                end
                if (out_ready)
                    held_valid = 1'b0;
            end
            if (out_valid && !out_ready) begin
                held_valid = 1'b1;
                held_pixel = out_pixel_idx; held_cout = out_channel_base;
                held_row = out_row_idx; held_beat = out_beat_idx;
                held_mask = out_lane_mask; held_data = out_data;
            end
            if (out_valid && out_ready) begin
                if (output_count >= expected_count) begin
                    $display("FAIL unexpected output count=%0d", output_count);
                    errors = errors + 1;
                end else begin
                    if (out_pixel_idx !== exp_pixel[output_count] ||
                        out_channel_base !== exp_cout[output_count] ||
                        out_row_idx !== exp_row[output_count] ||
                        out_beat_idx !== exp_beat[output_count] ||
                        out_lane_mask !== exp_mask[output_count]) begin
                        $display("FAIL TAG n=%0d got p=%0d c=%0d r=%0d b=%0d m=%b exp p=%0d c=%0d r=%0d b=%0d m=%b",
                                 output_count, out_pixel_idx, out_channel_base,
                                 out_row_idx, out_beat_idx, out_lane_mask,
                                 exp_pixel[output_count], exp_cout[output_count],
                                 exp_row[output_count], exp_beat[output_count],
                                 exp_mask[output_count]);
                        errors = errors + 1;
                    end
                    if ((out_lane_mask[0] &&
                         out_data[7:0] !== exp_data[output_count][7:0]) ||
                        (out_lane_mask[1] &&
                         out_data[15:8] !== exp_data[output_count][15:8])) begin
                        $display("FAIL DATA n=%0d got=%h exp=%h mask=%b",
                                 output_count, out_data,
                                 exp_data[output_count], out_lane_mask);
                        errors = errors + 1;
                    end
                end
                output_count = output_count + 1;
            end
        end
    end

    initial begin
        dw_acquire_valid = 0; dw_acquire_bank = 0;
        dw_acquire_session = 0; dw_acquire_epoch = 0; dw_acquire_group_count = 0;
        dw_write_valid = 0; dw_write_bank = 0; dw_write_half = 0;
        dw_write_group = 0; dw_write_data = 0; dw_write_lane_mask = 0;
        dw_commit_valid = 0; dw_commit_bank = 0;
        dw_commit_session = 0; dw_commit_epoch = 0;
        pw_weight_wr_en = 0; pw_weight_wr_idx = 0; pw_weight_wr_data = 0;
        job_valid = 0; job_bank = 0; job_session = 0; job_epoch = 0;
        job_group_count = 0; job_reverse_groups = 0; job_pixel_base = 0;
        job_cout_base = 0; job_output_pixels = 0; job_output_channels = 0;
        job_bias_vec = 0; job_multiplier_vec = 0; job_shift_vec = 0;
        job_output_zero_point_int32 = 0; job_activation_min_int32 = 0;
        job_activation_max_int32 = 0; out_ready = 1; held_valid = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        /* Retained zero-weight smoke. */
        job_pixel_base = 0; job_cout_base = 0;
        job_output_pixels = 1; job_output_channels = 8;
        run_job(0, 0, 1, 1, 8, 1, 8, 0, 0, 0, 0);
        $display("PASS retained zero-weight smoke outputs=%0d", output_count);

        /* Cin=16, full spatial block and the Cout=13 channel tail. */
        job_pixel_base = 0; job_cout_base = 0;
        job_output_pixels = 17; job_output_channels = 13;
        run_job(1, 1, 2, 1, 16, 17, 13, 0, 0, 0, 1);

        /* Cin=48, P17 one-pixel tail and Cout13 five-channel tail. */
        job_pixel_base = 16; job_cout_base = 8;
        job_output_pixels = 17; job_output_channels = 13;
        run_job(2, 0, 3, 2, 48, 17, 13, 16, 8, 1, 1);

        /* Reuse the first bank with new session/epoch and a different tail. */
        job_pixel_base = 8; job_cout_base = 8;
        job_output_pixels = 17; job_output_channels = 13;
        run_job(3, 1, 0, 3, 16, 17, 13, 8, 8, 1, 1);

        if (errors != 0) begin
            $display("FAIL consumer differential errors=%0d", errors);
            $fatal(1);
        end
        $display("PASS pair_rowbank_consumer differential jobs=4 outputs/job=%0d cycles=%0d",
                 MAX_OUT, cycle_count);
        $finish;
    end
endmodule

`default_nettype wire
