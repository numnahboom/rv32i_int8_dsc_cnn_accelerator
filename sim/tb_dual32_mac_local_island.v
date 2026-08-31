`timescale 1ns/1ps
`default_nettype none

/* Independent reference/traffic harness for dual32_mac_local_island. */
module tb_dual32_mac_local_island;
    localparam [1:0] PW = 2'd0, STEM = 2'd1, DW = 2'd2;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] mode_i;
    reg cfg_valid_i, cfg_island_i;
    reg [5:0] cfg_lane_i;
    reg signed [31:0] cfg_bias_i, cfg_multiplier_i;
    reg [5:0] cfg_shift_i;
    wire cfg_ready_o;
    reg valid_in, first_k, last_k;
    reg [7:0] k_idx, block_tag_i, pixel_base_i, pixel_mask_i;
    reg [8:0] cout_base_i;
    reg [15:0] cout_mask_i;
    reg signed [31:0] output_zero_point_i, activation_min_i, activation_max_i;
    reg [31:0] src_word0_i, src_word1_i;
    reg [31:0] param_word0_i, param_word1_i, param_word2_i, param_word3_i;
    wire ready_in;
    wire valid_out, busy_o;
    reg ready_out;
    wire [31:0] out_word;
    wire [3:0] out_word_mask;
    wire [7:0] out_pixel_idx, out_block_tag;
    wire [8:0] out_channel_base;
    wire [2:0] out_group_idx;
    wire [1:0] out_mode;

    dual32_mac_local_island dut (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_valid_i), .cfg_ready_o(cfg_ready_o),
        .cfg_island_i(cfg_island_i), .cfg_lane_i(cfg_lane_i),
        .cfg_bias_i(cfg_bias_i), .cfg_multiplier_i(cfg_multiplier_i),
        .cfg_shift_i(cfg_shift_i), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
        .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i),
        .cout_mask_i(cout_mask_i),
        .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i),
        .activation_max_i(activation_max_i), .src_word0_i(src_word0_i),
        .src_word1_i(src_word1_i), .param_word0_i(param_word0_i),
        .param_word1_i(param_word1_i), .param_word2_i(param_word2_i),
        .param_word3_i(param_word3_i), .valid_out(valid_out),
        .ready_out(ready_out), .out_word(out_word),
        .out_word_mask(out_word_mask), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_group_idx(out_group_idx),
        .out_block_tag(out_block_tag), .out_mode(out_mode), .busy_o(busy_o)
    );

    integer errors = 0;
    integer exp_count = 0, exp_ptr = 0;
    reg [31:0] exp_word [0:4095];
    reg [3:0] exp_mask [0:4095];
    reg [7:0] exp_pixel [0:4095], exp_tag [0:4095];
    reg [8:0] exp_channel [0:4095];
    reg [1:0] exp_mode [0:4095];
    integer sim_cycle = 0, in_stall = 0, in_bubble = 0, out_stall = 0;
    integer source_words = 0, param_words = 0, commit_words = 0;
    integer reference_checks = 0;
    integer mac_valid_ops = 0, mac_capacity_ops = 0;
    integer case_start_cycle, case_start_in_stall, case_start_out_stall;
    integer case_start_source, case_start_param, case_start_commit;
    integer case_start_bubble, case_start_mac_valid, case_start_mac_capacity;
    integer case_start_reference_checks;

    always @(negedge clk) begin
        if (rst_n) begin
            sim_cycle = sim_cycle + 1;
`ifdef DUAL32_NO_BACKPRESSURE
            ready_out <= 1'b1;
`else
            ready_out <= ((sim_cycle % 11) != 4) && ((sim_cycle % 7) != 2);
