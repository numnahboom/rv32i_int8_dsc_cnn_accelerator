`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_fullnet_sram_datapath #(
    parameter USE_UNIFIED64_DS = 0,
    parameter USE_UNIFIED64_STEM = 0,
    parameter USE_SHARED_UNIFIED64 = 0,
    parameter USE_PERSISTENT_DS = 0,
    // Optional deterministic external-bus backpressure for integration
    // proof.  The default retains the historical always-ready fullnet test.
    parameter MEM_READY_STALLS = 0
);
    localparam MEM_WORDS = 262144;
    localparam MAX_EXPECTED = 64;
    localparam MAX_LAYERS = 16;

    reg clk;
    reg rst_n;
    reg cmd_valid;
    wire cmd_ready;
    reg [1:0] cmd_type;
    reg [31:0] desc_base_addr;
    reg [31:0] layer_num;
    wire [31:0] status;
    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    reg mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;

    reg [31:0] mem [0:MEM_WORDS-1];
    integer bus_phase;
    reg [31:0] expected_addr [0:MAX_EXPECTED-1];
    reg [7:0] expected_data [0:MAX_EXPECTED-1];

    integer fd;
    integer report_fd;
    integer layer_metrics_fd;
    integer persistent_ds_metrics_fd;
    integer hw_logits_fd;
    integer expected_logits_fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer entry_count;
    integer expected_count;
    integer layer_num_file;
    integer i;
    integer perf_i;
    integer timeout;
    integer total_checks;
    integer error_count;
    integer case_errors;
    integer mem_read_total;
    integer mem_write_total;
    integer desc_read_total;
    integer layer_read_total;
    integer layer_write_total;
    integer sram_read_total;
    integer sram_word_read_total;
    integer sram_write_total;
    reg [31:0] tmp_addr;
    reg [31:0] tmp_data;
    reg [7:0] tmp_i8;
    reg [31:0] case_hw_cycles;
    reg perf_layer_active;
    reg [7:0] perf_layer_idx;
    reg [31:0] perf_layer_cycles [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_writes [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_word_reads [0:MAX_LAYERS-1];
    reg [31:0] perf_layer_sram_writes [0:MAX_LAYERS-1];
    /* Persistent production-path evidence captured at each DS layer fence. */
    reg [31:0] persistent_ds_preload [0:5];
    reg [31:0] persistent_ds_compute [0:5];
    reg [31:0] persistent_ds_commit [0:5];
    reg [31:0] persistent_ds_reads [0:5];
    reg [31:0] persistent_ds_writes [0:5];
    reg [31:0] persistent_ds_reuse [0:5];
    reg [31:0] persistent_ds_tokens [0:5];
    reg [31:0] persistent_ds_commit_prev;
    reg [31:0] persistent_ds_reads_prev;
    reg [31:0] persistent_ds_reuse_prev;
    reg [31:0] persistent_ds_tokens_prev;

    function [31:0] expected_sram_reads_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                0: expected_sram_reads_for_layer = 32'd0;
                1: expected_sram_reads_for_layer = 32'd23104;
                2: expected_sram_reads_for_layer = 32'd34848;
                3: expected_sram_reads_for_layer = 32'd20736;
                4: expected_sram_reads_for_layer = 32'd16384;
                5: expected_sram_reads_for_layer = 32'd8192;
                6: expected_sram_reads_for_layer = 32'd8192;
                7: expected_sram_reads_for_layer = 32'd4096;
                8: expected_sram_reads_for_layer = 32'd256;
                default: expected_sram_reads_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_sram_writes_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                0: expected_sram_writes_for_layer = 32'd16384;
                // DS outputs use one aligned four-byte internal-SRAM
                // transaction when four consecutive channels are ready.
                1: expected_sram_writes_for_layer = 32'd8192;
                2: expected_sram_writes_for_layer = 32'd4096;
                3: expected_sram_writes_for_layer = 32'd4096;
                4: expected_sram_writes_for_layer = 32'd2048;
                5: expected_sram_writes_for_layer = 32'd2048;
                6: expected_sram_writes_for_layer = 32'd1024;
                7: expected_sram_writes_for_layer = 32'd256;
                8: expected_sram_writes_for_layer = 32'd0;
                default: expected_sram_writes_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_ext_reads_for_layer;
        input integer layer_idx;
        begin
            case (layer_idx)
                // Unified Stem reads the 32x32x3 source image directly as
                // 3072 scalar 32-bit transactions (plus 480 parameter
                // words).  The legacy tiled Stem replays its 10x10 halos,
                // hence its larger historical count.
                0: expected_ext_reads_for_layer =
                                                   (USE_UNIFIED64_STEM || USE_SHARED_UNIFIED64) ?
                                                   32'd3552 : 32'd4812;
                1: expected_ext_reads_for_layer = 32'd800;
                2: expected_ext_reads_for_layer = 32'd2624;
                3: expected_ext_reads_for_layer = 32'd5056;
                4: expected_ext_reads_for_layer = 32'd9344;
                5: expected_ext_reads_for_layer = 32'd18304;
                6: expected_ext_reads_for_layer = 32'd35072;
                7: expected_ext_reads_for_layer = 32'd0;
                8: expected_ext_reads_for_layer = 32'd2590;
                default: expected_ext_reads_for_layer = 32'd0;
            endcase
        end
    endfunction

    function [31:0] expected_ext_writes_for_layer;
        input integer layer_idx;
        begin
            expected_ext_writes_for_layer = (layer_idx == 8) ? 32'd10 : 32'd0;
        end
    endfunction

    cnn_top #(
        .USE_UNIFIED64_DS(USE_UNIFIED64_DS),
        .USE_UNIFIED64_STEM(USE_UNIFIED64_STEM),
        .USE_SHARED_UNIFIED64(USE_SHARED_UNIFIED64),
        .USE_PERSISTENT_DS(USE_PERSISTENT_DS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_type(cmd_type),
        .desc_base_addr(desc_base_addr),
        .layer_num(layer_num),
        .status(status),
        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
            mem_req_ready <= 1'b0;
            bus_phase <= 0;
        end else begin
            bus_phase <= bus_phase + 1;
            mem_req_ready <= MEM_READY_STALLS ?
                              ((bus_phase % 7) != 0) : 1'b1;
            mem_resp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem[mem_req_addr[19:2]] <= mem_req_wdata;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem[mem_req_addr[19:2]];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            perf_layer_active <= 1'b0;
            perf_layer_idx <= 8'd0;
            mem_read_total <= 0;
            mem_write_total <= 0;
            desc_read_total <= 0;
            layer_read_total <= 0;
            layer_write_total <= 0;
            sram_read_total <= 0;
            sram_word_read_total <= 0;
            sram_write_total <= 0;
            for (perf_i = 0; perf_i < MAX_LAYERS; perf_i = perf_i + 1) begin
                perf_layer_cycles[perf_i] <= 32'd0;
                perf_layer_reads[perf_i] <= 32'd0;
                perf_layer_writes[perf_i] <= 32'd0;
                perf_layer_sram_reads[perf_i] <= 32'd0;
                perf_layer_sram_word_reads[perf_i] <= 32'd0;
                perf_layer_sram_writes[perf_i] <= 32'd0;
            end
            for (perf_i = 0; perf_i < 6; perf_i = perf_i + 1) begin
                persistent_ds_preload[perf_i] <= 32'd0;
                persistent_ds_compute[perf_i] <= 32'd0;
                persistent_ds_commit[perf_i] <= 32'd0;
                persistent_ds_reads[perf_i] <= 32'd0;
                persistent_ds_writes[perf_i] <= 32'd0;
                persistent_ds_reuse[perf_i] <= 32'd0;
                persistent_ds_tokens[perf_i] <= 32'd0;
            end
            persistent_ds_commit_prev <= 32'd0;
            persistent_ds_reads_prev <= 32'd0;
            persistent_ds_reuse_prev <= 32'd0;
            persistent_ds_tokens_prev <= 32'd0;
        end else begin
            if (dut.layer_start) begin
                perf_layer_active <= 1'b1;
                perf_layer_idx <= dut.current_layer;
                if (dut.current_layer < MAX_LAYERS) begin
                    perf_layer_cycles[dut.current_layer] <= 32'd1;
                    perf_layer_reads[dut.current_layer] <= 32'd0;
                    perf_layer_writes[dut.current_layer] <= 32'd0;
                    perf_layer_sram_reads[dut.current_layer] <= 32'd0;
                    perf_layer_sram_word_reads[dut.current_layer] <= 32'd0;
                    perf_layer_sram_writes[dut.current_layer] <= 32'd0;
                end
            end else if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                perf_layer_cycles[perf_layer_idx] <= perf_layer_cycles[perf_layer_idx] + 32'd1;
            end

            if (dut.layer_sram_input_rd_en) begin
                sram_read_total <= sram_read_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_reads[perf_layer_idx] <=
                        perf_layer_sram_reads[perf_layer_idx] + 32'd1;
                end
            end
            if (dut.layer_sram_input_rd_word_en) begin
                if (sram_word_read_total < 80)
                    $display("WORD layer=%0d addr=%0d idx=%0d ch=%0d x=%0d y=%0d cin=%0d",
                             perf_layer_idx, dut.layer_sram_input_rd_word_addr,
                             dut.u_layer_runner.tiled_load_idx,
                             dut.u_layer_runner.tiled_load_channel,
                             dut.u_layer_runner.tiled_load_x,
                             dut.u_layer_runner.tiled_load_y,
                             dut.u_layer_runner.in_c_reg);
                sram_word_read_total <= sram_word_read_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_word_reads[perf_layer_idx] <=
                        perf_layer_sram_word_reads[perf_layer_idx] + 32'd1;
                    perf_layer_sram_reads[perf_layer_idx] <=
                        perf_layer_sram_reads[perf_layer_idx] + 32'd4;
                end
            end
            if (dut.layer_sram_output_wr_en) begin
                sram_write_total <= sram_write_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_writes[perf_layer_idx] <=
                        perf_layer_sram_writes[perf_layer_idx] + 32'd1;
                end
            end
            if (dut.layer_sram_output_wr4_en) begin
                sram_write_total <= sram_write_total + 1;
                if (perf_layer_active && perf_layer_idx < MAX_LAYERS) begin
                    perf_layer_sram_writes[perf_layer_idx] <=
                        perf_layer_sram_writes[perf_layer_idx] + 32'd1;
                end
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    mem_write_total <= mem_write_total + 1;
                    if (perf_layer_active) begin
                        layer_write_total <= layer_write_total + 1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_writes[perf_layer_idx] <= perf_layer_writes[perf_layer_idx] + 32'd1;
                        end
                    end
                end else begin
                    mem_read_total <= mem_read_total + 1;
                    if (perf_layer_active) begin
                        layer_read_total <= layer_read_total + 1;
                        if (perf_layer_idx < MAX_LAYERS) begin
                            perf_layer_reads[perf_layer_idx] <= perf_layer_reads[perf_layer_idx] + 32'd1;
                        end
                    end else begin
                        desc_read_total <= desc_read_total + 1;
                    end
                end
            end

            if (dut.layer_done) begin
`ifdef DEBUG_SHARED_FULLNET
                if (USE_PERSISTENT_DS && USE_SHARED_UNIFIED64 &&
                    (dut.current_layer >= 1) && (dut.current_layer <= 6)) begin
                    /* current_layer is the descriptor index at layer_done;
                     * shared commit counters are cumulative across DS1..DS6. */
                    persistent_ds_preload[dut.current_layer - 1] <=
                        perf_layer_reads[dut.current_layer];
                    persistent_ds_compute[dut.current_layer - 1] <=
                        perf_layer_cycles[dut.current_layer];
                    persistent_ds_commit[dut.current_layer - 1] <=
                        dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg -
                        persistent_ds_commit_prev;
                    persistent_ds_commit_prev <=
                        dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg;
                    persistent_ds_reads[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_source_window_reads -
                        persistent_ds_reads_prev;
                    persistent_ds_writes[dut.current_layer - 1] <=
                        perf_layer_sram_writes[dut.current_layer];
                    persistent_ds_reuse[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_window_reuse -
                        persistent_ds_reuse_prev;
                    persistent_ds_tokens[dut.current_layer - 1] <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_token_count -
                        persistent_ds_tokens_prev;
                    persistent_ds_reads_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_source_window_reads;
                    persistent_ds_reuse_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_window_reuse;
                    persistent_ds_tokens_prev <=
                        dut.u_layer_runner.u_ds_block_engine.persistent_token_count;
                end
`endif
                perf_layer_active <= 1'b0;
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            cmd_valid = 1'b0;
            cmd_type = 2'd0;
            mem_resp_valid = 1'b0;
            mem_resp_rdata = 32'd0;
            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    task start_and_wait_done;
        begin
            while (!cmd_ready) begin
                @(posedge clk);
            end
            @(negedge clk);
            cmd_valid = 1'b1;
            cmd_type = 2'd0;
            @(negedge clk);
            cmd_valid = 1'b0;

            timeout = 0;
            while (!status[1] && timeout < 10000000) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (timeout >= 10000000) begin
                $display("FAIL tb_cnn_top_fullnet_sram_datapath timeout case=%0d status=%08x", case_idx, status);
`ifdef DEBUG_SHARED_FULLNET
                $display("DBG runner state=%0d op_type=%08x stem=%0d ds=%0d tiled=%0d layer_busy=%0d layer_done=%0d layer_error=%0d",
                         dut.u_layer_runner.state, dut.u_layer_runner.op_type_reg,
                         dut.u_layer_runner.op_is_stem_reg, dut.u_layer_runner.op_is_ds_reg,
                         dut.u_layer_runner.tiled_spatial_mode, dut.layer_busy,
                         dut.layer_done, dut.layer_error);
                $display("DBG runner starts stem=%0d ds=%0d unified_stem busy=%0d done=%0d cfg_ready=%0d",
                         dut.u_layer_runner.stem_start, dut.u_layer_runner.ds_start,
                         dut.u_layer_runner.unified_stem_busy,
                         dut.u_layer_runner.unified_stem_done,
                         dut.u_layer_runner.unified_stem_cfg_ready);
                $display("DBG stem state=%0d busy=%0d done=%0d block=(%0d,%0d) cell_k=%0d load=(%0d,%0d) req=%0d resp=%0d tok=%0d mac=%0d commits=%0d",
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.state,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.busy,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.done,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.block_x,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.block_y,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.cell_k_idx,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.load_row,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.load_word,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.source_req_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.source_resp_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.token_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.mac_count_reg,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.output_commit_count_reg);
                $display("DBG shared state active=%0d drain=%0d in_stage=%0d bank_live=%0d/%0d ready=%0d/%0d issue=%0d mode=%0d token=%0d commit=%0d rq_stage=%0d rq_busy=%0d valid_out=%0d",
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.current_active,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.drain_active,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_valid,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_live0,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_live1,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_ready0,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.bank_ready1,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.issue_idx,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.drain_mode,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.rq_stage_valid,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.rq_busy,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.valid_out);
                $display("DBG shared io in v/r=%0d/%0d out v/r=%0d/%0d stem state/v/r=%0d/%0d/%0d core mode=%0d k=%0d",
                         dut.u_layer_runner.shared_stem_valid_in,
                         dut.u_layer_runner.shared_stem_ready_in,
                         dut.u_layer_runner.shared_stem_out_valid,
                         dut.u_layer_runner.shared_stem_out_ready,
                         dut.u_layer_runner.gen_unified64_stem.u_stem_unified64.state,
                         dut.u_layer_runner.shared_core_valid_in,
                         dut.u_layer_runner.shared_core_ready_in,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_mode,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_last,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.in_stage_first);
`endif
                $fatal;
            end
            case_hw_cycles = status[31:8];
        end
    endtask

    initial begin
        rst_n = 1'b0;
        cmd_valid = 1'b0;
        cmd_type = 2'd0;
        desc_base_addr = 32'd0;
        layer_num = 32'd0;
        mem_req_ready = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        total_checks = 0;
        error_count = 0;
        case_errors = 0;
        case_hw_cycles = 32'd0;

        fd = $fopen("tests/vectors/cnn_top_fullnet_sram_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/cnn_top_fullnet_sram_cases.hex");
            $fatal;
        end
        report_fd = $fopen("build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt", "w");
        layer_metrics_fd = $fopen("build/reports/fullnet_layer_metrics.csv", "w");
        persistent_ds_metrics_fd = $fopen("build/reports/fullnet_persistent_ds_metrics.csv", "w");
        hw_logits_fd = $fopen("build/reports/fullnet_hw_logits.hex", "w");
        expected_logits_fd = $fopen("build/reports/fullnet_expected_logits.hex", "w");
        if ((report_fd == 0) || (layer_metrics_fd == 0) ||
            (persistent_ds_metrics_fd == 0) ||
            (hw_logits_fd == 0) || (expected_logits_fd == 0)) begin
            $display(
                "ERROR: cannot create fullnet reports metrics=%0d layers=%0d hw=%0d expected=%0d",
                report_fd, layer_metrics_fd, hw_logits_fd, expected_logits_fd
            );
            $fatal;
        end
        if (layer_metrics_fd != 0) begin
            $fwrite(
                layer_metrics_fd,
                "case,layer,cycles,mem_reads,mem_writes,sram_reads,sram_scalar_reads,sram_word_reads,sram_writes\n"
            );
        end
        if (persistent_ds_metrics_fd != 0) begin
            $fwrite(persistent_ds_metrics_fd,
                    "case,ds_layer,preload_words,compute_cycles,commit_blocks,source_window_reads,sram_writes,window_reuse,tokens\n");
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            case_errors = 0;
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                mem[i] = 32'd0;
            end
            for (i = 0; i < MAX_EXPECTED; i = i + 1) begin
                expected_addr[i] = 32'd0;
                expected_data[i] = 8'd0;
            end

            scan_count = $fscanf(fd, "%h %d %d %d\n", desc_base_addr, layer_num_file, entry_count, expected_count);
            if (scan_count != 4) begin
                $display("ERROR: bad fullnet sram header case=%0d scan=%0d", case_idx, scan_count);
                $fatal;
            end
            layer_num = layer_num_file[31:0];

            for (i = 0; i < entry_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_data);
                if (scan_count != 2) begin
                    $display("ERROR: bad memory entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                mem[tmp_addr[19:2]] = tmp_data;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                scan_count = $fscanf(fd, "%h %h\n", tmp_addr, tmp_i8);
                if (scan_count != 2) begin
                    $display("ERROR: bad expected entry case=%0d index=%0d scan=%0d", case_idx, i, scan_count);
                    $fatal;
                end
                expected_addr[i] = tmp_addr;
                expected_data[i] = tmp_i8;
            end

            reset_dut();
            start_and_wait_done();

            if (status[2]) begin
                $display("MISMATCH case=%0d unexpected error status=%08x", case_idx, status);
                error_count = error_count + 1;
                case_errors = case_errors + 1;
            end

            for (i = 0; i < expected_count; i = i + 1) begin
                if (expected_logits_fd != 0) begin
                    $fwrite(expected_logits_fd, "%02x\n", expected_data[i]);
                end
                if (hw_logits_fd != 0) begin
                    $fwrite(hw_logits_fd, "%02x\n", mem[expected_addr[i][19:2]][7:0]);
                end
                if (mem[expected_addr[i][19:2]][7:0] !== expected_data[i]) begin
                    $display(
                        "MISMATCH case=%0d i=%0d addr=%08x expected=%0d actual=%0d",
                        case_idx,
                        i,
                        expected_addr[i],
                        $signed(expected_data[i]),
                        $signed(mem[expected_addr[i][19:2]][7:0])
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                total_checks = total_checks + 1;
            end
            for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                if (perf_layer_sram_word_reads[i] != 0)
                    $display("PERF layer=%0d scalar_sram_reads=%0d word_reads=%0d",
                             i,
                             perf_layer_sram_reads[i] -
                             (perf_layer_sram_word_reads[i] * 4),
                             perf_layer_sram_word_reads[i]);
                if (perf_layer_reads[i] !== expected_ext_reads_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d ext_reads got=%0d expected=%0d",
                        i, perf_layer_reads[i], expected_ext_reads_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (perf_layer_writes[i] !== expected_ext_writes_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d ext_writes got=%0d expected=%0d",
                        i, perf_layer_writes[i], expected_ext_writes_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (perf_layer_sram_reads[i] !== expected_sram_reads_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d sram_reads got=%0d expected=%0d",
                        i, perf_layer_sram_reads[i], expected_sram_reads_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
                if (perf_layer_sram_writes[i] !== expected_sram_writes_for_layer(i)) begin
                    $display(
                        "MISMATCH layer=%0d sram_writes got=%0d expected=%0d",
                        i, perf_layer_sram_writes[i], expected_sram_writes_for_layer(i)
                    );
                    error_count = error_count + 1;
                    case_errors = case_errors + 1;
                end
            end
            if (report_fd != 0) begin
                $fwrite(
                    report_fd,
                    "case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d desc_reads=%0d layer_reads=%0d layer_writes=%0d sram_reads=%0d sram_scalar_reads=%0d sram_word_reads=%0d sram_logical_reads=%0d sram_writes=%0d\n",
                    case_idx,
                    case_hw_cycles,
                    expected_count,
                    case_errors,
                    status,
                    mem_read_total,
                    mem_write_total,
                    desc_read_total,
                    layer_read_total,
                    layer_write_total,
                    sram_read_total,
                    sram_read_total,
                    sram_word_read_total,
                    sram_read_total + (sram_word_read_total * 4),
                    sram_write_total
                );
            end
            if (layer_metrics_fd != 0) begin
                for (i = 0; i < layer_num_file && i < MAX_LAYERS; i = i + 1) begin
                    $fwrite(
                        layer_metrics_fd,
                        "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        case_idx,
                        i,
                        perf_layer_cycles[i],
                        perf_layer_reads[i],
                        perf_layer_writes[i],
                        perf_layer_sram_reads[i],
                        perf_layer_sram_reads[i] -
                        (perf_layer_sram_word_reads[i] * 4),
                        perf_layer_sram_word_reads[i],
                        perf_layer_sram_writes[i]
                    );
                end
            end
            if (persistent_ds_metrics_fd != 0 && USE_PERSISTENT_DS && USE_SHARED_UNIFIED64) begin
                for (i = 0; i < 6; i = i + 1) begin
                    $fwrite(persistent_ds_metrics_fd,
                            "%0d,DS%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                            case_idx, i + 1,
                            persistent_ds_preload[i], persistent_ds_compute[i],
                            persistent_ds_commit[i], persistent_ds_reads[i],
                            persistent_ds_writes[i], persistent_ds_reuse[i],
                            persistent_ds_tokens[i]);
                    $display("PERSISTENT_DS layer=DS%0d preload_words=%0d compute_cycles=%0d commit_blocks=%0d source_window_reads=%0d sram_writes=%0d window_reuse=%0d tokens=%0d",
                             i + 1,
                             persistent_ds_preload[i], persistent_ds_compute[i],
                             persistent_ds_commit[i], persistent_ds_reads[i],
                             persistent_ds_writes[i], persistent_ds_reuse[i],
                             persistent_ds_tokens[i]);
                end
            end
            $display(
                "PERF tb_cnn_top_fullnet_sram_datapath case=%0d hw_cycles=%0d checks=%0d errors=%0d status=%08x mem_reads=%0d mem_writes=%0d",
                case_idx,
                case_hw_cycles,
                expected_count,
                case_errors,
                status,
                mem_read_total,
                mem_write_total
            );
`ifdef DEBUG_SHARED_FULLNET
            if (USE_SHARED_UNIFIED64) begin
                $display("SHARED_METRIC stem_tok=%0d stem_mac=%0d stem_commit=%0d ds_tok=%0d ds_mac=%0d ds_commit=%0d total_tok=%0d total_commit=%0d",
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_token_count_reg * 64,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.stem_commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_token_count_reg * 64,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.ds_commit_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.token_count_reg,
                         dut.u_layer_runner.gen_shared_unified64_core.u_shared_compute_array.commit_count_reg);
            end
`endif
        end

        $fclose(fd);
        if (report_fd != 0) begin
            $fclose(report_fd);
        end
        if (layer_metrics_fd != 0) begin
            $fclose(layer_metrics_fd);
        end
        if (persistent_ds_metrics_fd != 0) begin
            $fclose(persistent_ds_metrics_fd);
        end
        if (hw_logits_fd != 0) begin
            $fclose(hw_logits_fd);
        end
        if (expected_logits_fd != 0) begin
            $fclose(expected_logits_fd);
        end
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_cnn_top_fullnet_sram_datapath cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_cnn_top_fullnet_sram_datapath checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
