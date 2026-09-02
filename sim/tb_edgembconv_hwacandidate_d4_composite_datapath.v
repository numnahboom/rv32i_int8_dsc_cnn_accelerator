`timescale 1ns/1ps
`default_nettype none

/*
 * Small vector contract for the physical D4 composition.  The PW case uses
 * three K tokens and checks all 128 output lanes (112 dedicated + 16 pool).
 * The RQ case consumes the existing generated D4 coefficient/shift vector.
 * The DW cases use a synchronous one-cycle source model and exercise both
 * stride values, source backpressure, output backpressure, and mode fencing.
 */
module tb_edgembconv_hwacandidate_d4_composite_datapath;
    reg clk, rst_n;
    reg op_mode_rq, op_valid;
    wire op_ready;
    reg [55:0] pw_act_7pixel_vec;
    reg [127:0] pw_act_pool_vec, pw_wgt_vec;
    reg [7:0] pw_pixel_mask;
    reg [15:0] pw_cout_mask;
    reg pw_first_k, pw_last_k;
    reg [7:0] pw_k_idx;
    reg signed [127:0] rq_acc_vec, rq_multiplier_vec;
    reg [23:0] rq_shift_vec;
    reg signed [127:0] rq_zero_point_vec, rq_min_vec, rq_max_vec;
    reg [31:0] metadata_in;
    reg out_ready;
    wire out_valid, out_mode_rq;
    wire signed [4095:0] pw_psum_vec;
    wire [127:0] pw_lane_mask;
    wire signed [255:0] rq_product_vec;
    wire signed [31:0] rq_result_vec;
    wire [31:0] metadata_out;

    reg dw_cfg_valid;
    wire dw_cfg_ready;
    reg [7:0] dw_cfg_addr;
    reg signed [7:0] dw_cfg_data;
    reg dw_start_valid;
    wire dw_start_ready;
    reg [7:0] dw_in_w, dw_in_h, dw_out_x, dw_out_y;
    reg [1:0] dw_stride;
    reg [31:0] dw_metadata_in;
    wire dw_src_req_valid;
    reg dw_src_req_ready;
    wire [31:0] dw_src_req_addr;
    reg dw_src_resp_valid;
    wire dw_src_resp_ready;
    reg [127:0] dw_src_resp_data;
    reg dw_out_ready;
    wire dw_out_valid;
    wire signed [511:0] dw_raw_psum_vec;
    wire [31:0] dw_metadata_out;
    wire dw_done;

    edgembconv_hwacandidate_d4_composite_datapath dut (
        .clk(clk), .rst_n(rst_n), .op_mode_rq(op_mode_rq),
        .op_valid(op_valid), .op_ready(op_ready),
        .pw_act_7pixel_vec(pw_act_7pixel_vec),
        .pw_act_pool_vec(pw_act_pool_vec), .pw_wgt_vec(pw_wgt_vec),
        .pw_pixel_mask(pw_pixel_mask), .pw_cout_mask(pw_cout_mask),
        .pw_first_k(pw_first_k), .pw_last_k(pw_last_k), .pw_k_idx(pw_k_idx),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .metadata_in(metadata_in), .out_ready(out_ready),
        .out_valid(out_valid), .out_mode_rq(out_mode_rq),
        .pw_psum_vec(pw_psum_vec), .pw_lane_mask(pw_lane_mask),
        .rq_product_vec(rq_product_vec), .rq_result_vec(rq_result_vec),
        .metadata_out(metadata_out), .dw_cfg_valid(dw_cfg_valid),
        .dw_cfg_ready(dw_cfg_ready), .dw_cfg_addr(dw_cfg_addr),
        .dw_cfg_data(dw_cfg_data), .dw_start_valid(dw_start_valid),
        .dw_start_ready(dw_start_ready), .dw_in_w(dw_in_w),
        .dw_in_h(dw_in_h), .dw_out_x(dw_out_x), .dw_out_y(dw_out_y),
        .dw_stride(dw_stride), .dw_metadata_in(dw_metadata_in),
        .dw_src_req_valid(dw_src_req_valid),
        .dw_src_req_ready(dw_src_req_ready),
        .dw_src_req_addr(dw_src_req_addr),
        .dw_src_resp_valid(dw_src_resp_valid),
        .dw_src_resp_ready(dw_src_resp_ready),
        .dw_src_resp_data(dw_src_resp_data), .dw_out_ready(dw_out_ready),
        .dw_out_valid(dw_out_valid), .dw_raw_psum_vec(dw_raw_psum_vec),
        .dw_metadata_out(dw_metadata_out), .dw_done(dw_done)
    );

    reg signed [7:0] source_mem [0:255];
    reg signed [7:0] dw_weight_mem [0:143];
    reg [127:0] rq_acc_mem [0:4];
    reg [127:0] rq_multiplier_mem [0:4];
    reg [23:0] rq_shift_mem [0:4];
    reg [127:0] rq_zp_mem [0:4];
    reg [127:0] rq_min_mem [0:4];
    reg [127:0] rq_max_mem [0:4];
    reg [255:0] rq_product_mem [0:4];
    reg [31:0] rq_expected_mem [0:4];
    reg [127:0] pw_act_mem [0:2];
    reg [127:0] pw_wgt_mem [0:2];

    reg source_pending;
    reg [31:0] source_pending_addr;
    integer cycle_counter, errors, i, k, p, c, t, addr_i;
    integer input_x_i, input_y_i, dw_start_cycle, dw_finish_cycle;
    integer signed expected_pw [0:127];
    integer signed expected_dw [0:15];
    integer signed source_value, weight_value;
    integer signed got_value;
    reg [31:0] source_prng;
    reg [4095:0] held_pw;
    reg [127:0] held_rq_product;
    reg [31:0] held_rq_result;
    reg [511:0] held_dw;

    always #5 clk = ~clk;
    always @(posedge clk) cycle_counter = cycle_counter + 1;

    function [127:0] source_word;
        input [31:0] base;
        integer si;
        begin
            source_word = 128'd0;
            for (si = 0; si < 16; si = si + 1)
                source_word[(si*8) +: 8] = source_mem[base + si];
        end
    endfunction

    /* Registered response model: request is accepted on one edge, the word
     * is visible on a later edge and remains valid until the DUT accepts it. */
    always @(posedge clk) begin
        if (!rst_n) begin
            source_pending <= 1'b0;
            source_pending_addr <= 0;
            dw_src_resp_valid <= 1'b0;
            dw_src_resp_data <= 0;
        end else begin
            dw_src_resp_valid <= source_pending;
            if (source_pending)
                dw_src_resp_data <= source_word(source_pending_addr);
            source_pending <= dw_src_req_valid && dw_src_req_ready;
            if (dw_src_req_valid && dw_src_req_ready) begin
                source_pending_addr <= dw_src_req_addr;
            end
        end
    end

    /* Deterministic source stalls. */
    always @* begin
        dw_src_req_ready = (cycle_counter % 4) != 1;
    end

    initial begin
        #100000;
        $display("TIMEOUT composite TB cycle=%0d op_ready=%b out_valid=%b dw_req=%b dw_resp=%b",
                 cycle_counter, op_ready, out_valid, dw_src_req_valid,
                 dw_src_resp_valid);
        $fatal;
    end

    task clear_op_inputs;
        begin
            op_valid = 1'b0; op_mode_rq = 1'b0;
            pw_act_7pixel_vec = 0; pw_act_pool_vec = 0; pw_wgt_vec = 0;
            pw_pixel_mask = 0; pw_cout_mask = 0;
            pw_first_k = 0; pw_last_k = 0; pw_k_idx = 0;
            rq_acc_vec = 0; rq_multiplier_vec = 0; rq_shift_vec = 0;
            rq_zero_point_vec = 0; rq_min_vec = 0; rq_max_vec = 0;
            metadata_in = 0;
        end
    endtask

    task send_pw_token;
        input integer token;
        begin
            @(negedge clk);
            op_mode_rq = 1'b0; op_valid = 1'b1;
            pw_act_7pixel_vec = pw_act_mem[token][55:0];
            pw_act_pool_vec = 128'd0;
            for (c = 0; c < 16; c = c + 1)
                pw_act_pool_vec[c*8 +: 8] = pw_act_mem[token][(7*8) +: 8];
            pw_wgt_vec = pw_wgt_mem[token];
            pw_pixel_mask = 8'hff; pw_cout_mask = 16'hffff;
            pw_first_k = (token == 0); pw_last_k = (token == 2);
            pw_k_idx = token; metadata_in = 32'hd4000000 + token;
            while (!op_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk); op_valid = 1'b0; pw_first_k = 0; pw_last_k = 0;
        end
    endtask

    task check_pw;
        begin
            out_ready = 1'b0;
            while (!out_valid) @(negedge clk);
            held_pw = pw_psum_vec;
            repeat (3) begin
                @(posedge clk); #1;
                if (!out_valid || out_mode_rq || pw_psum_vec !== held_pw)
                    errors = errors + 1;
            end
            @(negedge clk); out_ready = 1'b1;
            @(posedge clk); #1;
            if (out_mode_rq || metadata_out !== 32'hd4000002)
                errors = errors + 1;
            for (i = 0; i < 128; i = i + 1) begin
                got_value = $signed(pw_psum_vec[(i*32) +: 32]);
                if (got_value !== expected_pw[i]) begin
                    $display("PW_MISMATCH lane=%0d got=%0d exp=%0d", i,
                             got_value, expected_pw[i]);
                    errors = errors + 1;
                end
            end
            if (pw_lane_mask !== 128'hffffffffffffffffffffffffffffffff)
                errors = errors + 1;
        end
    endtask

    task send_rq;
        input integer n;
        begin
            @(negedge clk);
            op_mode_rq = 1'b1; op_valid = 1'b1;
            rq_acc_vec = rq_acc_mem[n]; rq_multiplier_vec = rq_multiplier_mem[n];
            rq_shift_vec = rq_shift_mem[n]; rq_zero_point_vec = rq_zp_mem[n];
            rq_min_vec = rq_min_mem[n]; rq_max_vec = rq_max_mem[n];
            metadata_in = 32'hd4a40000 + n;
            while (!op_ready) @(negedge clk);
            @(posedge clk); @(negedge clk); op_valid = 1'b0;
            out_ready = 1'b0;
            while (!out_valid) @(negedge clk);
            held_rq_product = rq_product_vec[127:0];
            held_rq_result = rq_result_vec;
            repeat (2) begin
                @(posedge clk); #1;
                if (!out_valid || !out_mode_rq || rq_product_vec[127:0] !== held_rq_product ||
                    rq_result_vec !== held_rq_result)
                    errors = errors + 1;
            end
            if (rq_product_vec !== rq_product_mem[n] ||
                rq_result_vec !== rq_expected_mem[n] ||
                metadata_out !== (32'hd4a40000 + n)) begin
                $display("RQ_MISMATCH n=%0d product=%h/%h result=%h/%h", n,
                         rq_product_vec, rq_product_mem[n], rq_result_vec,
                         rq_expected_mem[n]);
                errors = errors + 1;
            end
            @(negedge clk); out_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task load_dw_weights;
        begin
            for (i = 0; i < 144; i = i + 1) begin
                @(negedge clk); dw_cfg_valid = 1'b1; dw_cfg_addr = i;
                dw_cfg_data = dw_weight_mem[i];
                while (!dw_cfg_ready) @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk); dw_cfg_valid = 1'b0; dw_cfg_addr = 0; dw_cfg_data = 0;
        end
    endtask

    task run_dw;
        input integer out_x_i;
        input integer out_y_i;
        input integer stride_i;
        input integer tag_i;
        begin
            for (i = 0; i < 16; i = i + 1) expected_dw[i] = 0;
            for (t = 0; t < 9; t = t + 1) begin
                if (t < 3) begin p = 0; c = t; end
                else if (t < 6) begin p = 1; c = t - 3; end
                else begin p = 2; c = t - 6; end
                input_x_i = out_x_i*stride_i + c - 1;
                input_y_i = out_y_i*stride_i + p - 1;
                if (input_x_i >= 0 && input_x_i < 8 &&
                    input_y_i >= 0 && input_y_i < 8)
                    addr_i = input_y_i * 8 + input_x_i;
                else
                    addr_i = -1;
                for (i = 0; i < 16; i = i + 1)
                    if (addr_i >= 0)
                        expected_dw[i] = expected_dw[i] +
                            source_mem[addr_i+i] * dw_weight_mem[i*9+t];
            end
            @(negedge clk);
            dw_start_valid = 1'b1; dw_in_w = 8; dw_in_h = 8;
            dw_out_x = out_x_i; dw_out_y = out_y_i; dw_stride = stride_i;
            dw_metadata_in = 32'hd4d00000 + tag_i;
            while (!dw_start_ready) @(negedge clk);
            @(posedge clk); dw_start_valid = 1'b0;
            dw_start_cycle = cycle_counter;
            dw_out_ready = 1'b0;
            while (!dw_out_valid) @(negedge clk);
            held_dw = dw_raw_psum_vec;
            repeat (3) begin
                @(posedge clk); #1;
                if (!dw_out_valid || dw_raw_psum_vec !== held_dw)
                    errors = errors + 1;
            end
            for (i = 0; i < 16; i = i + 1) begin
                got_value = $signed(dw_raw_psum_vec[(i*32) +: 32]);
                if (got_value !== expected_dw[i]) begin
                    $display("DW_MISMATCH stride=%0d ch=%0d got=%0d exp=%0d",
                             stride_i, i, got_value, expected_dw[i]);
                    errors = errors + 1;
                end
            end
            if (dw_metadata_out !== (32'hd4d00000 + tag_i)) begin
                $display("DW_METADATA_MISMATCH stride=%0d got=%h exp=%h", stride_i,
                         dw_metadata_out, (32'hd4d00000 + tag_i));
                errors = errors + 1;
            end
            @(negedge clk); dw_out_ready = 1'b1;
            @(posedge clk); #1;
            dw_finish_cycle = cycle_counter;
            $display("D4_COMPOSITE_DW stride=%0d out=(%0d,%0d) cycles=%0d",
                     stride_i, out_x_i, out_y_i,
                     dw_finish_cycle - dw_start_cycle);
            if (!dw_done) begin
                $display("DW_DONE_MISSING stride=%0d cycle=%0d", stride_i, cycle_counter);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_acc.mem", rq_acc_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_multiplier.mem", rq_multiplier_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_shift.mem", rq_shift_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_zero_point.mem", rq_zp_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_minimum.mem", rq_min_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_maximum.mem", rq_max_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_product.mem", rq_product_mem);
        $readmemh("build/edgembconv_hwacandidate_d4_dsp_pool_vectors/d4_dsp_pool_rq_expected.mem", rq_expected_mem);
        clk = 0; rst_n = 0; errors = 0; cycle_counter = 0; out_ready = 1;
        dw_cfg_valid = 0; dw_start_valid = 0; dw_out_ready = 1;
        dw_src_resp_valid = 0; dw_src_resp_data = 0; source_prng = 32'hd4c0ffee;
        clear_op_inputs();
        for (i = 0; i < 256; i = i + 1) source_mem[i] = (i % 29) - 14;
        for (i = 0; i < 144; i = i + 1) dw_weight_mem[i] = (i % 11) - 5;
        for (i = 0; i < 3; i = i + 1) begin
            pw_act_mem[i] = 0; pw_wgt_mem[i] = 0;
            for (p = 0; p < 8; p = p + 1)
                pw_act_mem[i][p*8 +: 8] = (i + 1) * (p + 1) - 9;
            for (c = 0; c < 16; c = c + 1)
                pw_wgt_mem[i][c*8 +: 8] = (c - 7) + i;
        end
        for (p = 0; p < 8; p = p + 1)
            for (c = 0; c < 16; c = c + 1) begin
                expected_pw[p*16+c] = 0;
                for (k = 0; k < 3; k = k + 1)
                    expected_pw[p*16+c] = expected_pw[p*16+c] +
                        $signed(pw_act_mem[k][p*8 +: 8]) *
                        $signed(pw_wgt_mem[k][c*8 +: 8]);
            end
        repeat (3) @(posedge clk); rst_n = 1;
        send_pw_token(0); send_pw_token(1); send_pw_token(2); check_pw();
        /* Immediate mode attempt while PW output is held must not be
         * accepted; the mode lock is checked before the RQ vector. */
        send_rq(0);
        load_dw_weights();
        run_dw(3, 3, 1, 0);
        run_dw(2, 2, 2, 1);
        run_dw(0, 0, 1, 2);
        run_dw(0, 0, 2, 3);
        if (errors == 0)
            $display("PASS edgembconv_hwacandidate_d4_composite_datapath mapping=112PW+16dual+18DW stalls=checked");
        else begin
            $display("FAIL edgembconv_hwacandidate_d4_composite_datapath errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule
`default_nettype wire
