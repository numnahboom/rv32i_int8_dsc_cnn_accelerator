`timescale 1ns/1ps
`default_nettype none

/* Full 32x32 Stem proof for stem_unified64_streaming.  The scoreboard is
 * independent of the four-pixel/16-channel implementation and checks every
 * one of the 16,384 requantized outputs.  The memory model deliberately
 * exposes only 32-bit words and inserts request/response bubbles. */
module tb_stem_unified64_streaming;
`ifdef USE_SHARED_ARRAY
    localparam integer TEST_SHARED_ARRAY = 1;
`else
    localparam integer TEST_SHARED_ARRAY = 0;
`endif
`ifdef TEST_SCALAR_INPUT
    localparam integer TEST_PACKED_INPUT = 0;
`else
    localparam integer TEST_PACKED_INPUT = 1;
`endif
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg cfg_valid = 0;
    wire cfg_ready;
    reg [1:0] cfg_target;
    reg [8:0] cfg_index;
    reg [31:0] cfg_data;
    reg start = 0;
    reg [31:0] source_base_addr;
    reg signed [7:0] input_zero_point;
    reg signed [31:0] output_zero_point;
    reg signed [31:0] activation_min, activation_max;
    reg [3:0] start_epoch;
    wire busy, done, error;
    wire mem_req_valid;
    reg mem_req_ready = 0;
    wire [31:0] mem_req_addr;
    reg mem_resp_valid = 0;
    wire mem_resp_ready;
    reg [31:0] mem_resp_data = 0;
    wire out_wr_valid;
    reg out_wr_ready = 0;
    wire [9:0] out_wr_pixel_idx;
    wire [3:0] out_wr_channel_base;
    wire [31:0] out_wr_data;
    wire [3:0] out_wr_byte_en;
    wire [3:0] out_wr_epoch;
    wire [31:0] metric_cycles, metric_source_req_count,
                metric_source_resp_count, metric_output_commit_count,
                metric_token_count, metric_mac_count,
                metric_compute_cycles, metric_config_writes;
    wire shared_valid_in, shared_ready_in;
    wire shared_first_k, shared_last_k;
    wire [7:0] shared_k_idx;
    wire signed [63:0] shared_act_vec;
    wire signed [127:0] shared_wgt_vec16;
    wire [7:0] shared_pixel_mask;
    wire [15:0] shared_cout_mask;
    wire [10:0] shared_pixel_base;
    wire [8:0] shared_cout_base;
    wire signed [511:0] shared_bias_vec, shared_multiplier_vec;
    wire [95:0] shared_shift_vec;
    wire shared_out_valid, shared_out_ready;
    wire [10:0] shared_out_pixel_idx;
    wire [8:0] shared_out_channel_base;
    wire [3:0] shared_out_lane_mask;
    wire signed [31:0] shared_out_data;

    stem_static_window_banks #(.SHARED_ARRAY(TEST_SHARED_ARRAY),
                               .PACKED_INPUT(TEST_PACKED_INPUT)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_target(cfg_target), .cfg_index(cfg_index), .cfg_data(cfg_data),
        .start(start), .source_base_addr(source_base_addr),
        .input_zero_point(input_zero_point),
        .output_zero_point(output_zero_point),
        .activation_min(activation_min), .activation_max(activation_max),
        .start_epoch(start_epoch), .busy(busy), .done(done), .error(error),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready), .mem_resp_data(mem_resp_data),
        .out_wr_valid(out_wr_valid), .out_wr_ready(out_wr_ready),
        .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_base(out_wr_channel_base),
        .out_wr_data(out_wr_data), .out_wr_byte_en(out_wr_byte_en),
        .out_wr_epoch(out_wr_epoch), .metric_cycles(metric_cycles),
        .metric_source_req_count(metric_source_req_count),
        .metric_source_resp_count(metric_source_resp_count),
        .metric_output_commit_count(metric_output_commit_count),
        .metric_token_count(metric_token_count),
        .metric_mac_count(metric_mac_count),
        .metric_compute_cycles(metric_compute_cycles),
        .metric_config_writes(metric_config_writes),
        .shared_valid_in(shared_valid_in), .shared_ready_in(shared_ready_in),
        .shared_first_k(shared_first_k), .shared_last_k(shared_last_k),
        .shared_k_idx(shared_k_idx), .shared_act_vec(shared_act_vec),
        .shared_wgt_vec16(shared_wgt_vec16), .shared_pixel_mask(shared_pixel_mask),
        .shared_cout_mask(shared_cout_mask), .shared_pixel_base(shared_pixel_base),
        .shared_cout_base(shared_cout_base), .shared_bias_vec(shared_bias_vec),
        .shared_multiplier_vec(shared_multiplier_vec), .shared_shift_vec(shared_shift_vec),
        .shared_out_valid(shared_out_valid), .shared_out_ready(shared_out_ready),
        .shared_out_pixel_idx(shared_out_pixel_idx),
        .shared_out_channel_base(shared_out_channel_base),
        .shared_out_lane_mask(shared_out_lane_mask), .shared_out_data(shared_out_data)
    );

    generate if (TEST_SHARED_ARRAY) begin : gen_shared_array_tb
        unified64_shared_compute_array u_shared_array (
            .clk(clk), .rst_n(rst_n), .mode_stem(1'b1),
            .valid_in(shared_valid_in), .ready_in(shared_ready_in),
            .first_k(shared_first_k), .last_k(shared_last_k), .k_idx(shared_k_idx),
            .act_vec(shared_act_vec), .wgt_vec16(shared_wgt_vec16),
            .pixel_mask(shared_pixel_mask), .cout_mask(shared_cout_mask),
            .pixel_base(shared_pixel_base), .cout_base(shared_cout_base),
            .bias_vec(shared_bias_vec), .multiplier_vec(shared_multiplier_vec),
            .shift_vec(shared_shift_vec),
            .output_zero_point_int32(output_zero_point),
            .activation_min_int32(activation_min), .activation_max_int32(activation_max),
            .ready_out(shared_out_ready), .valid_out(shared_out_valid),
            .out_pixel_idx(shared_out_pixel_idx), .out_channel_base(shared_out_channel_base),
            .out_lane_mask(shared_out_lane_mask), .out_data(shared_out_data),
            .busy(), .metric_token_count(), .metric_masked_mac_count(),
            .metric_commit_count()
        );
    end else begin : gen_no_shared_array_tb
        assign shared_ready_in = 1'b0;
        assign shared_out_valid = 1'b0;
        assign shared_out_pixel_idx = 11'd0;
        assign shared_out_channel_base = 9'd0;
        assign shared_out_lane_mask = 4'd0;
        assign shared_out_data = 32'd0;
    end endgenerate

    integer signed feature [0:3071];
    integer signed weight [0:431];
    integer signed bias [0:15];
    integer signed multiplier [0:15];
    integer unsigned shift_amount [0:15];
    reg [31:0] source_words [0:767];
    reg [31:0] scalar_source_words [0:3071];
    reg signed [7:0] expected [0:1023][0:15];
    reg [31:0] lfsr;
    integer i, y, x, ci, co, kh, kw, k, acc;
    integer src_y, src_x, idx;
    integer errors, writes, run_no, run_cycles;
    integer mem_pending, mem_delay;
    integer mem_word_addr;
    integer req_ready_phase;
    integer output_ready_phase;
    reg [3:0] expected_epoch;

    function integer signed rand8;
        integer v;
        begin
            lfsr = (lfsr << 1) ^ ((lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]) ? 32'h1 : 32'h0);
            v = lfsr[7:0];
            if (v >= 128) v = v - 256;
            rand8 = v;
        end
    endfunction

    function signed [7:0] ref_requant;
        input integer signed acc_in;
        input integer signed co_in;
        reg signed [63:0] xx, pp, mag, rounded;
        reg signed [63:0] mn, mx;
        begin
            xx = acc_in + bias[co_in];
            pp = xx * multiplier[co_in];
            if (pp >= 0)
                xx = (pp + 64'sd1073741824) >>> 31;
            else begin
                mag = -pp;
                rounded = (mag + 64'sd1073741824) >>> 31;
                xx = -rounded;
            end
            xx = xx >>> shift_amount[co_in];
            xx = xx + output_zero_point;
            if (xx > 127) xx = 127;
            else if (xx < -128) xx = -128;
            mn = activation_min;
            mx = activation_max;
            if (xx < mn) xx = mn;
            else if (xx > mx) xx = mx;
            ref_requant = xx[7:0];
        end
    endfunction

    function integer signed ref_acc_at;
        input integer signed pix_in;
        input integer signed co_in;
        integer oy, ox, h, w, c, sy, sx, av;
        begin
            oy = pix_in / 32;
            ox = pix_in % 32;
            ref_acc_at = 0;
            for (h = 0; h < 3; h = h + 1)
                for (w = 0; w < 3; w = w + 1)
                    for (c = 0; c < 3; c = c + 1) begin
                        sy = oy + h - 1;
                        sx = ox + w - 1;
                        if (sy < 0 || sy >= 32 || sx < 0 || sx >= 32)
                            av = input_zero_point;
                        else av = feature[(sy*32+sx)*3+c];
                        ref_acc_at = ref_acc_at + av * weight[co_in*27+h*9+w*3+c];
                    end
        end
    endfunction

    task automatic cfg_write(input [1:0] target, input integer address,
                             input [31:0] data);
        begin
            while (!cfg_ready) @(posedge clk);
            @(negedge clk);
            cfg_target = target;
            cfg_index = address[8:0];
            cfg_data = data;
            cfg_valid = 1'b1;
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task automatic make_vectors;
        integer wi, b, yy, xx, cc, kk;
        integer signed a;
        begin
            lfsr = 32'h1acebeef;
            input_zero_point = -7;
            output_zero_point = 3;
            activation_min = -101;
            activation_max = 93;
            for (i = 0; i < 3072; i = i + 1) feature[i] = rand8();
            for (i = 0; i < 432; i = i + 1) weight[i] = rand8();
            for (i = 0; i < 16; i = i + 1) begin
                bias[i] = rand8() * 13;
                multiplier[i] = (1 << 29) + (rand8() * 1000000);
                if (i[0]) multiplier[i] = -multiplier[i];
                shift_amount[i] = i % 6;
            end
            for (wi = 0; wi < 768; wi = wi + 1) begin
                source_words[wi] = 0;
                for (b = 0; b < 4; b = b + 1)
                    source_words[wi][b*8 +: 8] = feature[wi*4+b][7:0];
            end
            for (wi = 0; wi < 3072; wi = wi + 1) begin
                scalar_source_words[wi] = 0;
                scalar_source_words[wi][7:0] = feature[wi][7:0];
            end
            for (yy = 0; yy < 32; yy = yy + 1) begin
                for (xx = 0; xx < 32; xx = xx + 1) begin
                    for (co = 0; co < 16; co = co + 1) begin
                        acc = 0;
                        for (kh = 0; kh < 3; kh = kh + 1)
                            for (kw = 0; kw < 3; kw = kw + 1)
                                for (ci = 0; ci < 3; ci = ci + 1) begin
                                    src_y = yy + kh - 1;
                                    src_x = xx + kw - 1;
                                    if (src_y < 0 || src_y >= 32 || src_x < 0 || src_x >= 32)
                                        a = input_zero_point;
                                    else
                                        a = feature[(src_y*32+src_x)*3+ci];
                                    acc = acc + a * weight[(co*27)+(kh*9)+(kw*3)+ci];
                                end
                        expected[yy*32+xx][co] = ref_requant(acc, co);
                    end
                end
            end
        end
    endtask

    task automatic configure;
        integer wi;
        begin
            for (wi = 0; wi < 432; wi = wi + 1)
                cfg_write(0, wi, weight[wi] & 32'hff);
            for (wi = 0; wi < 16; wi = wi + 1) begin
                cfg_write(1, wi, bias[wi]);
                cfg_write(2, wi, multiplier[wi]);
                cfg_write(3, wi, shift_amount[wi]);
            end
        end
    endtask

    /* One outstanding 32-bit read.  The response is visible for the whole
     * cycle in which the DUT is waiting, so arbitrary 0..2 cycle latency is
     * exercised without relying on simulator scheduling races. */
    always @(posedge clk) begin
        if (!rst_n) begin
            mem_pending <= 0;
            mem_delay <= 0;
            mem_word_addr <= 0;
            mem_req_ready <= 0;
        end else begin
            req_ready_phase = req_ready_phase + 1;
            mem_req_ready <= ((req_ready_phase % 7) != 0);
            if (mem_req_valid && mem_req_ready) begin
                mem_pending <= 1;
                mem_word_addr <= (mem_req_addr - source_base_addr) >> 2;
                mem_delay <= req_ready_phase % 3;
            end else if (mem_pending && mem_delay != 0) begin
                mem_delay <= mem_delay - 1;
            end else if (mem_pending && mem_resp_ready) begin
                if (run_no == 0 && mem_word_addr == 24)
                    $display("DBG resp24 data=%h src=%h", mem_resp_data, source_words[24]);
                mem_pending <= 0;
            end
        end
    end
    always @* begin
        mem_resp_valid = mem_pending && (mem_delay == 0);
        if (TEST_PACKED_INPUT && mem_word_addr >= 0 && mem_word_addr < 768)
            mem_resp_data = source_words[mem_word_addr];
        else if (!TEST_PACKED_INPUT && mem_word_addr >= 0 && mem_word_addr < 3072)
            mem_resp_data = scalar_source_words[mem_word_addr];
        else mem_resp_data = 32'hdeadbeef;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_wr_ready <= 0;
            output_ready_phase <= 0;
        end else begin
            output_ready_phase <= output_ready_phase + 1;
            out_wr_ready <= ((output_ready_phase % 11) != 0) &&
                            ((output_ready_phase % 17) != 0);
        end
    end

    always @(posedge clk) begin
        if (rst_n && out_wr_valid && out_wr_ready) begin
            if (out_wr_byte_en !== 4'b1111 || out_wr_epoch !== expected_epoch) begin
                $display("FAIL protocol idx=%0d epoch=%0d/%0d be=%b",
                         writes, out_wr_epoch, expected_epoch, out_wr_byte_en);
                errors = errors + 1;
            end
            if (out_wr_pixel_idx >= 1024 || out_wr_channel_base > 12 ||
                out_wr_channel_base[1:0] != 0) begin
                $display("FAIL tag pixel=%0d channel=%0d", out_wr_pixel_idx,
                         out_wr_channel_base);
                errors = errors + 1;
            end else begin
                for (i = 0; i < 4; i = i + 1)
                    if ($signed(out_wr_data[i*8 +: 8]) !==
                        expected[out_wr_pixel_idx][out_wr_channel_base+i]) begin
                        $display("FAIL output run=%0d pixel=%0d ch=%0d got=%0d exp=%0d",
                                 run_no, out_wr_pixel_idx, out_wr_channel_base+i,
                                 $signed(out_wr_data[i*8 +: 8]),
                                 expected[out_wr_pixel_idx][out_wr_channel_base+i]);
                        errors = errors + 1;
                    end
            end
            writes = writes + 1;
        end
    end

    task automatic run_once(input [3:0] ep);
        begin
            expected_epoch = ep;
            writes = 0;
            run_cycles = 0;
            @(negedge clk);
            start_epoch = ep;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (!done && run_cycles < 30000) begin
                @(posedge clk);
                run_cycles = run_cycles + 1;
            end
            if (!done || error || writes != 4096) begin
                $display("FAIL run=%0d done=%b error=%b writes=%0d cycles=%0d req=%0d resp=%0d",
                         run_no, done, error, writes, run_cycles,
                         metric_source_req_count, metric_source_resp_count);
                errors = errors + 1;
            end else if (metric_source_req_count != (TEST_PACKED_INPUT ? 768 : 3072) ||
                         metric_source_resp_count != (TEST_PACKED_INPUT ? 768 : 3072) ||
                         metric_output_commit_count != 4096 ||
                         metric_token_count != 6912 ||
                         metric_mac_count != 442368 ||
                         metric_compute_cycles != 6912) begin
                $display("FAIL metrics cycles=%0d req=%0d resp=%0d commit=%0d token=%0d mac=%0d comp=%0d",
                         metric_cycles, metric_source_req_count,
                         metric_source_resp_count, metric_output_commit_count,
                         metric_token_count, metric_mac_count,
                         metric_compute_cycles);
                errors = errors + 1;
            end else begin
                $display("PASS stem64 run=%0d writes=%0d cycles=%0d req=%0d tokens=%0d mac=%0d compute=%0d",
                         run_no, writes, metric_cycles, metric_source_req_count,
                         metric_token_count, metric_mac_count,
                         metric_compute_cycles);
            end
            run_no = run_no + 1;
            while (busy) @(posedge clk);
        end
    endtask

    initial begin
        source_base_addr = 32'h00001000;
        cfg_target = 0; cfg_index = 0; cfg_data = 0;
        start_epoch = 0; req_ready_phase = 0; output_ready_phase = 0;
        errors = 0; writes = 0; run_no = 0;
        make_vectors();
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        configure();
        run_once(4'h3);
        run_once(4'hc);
        if (errors != 0) begin
            $display("FAIL tb_stem_unified64_streaming errors=%0d", errors);
            $fatal;
        end
        $display("PASS tb_stem_unified64_streaming runs=2 outputs=8192 commits=8192");
        $finish;
    end
endmodule

`default_nettype wire
