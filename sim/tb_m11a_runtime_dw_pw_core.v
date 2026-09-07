`timescale 1ns/1ps
`default_nettype none

module tb_m11a_runtime_dw_pw_core;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer layer_sel;
    integer random_bp;
    integer cfg_words;
    integer input_bytes;
    integer output_bytes;
    integer output_words_expected;
    integer expected_dw_mac, expected_dw_vec, expected_pw_tokens;
    integer expected_pw_mac, expected_out_words;
    integer fd, sink_fd, rc, ly, kd, idx, address, mask, dataw;
    integer sink_layer, sink_word, sink_addr, sink_data, sink_mask;
    integer sink_owner, sink_epoch, sink_context, sink_req_cycle, sink_resp_cycle;
    integer i, j;
    integer cfg_count;
    integer cycles;
    integer out_seen;
    integer mismatches;
    integer protocol_errors;
    integer addr_index;
    integer exp_index;
    integer stall_seen;
    integer expected_sink_words;
    integer sink_count;
    integer input_nonzero;
    integer expected_nonzero;
    integer first_mismatch_index;
    integer dw_trace_count;

    string fixture_dir;

    reg [31:0] cfg_mem [0:871];
    reg [7:0] input_mem [0:65535];
    reg [7:0] expected_mem [0:32767];
    reg [31:0] expected_sink_addr [0:8191];
    reg [31:0] expected_sink_data [0:8191];
    reg [3:0] expected_sink_be [0:8191];
    reg expected_sink_owner [0:8191];
    reg [31:0] expected_sink_epoch [0:8191];
    reg [1:0] expected_sink_context [0:8191];
    reg expected_sink_last [0:8191];

    reg cfg_active;
    reg [1:0] cfg_layer_r;
    reg [9:0] cfg_index_r;
    reg [31:0] cfg_data_r;
    reg cfg_commit_active;
    reg [1:0] cfg_commit_layer_r;

    reg start_active;
    reg [1:0] desc_layer_r;
    reg [5:0] desc_in_h_r, desc_in_w_r, desc_cin_r;
    reg [6:0] desc_cout_r;
    reg [1:0] desc_stride_r;
    reg [31:0] desc_input_base_r, desc_input_row_stride_r;
    reg [7:0] desc_input_zp_r;
    reg [31:0] desc_dw_zp_r, desc_pw_zp_r, desc_min_r, desc_max_r, desc_sink_base_r;

    wire cfg_valid = cfg_active;
    wire cfg_ready;
    wire [1:0] cfg_layer = cfg_layer_r;
    wire [9:0] cfg_index = cfg_index_r;
    wire [31:0] cfg_data = cfg_data_r;
    wire cfg_commit_valid = cfg_commit_active;
    wire cfg_commit_ready;
    wire [1:0] cfg_commit_layer = cfg_commit_layer_r;
    wire start_valid = start_active;
    wire start_ready;

    wire mem_req_valid;
    wire mem_req_ready;
    wire [31:0] mem_req_addr;
    reg mem_resp_valid;
    reg [127:0] mem_resp_data;
    reg mem_pending;
    reg [31:0] mem_pending_addr;
    reg [31:0] lfsr;
    assign mem_req_ready = !random_bp || lfsr[0];

    wire out_valid;
    wire out_ready = !random_bp || lfsr[1];
    wire [31:0] out_addr, out_data;
    wire [3:0] out_be;
    wire [1:0] out_context;
    wire out_owner;
    wire [31:0] out_epoch;
    wire out_last;

    wire busy, done, error;
    wire [7:0] error_code;
    wire [31:0] dw_mac_count, dw_vector_count, padding_tap_count, input_read_count;
    wire [31:0] pw_token_count, pw_mac_count, out_word_count;

    m11a_runtime_dw_pw_core dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_layer(cfg_layer),
        .cfg_index(cfg_index), .cfg_data(cfg_data),
        .cfg_commit_valid(cfg_commit_valid), .cfg_commit_ready(cfg_commit_ready),
        .cfg_commit_layer(cfg_commit_layer), .start_valid(start_valid), .start_ready(start_ready),
        .desc_layer(desc_layer_r), .desc_in_h(desc_in_h_r), .desc_in_w(desc_in_w_r),
        .desc_cin(desc_cin_r), .desc_cout(desc_cout_r), .desc_stride(desc_stride_r),
        .desc_input_base(desc_input_base_r), .desc_input_row_stride(desc_input_row_stride_r),
        .desc_input_zero_point(desc_input_zp_r), .desc_dw_output_zero_point(desc_dw_zp_r),
        .desc_pw_output_zero_point(desc_pw_zp_r), .desc_activation_min(desc_min_r),
        .desc_activation_max(desc_max_r), .desc_sink_base(desc_sink_base_r),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .out_valid(out_valid), .out_ready(out_ready),
        .out_addr(out_addr), .out_data(out_data), .out_be(out_be),
        .out_context(out_context), .out_owner(out_owner), .out_epoch(out_epoch),
        .out_last(out_last), .busy(busy), .done(done), .error(error),
        .error_code(error_code), .dw_mac_count(dw_mac_count),
        .dw_vector_count(dw_vector_count), .padding_tap_count(padding_tap_count),
        .input_read_count(input_read_count), .pw_token_count(pw_token_count),
        .pw_mac_count(pw_mac_count), .out_word_count(out_word_count)
    );

    task automatic load_cfg;
        integer n;
        begin
            for (n = 0; n < cfg_words; n = n + 1) begin
                @(negedge clk);
                cfg_index_r <= n;
                cfg_data_r <= cfg_mem[n];
                cfg_layer_r <= layer_sel[1:0];
                cfg_active <= 1'b1;
                while (1) begin
                    @(posedge clk);
                    if (cfg_ready) begin
                        @(negedge clk);
                        cfg_active <= 1'b0;
                        break;
                    end
                end
            end
            @(negedge clk);
            cfg_commit_layer_r <= layer_sel[1:0];
            cfg_commit_active <= 1'b1;
            while (1) begin
                @(posedge clk);
                if (cfg_commit_ready) begin
                    @(negedge clk);
                    cfg_commit_active <= 1'b0;
                    break;
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_pending <= 1'b0;
            mem_resp_valid <= 1'b0;
            mem_resp_data <= 128'd0;
            mem_pending_addr <= 0;
            lfsr <= 32'h1a2b3c4d;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            mem_resp_valid <= 1'b0;
            if (mem_pending) begin
                mem_resp_valid <= 1'b1;
                for (j = 0; j < 16; j = j + 1)
                    mem_resp_data[j*8 +: 8] <= input_mem[mem_pending_addr + j];
                mem_pending <= 1'b0;
            end else if (mem_req_valid && mem_req_ready) begin
                mem_pending <= 1'b1;
                mem_pending_addr <= mem_req_addr;
            end
        end
    end

    reg stalled_valid, stalled_last;
    reg [31:0] stalled_addr, stalled_data, stalled_epoch;
    reg [1:0] stalled_context;
    reg stalled_owner;
    always @(posedge clk) begin
        if (!rst_n) begin
            out_seen <= 0;
            mismatches <= 0;
            protocol_errors <= 0;
            stall_seen <= 0;
            first_mismatch_index <= -1;
            dw_trace_count <= 0;
            stalled_valid <= 1'b0;
            stalled_last <= 0;
            stalled_addr <= 0;
            stalled_data <= 0;
            stalled_epoch <= 0;
            stalled_context <= 0;
            stalled_owner <= 0;
        end else begin
            if (dut.dw_valid && dut.dw_ready && dw_trace_count < 4) begin
                $display("M11A_DW_TRACE pixel=%0d group=%0d data=%032h", dut.dw_pixel, dut.dw_group, dut.dw_data);
                dw_trace_count <= dw_trace_count + 1;
            end
            if (out_valid && !out_ready) begin
                stall_seen <= stall_seen + 1;
                if (stalled_valid && (out_addr !== stalled_addr || out_data !== stalled_data ||
                                      out_context !== stalled_context || out_owner !== stalled_owner ||
                                      out_epoch !== stalled_epoch || out_last !== stalled_last))
                    protocol_errors <= protocol_errors + 1;
                stalled_valid <= 1'b1;
                stalled_last <= out_last;
                stalled_addr <= out_addr;
                stalled_data <= out_data;
                stalled_epoch <= out_epoch;
                stalled_context <= out_context;
                stalled_owner <= out_owner;
            end else begin
                stalled_valid <= 1'b0;
                stalled_last <= 1'b0;
            end
            if (out_valid && out_ready) begin
                out_seen <= out_seen + 1;
                if (out_be !== 4'hf)
                    protocol_errors <= protocol_errors + 1;
                if (out_seen >= expected_sink_words) begin
                    protocol_errors <= protocol_errors + 1;
                end else if (out_addr !== expected_sink_addr[out_seen] ||
                             out_data !== expected_sink_data[out_seen] ||
                             out_be !== expected_sink_be[out_seen] ||
                             out_context !== expected_sink_context[out_seen] ||
                             out_owner !== expected_sink_owner[out_seen] ||
                             out_epoch !== expected_sink_epoch[out_seen] ||
                             out_last !== expected_sink_last[out_seen]) begin
                    if (first_mismatch_index < 0) begin
                        first_mismatch_index <= out_seen;
                        $display("M11A_FIRST_MISMATCH layer=%0d word=%0d addr_exp=%08h addr_act=%08h data_exp=%08h data_act=%08h be_exp=%h be_act=%h ctx_exp=%0d ctx_act=%0d owner_exp=%0d owner_act=%0d epoch_exp=%0d epoch_act=%0d last_exp=%0d last_act=%0d",
                                 layer_sel, out_seen, expected_sink_addr[out_seen], out_addr,
                                 expected_sink_data[out_seen], out_data,
                                 expected_sink_be[out_seen], out_be,
                                 expected_sink_context[out_seen], out_context,
                                 expected_sink_owner[out_seen], out_owner,
                                 expected_sink_epoch[out_seen], out_epoch,
                                 expected_sink_last[out_seen], out_last);
                    end
                    protocol_errors <= protocol_errors + 1;
                    mismatches <= mismatches + 1;
                end else if (out_addr < desc_sink_base_r || ((out_addr - desc_sink_base_r) & 32'd3) != 0) begin
                    mismatches <= mismatches + 1;
                end else begin
                    addr_index = (out_addr - desc_sink_base_r) >> 2;
                    exp_index = addr_index * 4;
                    for (j = 0; j < 4; j = j + 1)
                        if (out_data[j*8 +: 8] !== expected_mem[exp_index+j])
                            mismatches <= mismatches + 1;
                end
            end
        end
    end

    initial begin
        layer_sel = 1;
        random_bp = 0;
        fixture_dir = "build/m11a_nonzero_fixture";
        if (!$value$plusargs("LAYER=%d", layer_sel)) layer_sel = 1;
        if ($test$plusargs("RANDOM_BP")) random_bp = 1;
        if (!$value$plusargs("FIXTURE=%s", fixture_dir)) fixture_dir = "build/m11a_nonzero_fixture";
        cfg_words = (layer_sel == 1) ? 308 : 872;
        input_bytes = (layer_sel == 1) ? 16384 : 32768;
        output_bytes = (layer_sel == 1) ? 32768 : 16384;
        output_words_expected = (layer_sel == 1) ? 8192 : 4096;
        expected_dw_mac = (layer_sel == 1) ? 147456 : 73728;
        expected_dw_vec = (layer_sel == 1) ? 1024 : 512;
        expected_pw_tokens = 8192;
        expected_pw_mac = 524288;
        expected_out_words = output_words_expected;
        for (i = 0; i < 872; i = i + 1) cfg_mem[i] = 0;
        for (i = 0; i < 65536; i = i + 1) input_mem[i] = 0;
        for (i = 0; i < 32768; i = i + 1) expected_mem[i] = 0;
        if (layer_sel == 1) begin
            $readmemh($sformatf("%s/ds12_stream_ds1_input_i8.hex", fixture_dir), input_mem);
            $readmemh($sformatf("%s/ds12_stream_ds1_output_i8.hex", fixture_dir), expected_mem);
        end else begin
            $readmemh($sformatf("%s/ds12_stream_ds2_input_i8.hex", fixture_dir), input_mem);
            $readmemh($sformatf("%s/ds12_stream_ds2_output_i8.hex", fixture_dir), expected_mem);
        end
        fd = $fopen($sformatf("%s/ds12_stream_cfg_transactions.hex", fixture_dir), "r");
        cfg_count = 0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%d %d %d %h %h %h\n", ly, kd, idx, address, mask, dataw);
            if (rc == 6 && ly == layer_sel) begin
                cfg_mem[idx] = dataw;
                cfg_count = cfg_count + 1;
            end
        end
        $fclose(fd);
        if (cfg_count != cfg_words) $fatal(1, "config parse count %0d expected %0d", cfg_count, cfg_words);

        input_nonzero = 0;
        for (i = 0; i < input_bytes; i = i + 1)
            if (input_mem[i] !== 8'd0) input_nonzero = input_nonzero + 1;
        expected_nonzero = 0;
        for (i = 0; i < output_bytes; i = i + 1)
            if (expected_mem[i] !== 8'd0) expected_nonzero = expected_nonzero + 1;
        if (input_nonzero == 0 || expected_nonzero == 0)
            $fatal(1, "nonzero fixture rejected input_nz=%0d expected_nz=%0d", input_nonzero, expected_nonzero);

        expected_sink_words = 0;
        sink_count = 0;
        sink_fd = $fopen($sformatf("%s/ds12_stream_sink_words.hex", fixture_dir), "r");
        if (sink_fd == 0) $fatal(1, "sink metadata open failed for %s", fixture_dir);
        while (!$feof(sink_fd)) begin
            rc = $fscanf(sink_fd, "%d %d %h %h %h %d %d %d %d %d\n",
                         sink_layer, sink_word, sink_addr, sink_data, sink_mask,
                         sink_owner, sink_epoch, sink_context,
                         sink_req_cycle, sink_resp_cycle);
            if (rc == 10 && sink_layer == layer_sel) begin
                if (sink_word != sink_count) $fatal(1, "sink word index %0d expected %0d", sink_word, sink_count);
                expected_sink_addr[sink_count] = sink_addr;
                expected_sink_data[sink_count] = sink_data;
                expected_sink_be[sink_count] = sink_mask[3:0];
                expected_sink_owner[sink_count] = sink_owner[0];
                expected_sink_epoch[sink_count] = sink_epoch;
                expected_sink_context[sink_count] = sink_context[1:0];
                expected_sink_last[sink_count] = (sink_word == output_words_expected - 1);
                for (j = 0; j < 4; j = j + 1)
                    if (expected_mem[sink_count*4+j] !== sink_data[j*8 +: 8])
                        $fatal(1, "sink metadata/data mismatch word=%0d lane=%0d", sink_count, j);
                sink_count = sink_count + 1;
            end
        end
        $fclose(sink_fd);
        expected_sink_words = sink_count;
        if (expected_sink_words != expected_out_words)
            $fatal(1, "sink row count %0d expected %0d", expected_sink_words, expected_out_words);

        cfg_active = 0; cfg_layer_r = 0; cfg_index_r = 0; cfg_data_r = 0;
        cfg_commit_active = 0; cfg_commit_layer_r = 0; start_active = 0;
        desc_layer_r = layer_sel[1:0];
        desc_in_h_r = 32; desc_in_w_r = 32;
        desc_cin_r = (layer_sel == 1) ? 16 : 32;
        desc_cout_r = (layer_sel == 1) ? 32 : 64;
        desc_stride_r = (layer_sel == 1) ? 1 : 2;
        desc_input_base_r = 0;
        desc_input_row_stride_r = (layer_sel == 1) ? 512 : 1024;
        desc_input_zp_r = 0;
        desc_dw_zp_r = 0; desc_pw_zp_r = 0; desc_min_r = 0; desc_max_r = 127;
        desc_sink_base_r = (layer_sel == 1) ? 32'h0010_0000 : 32'h0020_0000;
        repeat (3) @(posedge clk);
        rst_n = 1;
        load_cfg();
        while (!start_ready) @(posedge clk);
        @(negedge clk); start_active = 1'b1;
        @(posedge clk);
        @(negedge clk); start_active = 1'b0;
        cycles = 0;
        while (!done && cycles < 500000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        $display("M11A_LAYER%0d_%s cycles=%0d cfg=%0d out=%0d dw_vec=%0d dw_mac=%0d pw_tokens=%0d pw_mac=%0d input_reads=%0d pad=%0d input_nz=%0d expected_nz=%0d mismatches=%0d protocol_errors=%0d stalls=%0d error=%b ec=%h",
                 layer_sel,
                 (done && !error && mismatches == 0 && protocol_errors == 0 &&
                  out_seen == expected_out_words && dw_vector_count == expected_dw_vec &&
                  dw_mac_count == expected_dw_mac && pw_token_count == expected_pw_tokens &&
                  pw_mac_count == expected_pw_mac && out_word_count == expected_out_words) ? "NONZERO_FIXTURE_PASS" : "NONZERO_FIXTURE_FAIL",
                 cycles, cfg_count, out_seen, dw_vector_count, dw_mac_count,
                 pw_token_count, pw_mac_count, input_read_count, padding_tap_count,
                 input_nonzero, expected_nonzero, mismatches, protocol_errors, stall_seen, error, error_code);
        if (!done || error || mismatches != 0 || protocol_errors != 0 ||
            out_seen != expected_out_words || dw_vector_count != expected_dw_vec ||
            dw_mac_count != expected_dw_mac || pw_token_count != expected_pw_tokens ||
            pw_mac_count != expected_pw_mac || out_word_count != expected_out_words)
            $fatal(1, "M11.1-A exact unit check failed");
        $finish;
    end
endmodule

`default_nettype wire