`endif
        end else begin
            ready_out <= 1'b0;
        end
    end

    /* Observe accepted 4-byte commits after the DUT's nonblocking updates. */
    always @(posedge clk) begin
        if (rst_n) begin
            if (valid_out && !ready_out) out_stall = out_stall + 1;
            if (valid_out && ready_out) begin
                commit_words = commit_words + 1;
                reference_checks = reference_checks + count4(out_word_mask);
                if (exp_ptr >= exp_count) begin
                    $display("FAIL unexpected commit tag=%0d", out_block_tag);
                    errors = errors + 1;
                end else begin
                    if (out_word !== exp_word[exp_ptr] ||
                        out_word_mask !== exp_mask[exp_ptr] ||
                        out_pixel_idx !== exp_pixel[exp_ptr] ||
                        out_channel_base !== exp_channel[exp_ptr] ||
                        out_block_tag !== exp_tag[exp_ptr] ||
                        out_mode !== exp_mode[exp_ptr]) begin
                        $display("FAIL commit=%0d got word=%h mask=%h p=%0d c=%0d tag=%0d mode=%0d expected word=%h mask=%h p=%0d c=%0d tag=%0d mode=%0d",
                                 exp_ptr, out_word, out_word_mask, out_pixel_idx,
                                 out_channel_base, out_block_tag, out_mode,
                                 exp_word[exp_ptr], exp_mask[exp_ptr],
                                 exp_pixel[exp_ptr], exp_channel[exp_ptr],
                                 exp_tag[exp_ptr], exp_mode[exp_ptr]);
                        errors = errors + 1;
                    end
                    exp_ptr = exp_ptr + 1;
                end
            end
            #1;
        end
    end

    function [7:0] ref_quant;
        input signed [31:0] acc_in, bias_in, mult_in;
        input [5:0] shift_in;
        input signed [31:0] zp_in, min_in, max_in;
        reg signed [127:0] aa, mm, pp, fixed, shifted, added;
        reg [30:0] low_bits;
        reg neg, low_zero, round_up;
        begin
            aa = acc_in + bias_in; mm = mult_in; pp = aa * mm;
            low_bits = pp[30:0]; low_zero = (low_bits == 0); neg = pp[127];
            if (!neg) begin
                round_up = (low_bits >= 31'h40000000);
                fixed = (pp >>> 31) + (round_up ? 1 : 0);
            end else begin
                round_up = pp[30] ? (low_zero || (pp[29:0] == 0)) : !low_zero;
                if (low_zero && round_up) fixed = (pp >>> 31) - 1;
                else if (low_zero || round_up) fixed = (pp >>> 31);
                else fixed = (pp >>> 31) + 1;
            end
            shifted = fixed >>> shift_in; added = shifted + zp_in;
            if (added > 127) ref_quant = 8'h7f;
            else if (added < -128) ref_quant = 8'h80;
            else if (added < min_in) ref_quant = min_in[7:0];
            else if (added > max_in) ref_quant = max_in[7:0];
            else ref_quant = added[7:0];
        end
    endfunction

    function integer count8;
        input [7:0] x;
        integer j;
        begin count8 = 0; for (j=0;j<8;j=j+1) count8 = count8 + x[j]; end
    endfunction
    function integer count4;
        input [3:0] x;
        integer j;
        begin count4 = 0; for (j=0;j<4;j=j+1) count4 = count4 + x[j]; end
    endfunction
    function integer count16;
        input [15:0] x;
        integer j;
        begin count16 = 0; for (j=0;j<16;j=j+1) count16 = count16 + x[j]; end
    endfunction

    integer case_no;
    integer refs [0:1][0:31];
    integer lane_bias [0:31];
    integer p, c, i, k, isl, g, lane, gc, groups, bubble_once;
    integer actv, wv, base_c;
    reg [31:0] sw0, sw1, pw0, pw1, pw2, pw3;
    reg [7:0] got_byte;
    reg [31:0] src0_hist [0:255], src1_hist [0:255];
    reg [31:0] par0_hist [0:255], par1_hist [0:255];
    reg [31:0] par2_hist [0:255], par3_hist [0:255];
    reg ready_sample;

    task configure;
        begin
            for (isl = 0; isl < 2; isl = isl + 1) begin
                for (i = 0; i < 32; i = i + 1) begin
                    @(negedge clk);
                    cfg_valid_i <= 1'b1; cfg_island_i <= isl[0];
                    cfg_lane_i <= i[5:0]; cfg_bias_i <= 32'sd3 + i;
                    cfg_multiplier_i <= 32'sh40000000; cfg_shift_i <= 0;
                    @(posedge clk); #1;
                    if (!cfg_ready_o) begin
                        /* Hold one more cycle; config is an ordinary narrow
                         * ready/valid stream and this is intentionally tested. */
                        @(negedge clk); @(posedge clk); #1;
                    end
                end
            end
            @(negedge clk); cfg_valid_i <= 1'b0;
        end
    endtask

    task append_expected;
        input [1:0] tmode;
        input [7:0] ttag, tpb, tpmask;
        input [8:0] tcb;
        input [15:0] tcmask;
        begin
            for (isl = 0; isl < 2; isl = isl + 1) begin
                if (tmode == DW && isl == 1) begin end
                else begin
                    for (g = 0; g < 8; g = g + 1) begin
                        exp_word[exp_count] = 0; exp_mask[exp_count] = 0;
                        exp_pixel[exp_count] = tpb; exp_channel[exp_count] = tcb;
                        exp_tag[exp_count] = ttag; exp_mode[exp_count] = tmode;
                        if (tmode == PW) begin
                            p = g; base_c = isl * 4;
                            exp_pixel[exp_count] = tpb + p;
                            exp_channel[exp_count] = tcb + base_c;
                            for (i = 0; i < 4; i = i + 1) begin
                                lane = p*4+i; gc = base_c+i;
                                if (tpmask[p] && tcmask[gc]) begin
                                    exp_mask[exp_count][i] = 1'b1;
                                    exp_word[exp_count][i*8 +: 8] =
                                        ref_quant(refs[isl][lane], lane_bias[lane],
                                                  32'sh40000000, 0, 3, -128, 127);
                                end
                            end
                        end else begin
                            p = g/2; base_c = isl*8 + ((g%2)*4);
                            exp_pixel[exp_count] = tpb + p;
                            exp_channel[exp_count] = tcb + base_c;
                            for (i = 0; i < 4; i = i + 1) begin
                                lane = p*8 + (g%2)*4+i; gc = base_c+i;
                                if ((tmode != DW || isl == 0) && tpmask[p] && tcmask[gc]) begin
                                    exp_mask[exp_count][i] = 1'b1;
                                    exp_word[exp_count][i*8 +: 8] =
                                        ref_quant(refs[isl][lane], lane_bias[lane],
                                                  32'sh40000000, 0, 3, -128, 127);
                                end
                            end
                        end
                        exp_count = exp_count + 1;
                    end
                end
            end
        end
    endtask

    task run_block;
        input [1:0] tmode;
        input integer tk;
        input [7:0] ttag, tpb, tpmask;
        input [8:0] tcb;
        input [15:0] tcmask;
        begin
            mode_i = tmode; block_tag_i = ttag; pixel_base_i = tpb;
            cout_base_i = tcb; pixel_mask_i = tpmask; cout_mask_i = tcmask;
            output_zero_point_i = 3; activation_min_i = -128; activation_max_i = 127;
            for (isl = 0; isl < 2; isl = isl + 1)
                for (i = 0; i < 32; i = i + 1) refs[isl][i] = 0;
            /* First make the complete reference reduction and retain the
             * exact narrow words.  Expected commits are queued before the
             * first input token can reach the output monitor. */
            for (k = 0; k < tk; k = k + 1) begin
                sw0 = 0; sw1 = 0; pw0 = 0; pw1 = 0; pw2 = 0; pw3 = 0;
                for (p = 0; p < 8; p = p + 1) begin
                    actv = ((case_no*17 + k*13 + p*7) % 17) - 8;
                    if (actv == 0) actv = 1;
                    if (p < 4) sw0[p*8 +: 8] = actv[7:0];
                    else sw1[(p-4)*8 +: 8] = actv[7:0];
                end
                for (c = 0; c < 16; c = c + 1) begin
                    wv = ((case_no*19 + k*11 + c*3) % 13) - 6;
                    if (wv == 0) wv = -2;
                    if (c < 4) pw0[c*8 +: 8] = wv[7:0];
                    else if (c < 8) pw1[(c-4)*8 +: 8] = wv[7:0];
                    else if (c < 12) pw2[(c-8)*8 +: 8] = wv[7:0];
                    else pw3[(c-12)*8 +: 8] = wv[7:0];
                end
                /* Build the independent per-island sums. */
                for (isl = 0; isl < 2; isl = isl + 1) begin
                    if (tmode == PW) begin
                        for (p = 0; p < 8; p = p + 1) begin
                            actv = (p < 4) ? $signed(sw0[p*8 +: 8]) : $signed(sw1[(p-4)*8 +: 8]);
                            for (c = 0; c < 4; c = c + 1) begin
                                wv = $signed((isl == 0) ? pw0[c*8 +: 8] : pw1[c*8 +: 8]);
                                refs[isl][p*4+c] = refs[isl][p*4+c] + actv*wv;
                            end
                        end
                    end else begin
                        for (p = 0; p < 4; p = p + 1) begin
                            actv = $signed(sw0[p*8 +: 8]);
                            for (c = 0; c < 8; c = c + 1) begin
                                if (isl == 0)
                                    wv = $signed((c < 4) ? pw0[c*8 +: 8] : pw1[(c-4)*8 +: 8]);
                                else
                                    wv = $signed((c < 4) ? pw2[c*8 +: 8] : pw3[(c-4)*8 +: 8]);
                                refs[isl][p*8+c] = refs[isl][p*8+c] + actv*wv;
                            end
                        end
                    end
                end
                src0_hist[k] = sw0; src1_hist[k] = sw1;
                par0_hist[k] = pw0; par1_hist[k] = pw1;
                par2_hist[k] = pw2; par3_hist[k] = pw3;
            end
            append_expected(tmode,ttag,tpb,tpmask,tcb,tcmask);
            k = 0; bubble_once = 0;
            while (k < tk) begin
                sw0 = src0_hist[k]; sw1 = src1_hist[k];
                pw0 = par0_hist[k]; pw1 = par1_hist[k];
                pw2 = par2_hist[k]; pw3 = par3_hist[k];
                @(negedge clk);
                ready_sample = ready_in;
                if ((k % 9) == 4 && !bubble_once
`ifdef DUAL32_NO_BUBBLES
                    && 1'b0
