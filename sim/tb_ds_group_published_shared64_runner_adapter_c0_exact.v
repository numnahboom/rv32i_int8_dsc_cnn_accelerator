`timescale 1ns/1ps
`default_nettype none

/*
 * Independent C0 value/protocol gate for the descriptor-facing shared64
 * adapter.  The generator supplies all input, DW/PW expected bytes, and
 * scalar configuration transactions.  This bench checks every valid DW and
 * PW byte, not just a count or a selected output, and runs every shape once
 * without stalls and once with two independent deterministic ready streams.
 * The physical four-by-eight DW tail is counted separately from valid bytes.
 */
module tb_ds_group_published_shared64_runner_adapter_c0_exact;
    localparam integer MAX_BYTES = 32768;

    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;

    reg start_valid = 1'b0;
    wire start_ready;
    reg [31:0] input_base_addr = 32'd0;
    reg [31:0] output_base_addr = 32'd0;
    reg [15:0] input_height = 0, input_width = 0;
    reg [15:0] input_channels = 0, output_channels = 0;
    reg [7:0] stride = 1, input_zero_point = 0;
    reg signed [31:0] dw_output_zero_point = 0;
    reg signed [31:0] dw_activation_min = 0, dw_activation_max = 127;
    reg signed [31:0] pw_output_zero_point = 0;
    reg signed [31:0] pw_activation_min = 0, pw_activation_max = 127;

    reg config_write_en = 1'b0;
    reg [3:0] config_target = 0;
    reg [15:0] config_index = 0;
    reg [31:0] config_data = 0;
    wire [6:0] config_dw_channel = config_index / 9;
    wire [3:0] config_dw_tap = config_index % 9;

    wire source_word_en;
    wire [14:0] source_word_addr;
    reg source_word_ready = 1'b1;
    reg source_word_valid = 1'b0;
    reg [31:0] source_word_data = 0;
    wire output_word_en;
    wire [15:0] output_word_addr;
    wire [31:0] output_word_data;
    wire [3:0] output_word_be;
    reg output_word_ready = 1'b1;
    wire busy, done, error;
    wire [31:0] perf_cycles, perf_dw_writes, perf_descriptors;
    wire [31:0] perf_pw_tokens, perf_output_writes, perf_jobs, perf_stream_beats;
    wire [31:0] config_accept_count, config_phase_count;

    ds_group_published_shared64_runner_adapter dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid), .start_ready(start_ready),
        .input_base_addr(input_base_addr), .output_base_addr(output_base_addr),
        .input_height(input_height), .input_width(input_width),
        .input_channels(input_channels), .output_channels(output_channels),
        .stride(stride), .input_zero_point(input_zero_point),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min), .dw_activation_max(dw_activation_max),
        .pw_output_zero_point(pw_output_zero_point),
        .pw_activation_min(pw_activation_min), .pw_activation_max(pw_activation_max),
        .config_write_en(config_write_en), .config_target(config_target),
        .config_index(config_index), .config_data(config_data),
        .config_dw_channel(config_dw_channel), .config_dw_tap(config_dw_tap),
        .config_word_write_en(1'b0), .config_word_target(4'd0),
        .config_word_index(16'd0), .config_word_data(32'd0), .config_word_be(4'd0),
        .source_word_en(source_word_en), .source_word_addr(source_word_addr),
        .source_word_ready(source_word_ready), .source_word_valid(source_word_valid),
        .source_word_data(source_word_data), .output_word_en(output_word_en),
        .output_word_addr(output_word_addr), .output_word_data(output_word_data),
        .output_word_be(output_word_be), .output_word_ready(output_word_ready),
        .busy(busy), .done(done), .error(error), .perf_cycles(perf_cycles),
        .perf_dw_writes(perf_dw_writes), .perf_descriptors(perf_descriptors),
        .perf_pw_tokens(perf_pw_tokens), .perf_output_writes(perf_output_writes),
        .perf_jobs(perf_jobs), .perf_stream_beats(perf_stream_beats),
        .config_accept_count(config_accept_count), .config_phase_count(config_phase_count),
        .config_word_accept_count(), .config_scalar_write_count()
    );

    reg [7:0] source_mem [0:MAX_BYTES-1];
    reg [7:0] expected_dw [0:MAX_BYTES-1];
    reg [7:0] expected_pw [0:MAX_BYTES-1];
    reg dw_seen [0:MAX_BYTES-1];
    reg pw_seen [0:MAX_BYTES-1];

    integer active_layer = 0;
    integer active_h = 0, active_w = 0, active_cin = 0, active_cout = 0;
    integer active_stride = 1, active_out_h = 0, active_out_w = 0;
    integer active_pixels = 0, active_input_bytes = 0;
    integer active_dw_bytes = 0, active_pw_bytes = 0;
    integer active_tile_cols = 0, active_macro_count = 0, active_group_count = 0;
    integer active_cout_tiles = 0, active_jobs = 0;
    integer active_dw_physical_beats = 0, active_desc = 0;
    integer active_tokens = 0, active_output_words = 0;

    integer errors = 0;
    integer case_errors = 0;
    integer audit_active = 0;
    integer bp_mode = 0;
    integer source_handshakes = 0, source_stalls = 0;
    integer output_handshakes = 0, output_stalls = 0;
    integer dw_physical_handshakes = 0, dw_valid_checks = 0, pw_valid_checks = 0;
    integer source_addr_checks = 0, source_map_checks = 0, metadata_checks = 0, owner_checks = 0;
    integer config_lines = 0;
    integer metrics_fd;

    reg [31:0] source_lfsr = 32'h1a2b3c4d;
    reg [31:0] output_lfsr = 32'h5e6f7788;
    reg pending_source_valid = 1'b0;
    reg [31:0] pending_source_data = 0;
    reg expected_response_valid = 1'b0;
    reg [31:0] expected_response_data = 0;
    reg expected_compare_valid = 1'b0;
    reg [31:0] expected_compare_data = 0;
    integer source_addr_i;
    integer source_y_i, source_x_i, source_q_i, source_channel_offset_i;
    integer source_expected_addr_i;
    integer source_lane_i;

    /* The source model is an ordered one-cycle response stream.  The adapter
     * has no response-ready pin at this boundary; its internal FIFO absorbs
     * consecutive responses while producer/source ready independently stall. */
    always @(posedge clk) begin
        if (!rst_n) begin
            pending_source_valid <= 1'b0;
            pending_source_data <= 0;
            source_word_valid <= 1'b0;
            source_word_data <= 0;
            expected_response_valid <= 1'b0;
            expected_response_data <= 0;
            expected_compare_valid <= 1'b0;
            expected_compare_data <= 0;
        end else begin
            source_word_valid <= pending_source_valid;
            source_word_data <= pending_source_data;
            expected_response_valid <= source_word_en && source_word_ready;
            /* The response model uses nonblocking assignments, so the
             * visible source data/valid pair is one sampled edge behind the
             * request expectation register.  Delay the expected pair by the
             * same edge before checking it below. */
            expected_compare_valid <= expected_response_valid;
            expected_compare_data <= expected_response_data;
            if (source_word_en && source_word_ready) begin
                source_addr_i = dut.u_source_adapter.mem_req_addr;
                pending_source_data <= {
                    source_mem[source_addr_i + 3], source_mem[source_addr_i + 2],
                    source_mem[source_addr_i + 1], source_mem[source_addr_i]
                };
                expected_response_data <= {
                    source_mem[source_addr_i + 3], source_mem[source_addr_i + 2],
                    source_mem[source_addr_i + 1], source_mem[source_addr_i]
                };
            end
            pending_source_valid <= source_word_en && source_word_ready;
        end
    end

    /* Separate LFSRs make source and sink backpressure reproducible but not
     * coupled.  Ready changes only on the opposite edge, so it is stable for
     * the entire cycle in which a valid channel may be held. */
    always @(negedge clk) begin
        if (!rst_n || !bp_mode) begin
            source_word_ready <= 1'b1;
            output_word_ready <= 1'b1;
            source_lfsr <= 32'h1a2b3c4d;
            output_lfsr <= 32'h5e6f7788;
        end else begin
            source_word_ready <= !((source_lfsr[4:0] == 5'h0b) ||
                                   (source_lfsr[12:8] == 5'h15));
            output_word_ready <= !((output_lfsr[3:0] == 4'h5) ||
                                   (output_lfsr[11:8] == 4'ha));
            source_lfsr <= {source_lfsr[30:0],
                            source_lfsr[31] ^ source_lfsr[21] ^ source_lfsr[1] ^ source_lfsr[0]};
            output_lfsr <= {output_lfsr[30:0],
                            output_lfsr[31] ^ output_lfsr[21] ^ output_lfsr[1] ^ output_lfsr[0]};
        end
    end

    function integer as_unsigned_byte;
        input integer value;
        begin as_unsigned_byte = value & 255; end
    endfunction

    task configure_shape;
        input integer layer;
        begin
            case (layer)
                1: begin active_h=32; active_w=32; active_cin=16; active_cout=32; active_stride=1; end
                2: begin active_h=32; active_w=32; active_cin=32; active_cout=64; active_stride=2; end
                3: begin active_h=16; active_w=16; active_cin=64; active_cout=64; active_stride=1; end
                4: begin active_h=16; active_w=16; active_cin=64; active_cout=128; active_stride=2; end
                5: begin active_h=8; active_w=8; active_cin=128; active_cout=128; active_stride=1; end
                6: begin active_h=8; active_w=8; active_cin=128; active_cout=256; active_stride=2; end
                default: $fatal(1, "BAD_LAYER %0d", layer);
            endcase
            active_out_h = (active_h + active_stride - 1) / active_stride;
            active_out_w = (active_w + active_stride - 1) / active_stride;
            active_pixels = active_out_h * active_out_w;
            active_input_bytes = active_h * active_w * active_cin;
            active_dw_bytes = active_pixels * active_cin;
            active_pw_bytes = active_pixels * active_cout;
            active_tile_cols = (active_out_w + 7) / 8;
            active_macro_count = ((active_out_h + 3) / 4) * active_tile_cols;
            active_group_count = (active_cin + 15) / 16;
            active_cout_tiles = (active_cout + 7) / 8;
            active_jobs = active_macro_count * active_group_count;
            active_dw_physical_beats = active_macro_count * 32 * active_cin / 4;
            active_desc = active_macro_count * 4 * (active_cin / 8);
            /* perf_pw_tokens/owner_checks count accepted physical 64-product
             * tokens.  A narrow spatial tail still emits the fixed 4x8
             * macro, so DS6's 4x4 output has twice the physical token count
             * of its useful masked MAC workload. */
            active_tokens = active_macro_count * 4 * active_cin * active_cout_tiles;
            active_output_words = active_pixels * active_cout / 4;
            input_height = active_h;
            input_width = active_w;
            input_channels = active_cin;
            output_channels = active_cout;
            stride = active_stride;
            input_zero_point = 0;
            dw_output_zero_point = 0;
            pw_output_zero_point = 0;
            dw_activation_min = 0;
            dw_activation_max = 127;
            pw_activation_min = 0;
            pw_activation_max = 127;
        end
    endtask

    task load_hex_files;
        input integer layer;
        integer ii;
        begin
            for (ii=0; ii<MAX_BYTES; ii=ii+1) begin
                source_mem[ii] = 0;
                expected_dw[ii] = 0;
                expected_pw[ii] = 0;
                dw_seen[ii] = 0;
                pw_seen[ii] = 0;
            end
            case (layer)
                1: begin
                    $readmemh("build/shared64_c0_exact/layer1_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer1_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer1_pw_expected_i8.hex", expected_pw);
                end
                2: begin
                    $readmemh("build/shared64_c0_exact/layer2_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer2_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer2_pw_expected_i8.hex", expected_pw);
                end
                3: begin
                    $readmemh("build/shared64_c0_exact/layer3_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer3_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer3_pw_expected_i8.hex", expected_pw);
                end
                4: begin
                    $readmemh("build/shared64_c0_exact/layer4_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer4_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer4_pw_expected_i8.hex", expected_pw);
                end
                5: begin
                    $readmemh("build/shared64_c0_exact/layer5_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer5_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer5_pw_expected_i8.hex", expected_pw);
                end
                6: begin
                    $readmemh("build/shared64_c0_exact/layer6_input_i8.hex", source_mem);
                    $readmemh("build/shared64_c0_exact/layer6_dw_expected_i8.hex", expected_dw);
                    $readmemh("build/shared64_c0_exact/layer6_pw_expected_i8.hex", expected_pw);
                end
            endcase
        end
    endtask

    task cfg;
        input integer target;
        input integer index;
        input [31:0] data;
        begin
            @(negedge clk);
            config_target = target;
            config_index = index;
            config_data = data;
            config_write_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            config_write_en = 1'b0;
        end
    endtask

    task load_config;
        input integer layer;
        integer fd, rc, target_i, index_i;
        reg [31:0] data_i;
        reg [1023:0] config_path;
        begin
            case (layer)
                1: config_path = "build/shared64_c0_exact/layer1_cfg.hex";
                2: config_path = "build/shared64_c0_exact/layer2_cfg.hex";
                3: config_path = "build/shared64_c0_exact/layer3_cfg.hex";
                4: config_path = "build/shared64_c0_exact/layer4_cfg.hex";
                5: config_path = "build/shared64_c0_exact/layer5_cfg.hex";
                6: config_path = "build/shared64_c0_exact/layer6_cfg.hex";
                default: $fatal(1, "BAD_CONFIG_LAYER %0d", layer);
            endcase
            fd = $fopen(config_path, "r");
            if (fd == 0) $fatal(1, "CONFIG_OPEN_FAIL layer=%0d path=%0s", layer, config_path);
            config_lines = 0;
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%d %d %h", target_i, index_i, data_i);
                if (rc == 3) begin
                    cfg(target_i, index_i, data_i);
                    config_lines = config_lines + 1;
                end else if (!$feof(fd)) begin
                    $fatal(1, "CONFIG_PARSE_FAIL layer=%0d rc=%0d", layer, rc);
                end
            end
            $fclose(fd);
        end
    endtask

    /* Hold checks and full-byte scoreboards are sampled at the active edge,
     * after ready has been stable since the preceding falling edge. */
    reg source_hold_active = 1'b0;
    reg [14:0] source_hold_addr = 0;
    reg output_hold_active = 1'b0;
    reg [15:0] output_hold_addr = 0;
    reg [31:0] output_hold_data = 0;
    reg [3:0] output_hold_be = 0;
    integer stream_pixel_i, stream_macro_i, stream_local_y_i, stream_local_x_i;
    integer stream_global_y_i, stream_global_x_i, stream_group_i, stream_channel_i;
    integer stream_lane_i, stream_index_i, stream_value_i, stream_expected_i;
    integer result_pixel_i, result_channel_i, result_index_i, result_lane_i;
    integer result_value_i, result_expected_i;
    integer sy, sx, sq, sch, sa, expected_addr;
    always @(posedge clk) begin
        if (rst_n && audit_active) begin
            if (source_hold_active &&
                (!source_word_en || source_word_addr !== source_hold_addr)) begin
                if (case_errors < 12) $display("SOURCE_NOT_STABLE layer=%0d mode=%0d", active_layer, bp_mode);
                case_errors = case_errors + 1;
            end
            source_hold_active = source_word_en && !source_word_ready;
            if (source_hold_active) source_hold_addr = source_word_addr;

            if (output_hold_active &&
                (!output_word_en || output_word_addr !== output_hold_addr ||
                 output_word_data !== output_hold_data || output_word_be !== output_hold_be)) begin
                if (case_errors < 12) $display("OUTPUT_NOT_STABLE layer=%0d mode=%0d", active_layer, bp_mode);
                case_errors = case_errors + 1;
            end
            output_hold_active = output_word_en && !output_word_ready;
            if (output_hold_active) begin
                output_hold_addr = output_word_addr;
                output_hold_data = output_word_data;
                output_hold_be = output_word_be;
            end

            /* A delayed pending request can drain after the coordinate cursor
             * has advanced.  Audit coordinates at producer acceptance and
             * only range/alignment when that pending request reaches SRAM. */
            if (dut.u_source_adapter.producer_req_valid &&
                dut.u_source_adapter.producer_req_ready &&
                !dut.u_source_adapter.mapped_padding) begin
                sy = $signed(dut.u_source_adapter.source_y_reg);
                sx = $signed(dut.u_source_adapter.source_x_reg);
                sq = dut.u_source_adapter.quarter_reg;
                sch = dut.u_source_adapter.channel_offset_reg;
                expected_addr = ((sy * active_w) + sx) * active_cin + sch + sq * 4;
                if (dut.u_source_adapter.mapped_addr !== expected_addr ||
                    expected_addr < 0 || (expected_addr & 3) != 0 ||
                    expected_addr + 3 >= active_input_bytes) begin
                    if (case_errors < 12)
                        $display("BAD_SOURCE_MAP layer=%0d mode=%0d addr=%0d exp=%0d y=%0d x=%0d q=%0d ch=%0d", active_layer, bp_mode, dut.u_source_adapter.mapped_addr, expected_addr, sy, sx, sq, sch);
                    case_errors = case_errors + 1;
                end
                source_map_checks = source_map_checks + 1;
            end
            if (source_word_en && source_word_ready) begin
                source_handshakes = source_handshakes + 1;
                sa = dut.u_source_adapter.mem_req_addr;
                if ((sa < 0) || ((sa & 3) != 0) || (sa + 3 >= active_input_bytes)) begin
                    if (case_errors < 12)
                        $display("BAD_SOURCE_ADDR layer=%0d mode=%0d addr=%0d", active_layer, bp_mode, sa);
                    case_errors = case_errors + 1;
                end
                source_addr_checks = source_addr_checks + 1;
            end else if (source_word_en && !source_word_ready) begin
                source_stalls = source_stalls + 1;
            end
            if (source_word_valid) begin
                if (!expected_compare_valid || source_word_data !== expected_compare_data) begin
                    if (case_errors < 12) $display("BAD_SOURCE_DATA layer=%0d mode=%0d got=%h exp=%h", active_layer, bp_mode, source_word_data, expected_compare_data);
                    case_errors = case_errors + 1;
                end
            end

            if (dut.sweep_dw_valid && dut.sweep_dw_ready) begin
                dw_physical_handshakes = dw_physical_handshakes + 1;
                stream_pixel_i = dut.producer_stream_pixel;
                stream_macro_i = dut.macro_q;
                stream_local_y_i = stream_pixel_i / 8;
                stream_local_x_i = stream_pixel_i % 8;
                stream_global_y_i = (stream_macro_i / active_tile_cols) * 4 + stream_local_y_i;
                stream_global_x_i = (stream_macro_i % active_tile_cols) * 8 + stream_local_x_i;
                stream_group_i = dut.channel_group_q;
                for (stream_lane_i=0; stream_lane_i<4; stream_lane_i=stream_lane_i+1) begin
                    stream_channel_i = stream_group_i * 16 + dut.producer_stream_lane_base * 4 + stream_lane_i;
                    if (stream_global_y_i < active_out_h && stream_global_x_i < active_out_w &&
                        stream_channel_i < active_cin) begin
                        stream_index_i = (stream_global_y_i * active_out_w + stream_global_x_i) * active_cin + stream_channel_i;
                        stream_value_i = dut.producer_stream_data[stream_lane_i*8 +: 8];
                        stream_expected_i = expected_dw[stream_index_i];
                        if (stream_value_i != stream_expected_i || dw_seen[stream_index_i]) begin
                            if (case_errors < 12) $display("DW_MISMATCH layer=%0d mode=%0d macro=%0d p=%0d gy=%0d gx=%0d ch=%0d got=%02x exp=%02x dup=%0d", active_layer, bp_mode, stream_macro_i, stream_pixel_i, stream_global_y_i, stream_global_x_i, stream_channel_i, stream_value_i, stream_expected_i, dw_seen[stream_index_i]);
                            case_errors = case_errors + 1;
                        end
                        dw_seen[stream_index_i] = 1'b1;
                        dw_valid_checks = dw_valid_checks + 1;
                    end
                end
                if (dut.producer_stream_mask !== 4'hf &&
                    stream_global_y_i < active_out_h && stream_global_x_i < active_out_w) begin
                    if (case_errors < 12) $display("BAD_DW_MASK layer=%0d mode=%0d mask=%h", active_layer, bp_mode, dut.producer_stream_mask);
                    case_errors = case_errors + 1;
                end
                if (dut.sweep_dw_macro !== dut.macro_q ||
                    dut.sweep_dw_group !== (dut.channel_group_q * 2 + dut.producer_stream_lane_base[1]) ||
                    dut.sweep_dw_half !== dut.producer_stream_lane_base[0] ||
                    dut.sweep_dw_pixel !== dut.producer_stream_pixel[2:0]) begin
                    if (case_errors < 12) $display("BAD_DW_METADATA layer=%0d mode=%0d", active_layer, bp_mode);
                    case_errors = case_errors + 1;
                end
                metadata_checks = metadata_checks + 1;
            end

            if (dut.u_sweep.pw_token_fire) begin
                if ($test$plusargs("TOKDBG") && active_layer == 1 && bp_mode == 0 &&
                    dut.u_sweep.pw_tile_q == 0 && dut.u_sweep.pw_row_block_q <= 1)
                    $display("TOKDBG layer=%0d rowblock=%0d group=%0d k=%0d pixelbase=%0d top0=%h top1=%h bot0=%h bot1=%h act=%h wgt=%h waddr=%h respaddr=%h rdaddr=%h issue=%h active=%b curbank=%b alloc=%b live=%b%b ready=%b%b", active_layer, dut.u_sweep.pw_row_block_q, dut.u_sweep.pw_group_q, dut.u_sweep.pw_k_q, dut.u_sweep.pw_pixel_base, dut.u_sweep.pw_top_row[31:0], dut.u_sweep.pw_top_row[63:32], dut.u_sweep.pw_bottom_row[31:0], dut.u_sweep.pw_bottom_row[63:32], dut.u_sweep.pw_act_vec, dut.u_sweep.pw_wgt_row, dut.u_sweep.rd_issue_weight_addr, dut.pw_weight_resp_addr, dut.u_sweep.pw_scratch_addr, dut.u_sweep.rd_issue_scratch_addr, dut.u_sweep.u_shared_ds.current_active, dut.u_sweep.u_shared_ds.current_bank, dut.u_sweep.u_shared_ds.alloc_bank_reg, dut.u_sweep.u_shared_ds.bank_live1, dut.u_sweep.u_shared_ds.bank_live0, dut.u_sweep.u_shared_ds.bank_ready1, dut.u_sweep.u_shared_ds.bank_ready0);
                if (!dut.u_sweep.pw_published || !dut.u_sweep.pw_owner_match ||
                    dut.u_sweep.pw_slot_generation !== dut.u_sweep.epoch_q ||
                    dut.u_sweep.pw_bank !== dut.u_sweep.pw_macro_q[0] ||
                    (dut.u_sweep.pw_group_q * 8 + dut.u_sweep.pw_k_q) >= active_cin ||
                    dut.u_sweep.pw_tile_q >= active_cout_tiles) begin
                    if (case_errors < 12) $display("BAD_OWNER_TAG layer=%0d mode=%0d row=%0d tile=%0d group=%0d k=%0d", active_layer, bp_mode, dut.u_sweep.pw_row_block_q, dut.u_sweep.pw_tile_q, dut.u_sweep.pw_group_q, dut.u_sweep.pw_k_q);
                    case_errors = case_errors + 1;
                end
                owner_checks = owner_checks + 1;
            end

            if (output_word_en && output_word_ready) begin
                output_handshakes = output_handshakes + 1;
                result_pixel_i = dut.sweep_result_pixel;
                result_channel_i = dut.sweep_result_channel;
                if ($test$plusargs("TOKDBG") && active_layer == 1 && bp_mode == 0 &&
                    result_pixel_i >= 32 && result_pixel_i < 40 && result_channel_i == 0)
                    $display("OUTDBG layer=%0d p=%0d ch=%0d data=%h mask=%h bank0=%h bank1=%h drain=%h dvalid=%b", active_layer, result_pixel_i, result_channel_i, output_word_data, dut.sweep_result_mask, dut.u_sweep.u_shared_ds.bank_psum0[31:0], dut.u_sweep.u_shared_ds.bank_psum1[31:0], dut.u_sweep.u_shared_ds.drain_psum[31:0], dut.u_sweep.u_shared_ds.rq_stage_valid);
                if ((result_pixel_i >= active_pixels) || (result_channel_i >= active_cout) ||
                    ((result_channel_i & 3) != 0) || output_word_be !== 4'hf ||
                    output_word_addr !== (result_pixel_i * active_cout + result_channel_i) ||
                    output_word_addr + 3 >= active_pw_bytes) begin
                    if (case_errors < 12) $display("BAD_RESULT_METADATA layer=%0d mode=%0d p=%0d ch=%0d addr=%0d be=%h", active_layer, bp_mode, result_pixel_i, result_channel_i, output_word_addr, output_word_be);
                    case_errors = case_errors + 1;
                end
                for (result_lane_i=0; result_lane_i<4; result_lane_i=result_lane_i+1) begin
                    result_index_i = result_pixel_i * active_cout + result_channel_i + result_lane_i;
                    result_value_i = output_word_data[result_lane_i*8 +: 8];
                    result_expected_i = expected_pw[result_index_i];
                    if ((result_index_i < 0) || (result_index_i >= active_pw_bytes) ||
                        result_value_i != result_expected_i || pw_seen[result_index_i]) begin
                        if (case_errors < 12) $display("PW_MISMATCH layer=%0d mode=%0d p=%0d ch=%0d lane=%0d got=%02x exp=%02x dup=%0d", active_layer, bp_mode, result_pixel_i, result_channel_i, result_lane_i, result_value_i, result_expected_i, pw_seen[result_index_i]);
                        case_errors = case_errors + 1;
                    end
                    pw_seen[result_index_i] = 1'b1;
                    pw_valid_checks = pw_valid_checks + 1;
                end
            end else if (output_word_en && !output_word_ready) begin
                output_stalls = output_stalls + 1;
            end
        end
    end

    task run_case;
        input integer layer;
        input integer mode;
        integer ii, config_before, expected_config;
        integer wait_cycles, seen_dw, seen_pw;
        begin
            active_layer = layer;
            bp_mode = mode;
            configure_shape(layer);
            load_hex_files(layer);
            if (mode == 0) begin
                config_before = config_accept_count;
                load_config(layer);
                expected_config = (active_cin * 9) + (active_cin * 3) +
                                  (active_cout * active_cin) + (active_cout * 3);
                if (config_lines != expected_config ||
                    config_accept_count - config_before != expected_config) begin
                    $display("BAD_CONFIG_COUNT layer=%0d got=%0d/%0d accept_delta=%0d", layer, config_lines, expected_config, config_accept_count-config_before);
                    errors = errors + 1;
                end
            end
            case_errors = 0;
            source_handshakes = 0;
            source_stalls = 0;
            output_handshakes = 0;
            output_stalls = 0;
            dw_physical_handshakes = 0;
            dw_valid_checks = 0;
            pw_valid_checks = 0;
            source_addr_checks = 0;
            source_map_checks = 0;
            metadata_checks = 0;
            owner_checks = 0;
            source_hold_active = 1'b0;
            output_hold_active = 1'b0;
            expected_response_valid = 1'b0;
            expected_response_data = 0;
            expected_compare_valid = 1'b0;
            expected_compare_data = 0;
            pending_source_valid = 1'b0;
            @(posedge clk);
            @(negedge clk);
            start_valid = 1'b1;
            begin : wait_for_start
                while (1) begin
                    @(posedge clk);
                    if (start_ready) begin
                        @(negedge clk);
                        start_valid = 1'b0;
                        disable wait_for_start;
                    end
                end
            end
            audit_active = 1;
            wait_cycles = 0;
            while (!done) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 250000) $fatal(1, "CASE_WATCHDOG layer=%0d mode=%0d state=%0d cycles=%0d", layer, mode, dut.state, perf_cycles);
            end
            audit_active = 0;
            if (error) case_errors = case_errors + 1;
            seen_dw = 0;
            seen_pw = 0;
            for (ii=0; ii<active_dw_bytes; ii=ii+1) if (dw_seen[ii]) seen_dw = seen_dw + 1;
            for (ii=0; ii<active_pw_bytes; ii=ii+1) if (pw_seen[ii]) seen_pw = seen_pw + 1;
            if (perf_dw_writes !== active_dw_physical_beats ||
                perf_stream_beats !== active_dw_physical_beats ||
                dw_physical_handshakes !== active_dw_physical_beats) begin
                $display("BAD_DW_LEDGER layer=%0d mode=%0d perf=%0d stream=%0d hs=%0d exp=%0d", layer, mode, perf_dw_writes, perf_stream_beats, dw_physical_handshakes, active_dw_physical_beats);
                case_errors = case_errors + 1;
            end
            if (perf_descriptors !== active_desc || perf_pw_tokens !== active_tokens ||
                perf_output_writes !== active_output_words || perf_jobs !== active_jobs) begin
                $display("BAD_PW_LEDGER layer=%0d mode=%0d desc=%0d/%0d tok=%0d/%0d out=%0d/%0d jobs=%0d/%0d", layer, mode, perf_descriptors, active_desc, perf_pw_tokens, active_tokens, perf_output_writes, active_output_words, perf_jobs, active_jobs);
                case_errors = case_errors + 1;
            end
            if (dw_valid_checks !== active_dw_bytes || pw_valid_checks !== active_pw_bytes ||
                seen_dw !== active_dw_bytes || seen_pw !== active_pw_bytes ||
                source_handshakes == 0 || source_addr_checks !== source_handshakes || source_map_checks == 0 ||
                owner_checks !== active_tokens) begin
                $display("BAD_EXACT_COVERAGE layer=%0d mode=%0d dw=%0d/%0d seen_dw=%0d pw=%0d/%0d seen_pw=%0d source=%0d owner=%0d/%0d", layer, mode, dw_valid_checks, active_dw_bytes, seen_dw, pw_valid_checks, active_pw_bytes, seen_pw, source_handshakes, owner_checks, active_tokens);
                case_errors = case_errors + 1;
            end
            if (mode == 1 && (source_stalls == 0 || output_stalls == 0)) begin
                $display("BAD_BACKPRESSURE_COVERAGE layer=%0d source_stalls=%0d output_stalls=%0d", layer, source_stalls, output_stalls);
                case_errors = case_errors + 1;
            end
            errors = errors + case_errors;
            if (case_errors == 0)
                $display("PASS C0_EXACT layer=%0d mode=%0d cycles=%0d dw_valid=%0d dw_physical=%0d pw_valid=%0d source=%0d source_stalls=%0d output_stalls=%0d metadata=%0d owner=%0d config=%0d", layer, mode, perf_cycles, dw_valid_checks, dw_physical_handshakes, pw_valid_checks, source_handshakes, source_stalls, output_stalls, metadata_checks, owner_checks, config_accept_count);
            else
                $display("FAIL C0_EXACT layer=%0d mode=%0d errors=%0d cycles=%0d dw_valid=%0d/%0d pw_valid=%0d/%0d source=%0d owner=%0d/%0d", layer, mode, case_errors, perf_cycles, dw_valid_checks, active_dw_bytes, pw_valid_checks, active_pw_bytes, source_handshakes, owner_checks, active_tokens);
            if (metrics_fd != 0)
                $fwrite(metrics_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", layer, mode, active_h, active_w, active_cin, active_cout, active_stride, perf_cycles, perf_dw_writes, perf_descriptors, perf_pw_tokens, perf_output_writes, perf_jobs, dw_valid_checks, pw_valid_checks, source_handshakes, source_stalls, output_stalls, metadata_checks, owner_checks);
            @(posedge clk);
        end
    endtask

    initial begin
        metrics_fd = $fopen("build/reports/shared64_c0_exact_metrics.csv", "w");
        if (metrics_fd != 0)
            $fwrite(metrics_fd, "layer,mode,h,w,cin,cout,stride,cycles,dw_physical,descriptors,pw_tokens,pw_output_words,jobs,dw_valid_bytes,pw_valid_bytes,source_words,source_stalls,output_stalls,metadata_checks,owner_checks\n");
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        run_case(1, 0); run_case(1, 1);
        if (!$test$plusargs("DS1_ONLY")) begin
            run_case(2, 0); run_case(2, 1);
            run_case(3, 0); run_case(3, 1);
            run_case(4, 0); run_case(4, 1);
            run_case(5, 0); run_case(5, 1);
            run_case(6, 0); run_case(6, 1);
        end
        if (metrics_fd != 0) $fclose(metrics_fd);
        if (errors == 0) begin
            $display("PASS shared64 C0 six-layer exact total_pw_mac=4194304 total_ops=8388608");
            $finish;
        end else begin
            $display("FAIL shared64 C0 six-layer exact errors=%0d", errors);
            $fatal(1);
        end
    end
    initial begin
        repeat (2000000) @(posedge clk);
        $fatal(1, "GLOBAL_WATCHDOG");
    end
endmodule

`default_nettype wire