`endif
                ) begin
                    valid_in <= 1'b0; bubble_once = 1; in_bubble = in_bubble + 1;
                end else begin
                    valid_in <= 1'b1; bubble_once = 0;
                end
                first_k <= (k == 0); last_k <= (k == tk-1);
                k_idx <= k[7:0];
                src_word0_i <= sw0; src_word1_i <= sw1;
                param_word0_i <= pw0; param_word1_i <= pw1;
                param_word2_i <= pw2; param_word3_i <= pw3;
                @(posedge clk); #1;
                if (valid_in && ready_sample) begin
                    source_words = source_words + ((tmode == PW) ? 2 : 1);
                    /* PW has two 32-bit parameter words (one per island),
                     * STEM has four (two per island), and DW uses only the
                     * two words consumed by island 0. */
                    param_words = param_words + ((tmode == PW) ? 2 :
                                                 (tmode == STEM) ? 4 : 2);
                    if (tmode == PW) begin
                        mac_valid_ops = mac_valid_ops + count8(tpmask) * count16(tcmask);
                        mac_capacity_ops = mac_capacity_ops + 64;
                    end else if (tmode == STEM) begin
                        mac_valid_ops = mac_valid_ops + count8(tpmask & 8'h0f) * count16(tcmask);
                        mac_capacity_ops = mac_capacity_ops + 64;
                    end else begin
                        mac_valid_ops = mac_valid_ops + count8(tpmask & 8'h0f) * count8(tcmask[7:0]);
                        mac_capacity_ops = mac_capacity_ops + 32;
                    end
                    k = k + 1;
                end else if (valid_in && !ready_in) begin
                    in_stall = in_stall + 1;
                end
            end
            @(negedge clk); valid_in <= 1'b0; first_k <= 0; last_k <= 0;
            while (busy_o) begin @(posedge clk); #1; end
        end
    endtask

    task report_case;
        input [255:0] name;
        begin
            $display("CASE %-28s cycles=%0d source_words=%0d param_words=%0d commits=%0d ref_checks=%0d in_stall=%0d in_bubble=%0d out_stall=%0d mac_valid=%0d mac_capacity=%0d",
                     name, sim_cycle-case_start_cycle,
                     source_words-case_start_source, param_words-case_start_param,
                     commit_words-case_start_commit,
                     reference_checks-case_start_reference_checks,
                     in_stall-case_start_in_stall,
                     in_bubble-case_start_bubble,
                     out_stall-case_start_out_stall,
                     mac_valid_ops-case_start_mac_valid,
                     mac_capacity_ops-case_start_mac_capacity);
        end
    endtask

    task start_case;
        begin
            case_start_cycle = sim_cycle; case_start_in_stall = in_stall;
            case_start_out_stall = out_stall; case_start_source = source_words;
            case_start_param = param_words; case_start_commit = commit_words;
            case_start_bubble = in_bubble;
            case_start_mac_valid = mac_valid_ops;
            case_start_mac_capacity = mac_capacity_ops;
            case_start_reference_checks = reference_checks;
        end
    endtask

    initial begin
        mode_i=PW; cfg_valid_i=0; cfg_island_i=0; cfg_lane_i=0; cfg_bias_i=0;
        cfg_multiplier_i=0; cfg_shift_i=0; valid_in=0; first_k=0; last_k=0;
        k_idx=0; block_tag_i=0; pixel_base_i=0; cout_base_i=0; pixel_mask_i=0;
        cout_mask_i=0; output_zero_point_i=3; activation_min_i=-128;
        activation_max_i=127; src_word0_i=0; src_word1_i=0; param_word0_i=0;
        param_word1_i=0; param_word2_i=0; param_word3_i=0; ready_out=0;
        for (i = 0; i < 32; i = i + 1) lane_bias[i] = 3+i;
        fork
            begin #2000000; $display("WATCHDOG busy=%b valid=%b ready=%b exp=%0d/%0d i0stage=%b i0last=%b i0blk=%b i0drain=%b i1stage=%b i1last=%b i1blk=%b i1drain=%b",busy_o,valid_out,ready_in,exp_ptr,exp_count,dut.u_island0.stage_valid,dut.u_island0.stage_last,dut.u_island0.block_active,dut.u_island0.drain_active,dut.u_island1.stage_valid,dut.u_island1.stage_last,dut.u_island1.block_active,dut.u_island1.drain_active); $finish; end
        join_none
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        configure();

        case_no=1; start_case(); run_block(STEM,3,1,0,8'h0f,0,16'hffff); report_case("STEM_32x32x3_to16");
        case_no=2; start_case(); run_block(PW,16,2,0,8'hff,0,16'h00ff); report_case("PW_DS1_Cin16");
        case_no=3; start_case(); run_block(PW,128,3,0,8'hff,0,16'h00ff); report_case("PW_DS6_Cin128");
        case_no=4; start_case(); run_block(DW,9,4,0,8'h0f,0,16'h00ff); report_case("DW_Cin128_stride2");
        case_no=5;
        /* P=17/Cout=13: six narrow blocks, including both pixel and channel tails. */
        start_case();
        run_block(PW,16,10,0,8'hff,0,16'h00ff);
        run_block(PW,16,11,0,8'hff,8,16'h001f);
        run_block(PW,16,12,8,8'hff,0,16'h00ff);
        run_block(PW,16,13,8,8'hff,8,16'h001f);
        run_block(PW,16,14,16,8'h01,0,16'h00ff);
        run_block(PW,16,15,16,8'h01,8,16'h001f);
        report_case("PW_P17_C13_tails");

        if (exp_ptr != exp_count) begin
            $display("FAIL missing commits got=%0d expected=%0d", exp_ptr, exp_count);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS dual32_local_island commits=%0d cycles=%0d source_words=%0d param_words=%0d", commit_words, sim_cycle, source_words, param_words);
        else $display("FAIL dual32_local_island errors=%0d commits=%0d expected=%0d", errors, commit_words, exp_count);
        $finish;
    end
endmodule
`default_nettype wire
