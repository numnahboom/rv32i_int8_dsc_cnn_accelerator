`timescale 1ns/1ps
`default_nettype none

/*
 * Simulation-only timing profiler for the C0 group-published shared64 path.
 *
 * This wrapper deliberately instantiates the checked-in full-network harness
 * instead of changing the DUT or its functional testbench.  All observations
 * are hierarchical reads of ready/valid wires and registered stage state.
 * The existing harness remains the owner of reset, vector loading, exactness
 * checking, and $finish; this module only samples and emits bounded CSVs.
 */
module tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909;
    localparam integer LAYERS = 6;
    localparam integer MAX_JOBS = 32;
    localparam integer S_IDLE = 4'd0;
    localparam integer S_WAIT_JOB = 4'd10;
    localparam integer S_JOB = 4'd9;
    localparam integer S_FILL = 4'd7;
    localparam integer S_WAIT_FILL = 4'd8;
    localparam integer S_CONTEXT = 4'd6;
    localparam integer S_CFG = 4'd5;

    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        .USE_SHARED_UNIFIED64(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();

    wire p_clk = u_fullnet.clk;
    wire p_rst_n = u_fullnet.rst_n;

    /* Stable production hierarchy used by the existing fullnet profiler. */
    wire [7:0] obs_layer = u_fullnet.dut.current_layer;
    wire obs_layer_start = u_fullnet.dut.layer_start &&
                           u_fullnet.dut.group_layer_select;
    wire obs_layer_done = u_fullnet.dut.group_layer_done;
    wire obs_layer_error = u_fullnet.dut.group_layer_error;

    wire [3:0] a_state =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.state;
    wire [7:0] a_job_seq =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.job_seq_q;
    wire [3:0] a_channel_group =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.channel_group_q;
    wire [15:0] a_macro_row =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.macro_row_q;
    wire [15:0] a_macro_col =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.macro_col_q;
    wire [15:0] a_macro_count =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.macro_count_q;
    wire [15:0] a_group_count =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.group_count_q;
    wire [15:0] a_tile_rows =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.tile_rows_q;
    wire [15:0] a_tile_cols =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.tile_cols_q;

    wire a_source_context_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.source_context_valid;
    wire a_source_context_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.source_context_ready;
    wire a_source_context_complete =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.source_context_complete;
    wire a_prefetch_context_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_context_valid;
    wire a_prefetch_context_sent =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_context_sent_q;
    wire [7:0] a_prefetch_job_seq =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_job_seq_q;
    wire a_prefetch_active =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_active_q;
    wire a_prefetch_fill_started =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_fill_started_q;
    wire a_prefetch_done =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_done_q;
    wire a_prefetch_fill_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_fill_valid;
    wire a_source_context_select_prefetch =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.source_context_select_prefetch;
    wire a_fill_start_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_start_valid;
    wire a_fill_start_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_start_ready;
    wire a_fill_done_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_done_valid;
    wire a_fill_done_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.fill_done_ready;
    wire a_prefetch_fill_done_match =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.prefetch_fill_done_match;

    wire a_producer_job_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_job_valid;
    wire a_producer_job_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_job_ready;
    wire a_producer_done_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_done_valid;
    wire a_producer_done_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_done_ready;
    wire a_producer_stream_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_stream_valid;
    wire a_producer_stream_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.producer_stream_ready;
    wire a_sweep_dw_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.sweep_dw_valid;
    wire a_sweep_dw_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.sweep_dw_ready;
    wire a_current_job_has_next =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.current_job_has_next;
    wire a_cfg_prefetch_active =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.cfg_prefetch_active_q;
    wire a_cfg_prefetch_param_phase =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.cfg_prefetch_param_phase_q;
    wire a_cfg_prefetch_read_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.cfg_prefetch_read_valid_q;
    wire [4:0] a_cfg_prefetch_resp =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.cfg_prefetch_resp_q;
    wire [7:0] a_cfg_prefetch_job_seq =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.cfg_prefetch_job_seq_q;

    wire s_request_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.request_fire;
    wire s_mem_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.mem_fire;
    wire s_mem_resp_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.mem_resp_fire;
    wire s_response_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.response_fire;
    wire s_context_active =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.context_active;
    wire s_prepared =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_source_adapter.prepared;
    wire s_idle = s_context_active && s_prepared &&
                  !s_request_fire && !s_mem_fire &&
                  !s_mem_resp_fire && !s_response_fire;

    wire sweep_dw_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.dw_fire;
    wire sweep_pw_token_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_token_fire;
    wire sweep_result_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_fire;
    wire sweep_result_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_valid;
    wire sweep_result_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_ready;
    wire [2:0] sweep_state =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.state;
    wire [31:0] sweep_core_macs =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.core_metric_macs;
    wire [7:0] sweep_pw_macro =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_macro_q;
    wire [10:0] sweep_result_pixel =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.result_pixel_idx;
    wire [15:0] sweep_output_width =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.output_width_q;
    wire [15:0] sweep_tile_cols =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.tile_cols_q;
    wire sweep_pw_weight_req_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_weight_req_valid;
    wire sweep_pw_weight_resp_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_weight_resp_valid;
    wire sweep_pw_param_req_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_param_req_valid;
    wire sweep_pw_param_resp_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_param_resp_valid;
    wire sweep_pw_token_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_token_valid;
    wire sweep_core_ready =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.core_ready;
    wire sweep_pw_published =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_published;
    wire sweep_schedule_done =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.schedule_done_q;
    wire sweep_input_done =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.input_done_q;
    wire sweep_core_busy =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.core_busy;

    wire top_output_cmd_in_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.output_cmd_in_fire;
    wire top_output_cmd_out_fire =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.output_cmd_out_fire;
    wire top_sram_output_wr4_en =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.sram_output_wr4_en;
    wire [14:0] top_output_cmd_addr_q =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.output_cmd_addr_q;
    wire [15:0] top_shape_output_base_q =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.output_base_r[15:0];
    wire [15:0] top_shape_output_channels_q =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.output_channels_r;

    integer cycle_count;
    integer active_layer;
    integer layer_start_count;
    integer layer_done_count;
    integer obs_event_count;
    integer obs_error_count;
    integer i, j, k;
    integer el, ej;
    integer source_layer, source_job;
    integer fd_jobs, fd_layers, fd_checks, fd_events;

    function integer job_for_pixel;
        input integer pixel_index;
        input integer output_width;
        input integer tile_cols;
        input integer group_count;
        integer gy, gx, macro_index;
        begin
            if ((output_width <= 0) || (tile_cols <= 0) || (group_count <= 0))
                job_for_pixel = -1;
            else begin
                gy = pixel_index / output_width;
                gx = pixel_index - (gy * output_width);
                macro_index = (gy / 4) * tile_cols + (gx / 8);
                job_for_pixel = macro_index * group_count + group_count - 1;
            end
        end
    endfunction

    function integer job_for_output_addr;
        input integer output_addr;
        input integer output_base;
        input integer output_channels;
        input integer output_width;
        input integer tile_cols;
        input integer group_count;
        integer pixel_index;
        begin
            if ((output_channels <= 0) || (output_addr < output_base))
                job_for_output_addr = -1;
            else begin
                pixel_index = (output_addr - output_base) / output_channels;
                job_for_output_addr = job_for_pixel(pixel_index, output_width,
                                                    tile_cols, group_count);
            end
        end
    endfunction

    integer layer_start_cycle [0:LAYERS-1];
    integer layer_done_cycle [0:LAYERS-1];
    integer layer_state_cycles [0:LAYERS-1][0:15];
    integer layer_source_req [0:LAYERS-1];
    integer layer_source_mem_req [0:LAYERS-1];
    integer layer_source_resp [0:LAYERS-1];
    integer layer_source_producer_resp [0:LAYERS-1];
    integer layer_source_idle [0:LAYERS-1];
    integer layer_fill_start [0:LAYERS-1];
    integer layer_fill_done [0:LAYERS-1];
    integer layer_job_accept [0:LAYERS-1];
    integer layer_job_done [0:LAYERS-1];
    integer layer_stream_beats [0:LAYERS-1];
    integer layer_dw_beats [0:LAYERS-1];
    integer layer_pw_tokens [0:LAYERS-1];
    integer layer_result_tokens [0:LAYERS-1];
    integer layer_output_cmd_in [0:LAYERS-1];
    integer layer_output_cmd_out [0:LAYERS-1];
    integer layer_sram_writes [0:LAYERS-1];
    integer layer_sweep_state_cycles [0:LAYERS-1][0:6];
    integer layer_sweep_weight_req [0:LAYERS-1];
    integer layer_sweep_weight_resp [0:LAYERS-1];
    integer layer_sweep_param_req [0:LAYERS-1];
    integer layer_sweep_param_resp [0:LAYERS-1];
    integer layer_sweep_token_wait [0:LAYERS-1];
    integer layer_sweep_unpublished_wait [0:LAYERS-1];
    integer layer_sweep_dw_blocked [0:LAYERS-1];

    integer job_seen [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_ctx_valid [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_ctx_accept [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_ctx_complete [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_fill_start [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_fill_done [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_prefetch_start [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_prefetch_done [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_cfg_prefetch_start [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_cfg_prefetch_done [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_accept [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_done [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_stream_first [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_stream_last [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_stream_count [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_dw_first [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_dw_last [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_dw_count [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_pw_first [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_pw_last [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_pw_count [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_result_first [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_result_last [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_result_count [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_write_first [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_write_last [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_write_count [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_source_req [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_source_mem_req [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_source_resp [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_source_producer_resp [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_source_idle [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_wait_idle [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_stream_stall [0:LAYERS-1][0:MAX_JOBS-1];
    integer job_mac_snapshot [0:LAYERS-1][0:MAX_JOBS-1];

    initial begin
        cycle_count = 0;
        active_layer = 0;
        layer_start_count = 0;
        layer_done_count = 0;
        obs_event_count = 0;
        obs_error_count = 0;
        for (i = 0; i < LAYERS; i = i + 1) begin
            layer_start_cycle[i] = -1;
            layer_done_cycle[i] = -1;
            layer_source_req[i] = 0;
            layer_source_mem_req[i] = 0;
            layer_source_resp[i] = 0;
            layer_source_producer_resp[i] = 0;
            layer_source_idle[i] = 0;
            layer_fill_start[i] = 0;
            layer_fill_done[i] = 0;
            layer_job_accept[i] = 0;
            layer_job_done[i] = 0;
            layer_stream_beats[i] = 0;
            layer_dw_beats[i] = 0;
            layer_pw_tokens[i] = 0;
            layer_result_tokens[i] = 0;
            layer_output_cmd_in[i] = 0;
            layer_output_cmd_out[i] = 0;
            layer_sram_writes[i] = 0;
            layer_sweep_weight_req[i] = 0;
            layer_sweep_weight_resp[i] = 0;
            layer_sweep_param_req[i] = 0;
            layer_sweep_param_resp[i] = 0;
            layer_sweep_token_wait[i] = 0;
            layer_sweep_unpublished_wait[i] = 0;
            layer_sweep_dw_blocked[i] = 0;
            for (j = 0; j < 16; j = j + 1)
                layer_state_cycles[i][j] = 0;
            for (j = 0; j < 7; j = j + 1)
                layer_sweep_state_cycles[i][j] = 0;
            for (j = 0; j < MAX_JOBS; j = j + 1) begin
                job_seen[i][j] = 0;
                job_ctx_valid[i][j] = 0;
                job_ctx_accept[i][j] = 0;
                job_ctx_complete[i][j] = 0;
                job_fill_start[i][j] = -1;
                job_fill_done[i][j] = -1;
                job_prefetch_start[i][j] = -1;
                job_prefetch_done[i][j] = -1;
                job_cfg_prefetch_start[i][j] = -1;
                job_cfg_prefetch_done[i][j] = -1;
                job_accept[i][j] = -1;
                job_done[i][j] = -1;
                job_stream_first[i][j] = -1;
                job_stream_last[i][j] = -1;
                job_stream_count[i][j] = 0;
                job_dw_first[i][j] = -1;
                job_dw_last[i][j] = -1;
                job_dw_count[i][j] = 0;
                job_pw_first[i][j] = -1;
                job_pw_last[i][j] = -1;
                job_pw_count[i][j] = 0;
                job_result_first[i][j] = -1;
                job_result_last[i][j] = -1;
                job_result_count[i][j] = 0;
                job_write_first[i][j] = -1;
                job_write_last[i][j] = -1;
                job_write_count[i][j] = 0;
                job_source_req[i][j] = 0;
                job_source_mem_req[i][j] = 0;
                job_source_resp[i][j] = 0;
                job_source_producer_resp[i][j] = 0;
                job_source_idle[i][j] = 0;
                job_wait_idle[i][j] = 0;
                job_stream_stall[i][j] = 0;
                job_mac_snapshot[i][j] = 0;
            end
        end
    end

    always @(posedge p_clk) begin
        if (!p_rst_n) begin
            cycle_count = 0;
            active_layer = 0;
        end else begin
            cycle_count = cycle_count + 1;

            if (obs_layer_start) begin
                if ((obs_layer >= 1) && (obs_layer <= LAYERS)) begin
                    active_layer = obs_layer;
                    el = obs_layer - 1;
                    layer_start_cycle[el] = cycle_count;
                    layer_start_count = layer_start_count + 1;
                end else begin
                    obs_error_count = obs_error_count + 1;
                end
            end

            if ((active_layer >= 1) && (active_layer <= LAYERS)) begin
                el = active_layer - 1;
                if (a_state < 16)
                    layer_state_cycles[el][a_state] =
                        layer_state_cycles[el][a_state] + 1;
                if (sweep_state < 7)
                    layer_sweep_state_cycles[el][sweep_state] =
                        layer_sweep_state_cycles[el][sweep_state] + 1;
                if (sweep_pw_weight_req_valid)
                    layer_sweep_weight_req[el] =
                        layer_sweep_weight_req[el] + 1;
                if (sweep_pw_weight_resp_valid)
                    layer_sweep_weight_resp[el] =
                        layer_sweep_weight_resp[el] + 1;
                if (sweep_pw_param_req_valid)
                    layer_sweep_param_req[el] =
                        layer_sweep_param_req[el] + 1;
                if (sweep_pw_param_resp_valid)
                    layer_sweep_param_resp[el] =
                        layer_sweep_param_resp[el] + 1;
                if (sweep_pw_token_valid && !sweep_core_ready)
                    layer_sweep_token_wait[el] =
                        layer_sweep_token_wait[el] + 1;
                if ((sweep_state == 3'd1) && !sweep_schedule_done &&
                    !sweep_pw_published)
                    layer_sweep_unpublished_wait[el] =
                        layer_sweep_unpublished_wait[el] + 1;
                if (a_sweep_dw_valid && !a_sweep_dw_ready)
                    layer_sweep_dw_blocked[el] =
                        layer_sweep_dw_blocked[el] + 1;

                if (obs_layer_done) begin
                    layer_done_cycle[el] = cycle_count;
                    layer_done_count = layer_done_count + 1;
                    if (obs_layer_error)
                        obs_error_count = obs_error_count + 1;
                end

                /* Foreground context/fill events and look-ahead events carry
                 * explicit job sequence tags.  Context valid can be held;
                 * therefore it is counted separately from acceptance. */
                if (a_prefetch_context_valid) begin
                    ej = a_prefetch_job_seq;
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        job_ctx_valid[el][ej] = job_ctx_valid[el][ej] + 1;
                        if (a_source_context_ready) begin
                            job_ctx_accept[el][ej] =
                                job_ctx_accept[el][ej] + 1;
                        end
                    end
                end else if (a_state == S_CONTEXT) begin
                    ej = a_job_seq;
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        if (a_source_context_valid)
                            job_ctx_valid[el][ej] = job_ctx_valid[el][ej] + 1;
                        if (a_source_context_valid && a_source_context_ready)
                            job_ctx_accept[el][ej] =
                                job_ctx_accept[el][ej] + 1;
                    end
                end

                if (a_prefetch_fill_valid && a_fill_start_ready) begin
                    ej = a_prefetch_job_seq;
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        job_fill_start[el][ej] = cycle_count;
                        layer_fill_start[el] = layer_fill_start[el] + 1;
                    end
                end else if ((a_state == S_FILL) && a_fill_start_valid &&
                             a_fill_start_ready) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        job_fill_start[el][ej] = cycle_count;
                        layer_fill_start[el] = layer_fill_start[el] + 1;
                    end
                end

                if (a_prefetch_active && a_prefetch_fill_started &&
                    !a_prefetch_done && a_prefetch_fill_done_match &&
                    a_fill_done_valid && a_fill_done_ready) begin
                    ej = a_prefetch_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        job_fill_done[el][ej] = cycle_count;
                        job_ctx_complete[el][ej] =
                            job_ctx_complete[el][ej] + 1;
                        job_prefetch_done[el][ej] = cycle_count;
                        layer_fill_done[el] = layer_fill_done[el] + 1;
                    end
                end else if ((a_state == S_WAIT_FILL) && a_fill_done_valid &&
                             a_fill_done_ready) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        job_fill_done[el][ej] = cycle_count;
                        job_ctx_complete[el][ej] =
                            job_ctx_complete[el][ej] + 1;
                        layer_fill_done[el] = layer_fill_done[el] + 1;
                    end
                end

                if (a_producer_job_valid && a_producer_job_ready) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        job_accept[el][ej] = cycle_count;
                        layer_job_accept[el] = layer_job_accept[el] + 1;
                        /* The look-ahead command is armed at this exact
                         * admission edge; its context/fill handshakes are
                         * attributed to the target job below. */
                        if (a_current_job_has_next && (ej + 1 < MAX_JOBS)) begin
                            job_cfg_prefetch_start[el][ej+1] = cycle_count;
                        end
                    end
                    if (a_current_job_has_next && (ej + 1 < MAX_JOBS)) begin
                        job_prefetch_start[el][ej+1] = cycle_count;
                    end
                end

                if (a_producer_done_valid && a_producer_done_ready) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        job_done[el][ej] = cycle_count;
                        layer_job_done[el] = layer_job_done[el] + 1;
                        job_mac_snapshot[el][ej] = sweep_core_macs;
                    end
                end

                if (a_prefetch_context_valid && a_source_context_ready) begin
                    ej = a_prefetch_job_seq;
                    if (ej < MAX_JOBS)
                        job_prefetch_start[el][ej] = cycle_count;
                end

                if (a_cfg_prefetch_active && a_cfg_prefetch_param_phase &&
                    a_cfg_prefetch_read_valid && (a_cfg_prefetch_resp == 15)) begin
                    ej = a_cfg_prefetch_job_seq;
                    if (ej < MAX_JOBS)
                        job_cfg_prefetch_done[el][ej] = cycle_count;
                end

                if (a_producer_stream_valid && a_producer_stream_ready) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        if (job_stream_first[el][ej] < 0)
                            job_stream_first[el][ej] = cycle_count;
                        job_stream_last[el][ej] = cycle_count;
                        job_stream_count[el][ej] =
                            job_stream_count[el][ej] + 1;
                        layer_stream_beats[el] = layer_stream_beats[el] + 1;
                    end
                end else if ((a_state == S_WAIT_JOB) && (a_job_seq < MAX_JOBS)) begin
                    job_wait_idle[el][a_job_seq] =
                        job_wait_idle[el][a_job_seq] + 1;
                    if (a_producer_stream_valid && !a_producer_stream_ready)
                        job_stream_stall[el][a_job_seq] =
                            job_stream_stall[el][a_job_seq] + 1;
                end

                if (sweep_dw_fire) begin
                    ej = a_job_seq;
                    if (ej < MAX_JOBS) begin
                        job_seen[el][ej] = 1;
                        if (job_dw_first[el][ej] < 0)
                            job_dw_first[el][ej] = cycle_count;
                        job_dw_last[el][ej] = cycle_count;
                        job_dw_count[el][ej] = job_dw_count[el][ej] + 1;
                        layer_dw_beats[el] = layer_dw_beats[el] + 1;
                    end
                end
                if (sweep_pw_token_fire) begin
                    /* PW consumes the complete spatial macro after the
                     * final channel-group job has published its DW rows.
                     * Use the sweep-owned macro cursor, not runner job_seq_q:
                     * the runner may already be loading the next macro while
                     * this macro's PW schedule is draining. */
                    ej = (sweep_pw_macro * a_group_count) +
                         ((a_group_count > 0) ? (a_group_count - 1) : 0);
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        if (job_pw_first[el][ej] < 0)
                            job_pw_first[el][ej] = cycle_count;
                        job_pw_last[el][ej] = cycle_count;
                        job_pw_count[el][ej] = job_pw_count[el][ej] + 1;
                        layer_pw_tokens[el] = layer_pw_tokens[el] + 1;
                    end
                end
                if (sweep_result_fire) begin
                    ej = job_for_pixel(sweep_result_pixel, sweep_output_width,
                                       sweep_tile_cols, a_group_count);
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        if (job_result_first[el][ej] < 0)
                            job_result_first[el][ej] = cycle_count;
                        job_result_last[el][ej] = cycle_count;
                        job_result_count[el][ej] =
                            job_result_count[el][ej] + 1;
                        layer_result_tokens[el] = layer_result_tokens[el] + 1;
                    end
                end
                if (top_output_cmd_in_fire) begin
                    layer_output_cmd_in[el] = layer_output_cmd_in[el] + 1;
                end
                if (top_output_cmd_out_fire) begin
                    layer_output_cmd_out[el] = layer_output_cmd_out[el] + 1;
                end
                if (top_sram_output_wr4_en) begin
                    ej = job_for_output_addr(top_output_cmd_addr_q,
                                             top_shape_output_base_q,
                                             top_shape_output_channels_q,
                                             sweep_output_width,
                                             sweep_tile_cols, a_group_count);
                    if ((ej >= 0) && (ej < MAX_JOBS)) begin
                        job_seen[el][ej] = 1;
                        if (job_write_first[el][ej] < 0)
                            job_write_first[el][ej] = cycle_count;
                        job_write_last[el][ej] = cycle_count;
                        job_write_count[el][ej] =
                            job_write_count[el][ej] + 1;
                        layer_sram_writes[el] = layer_sram_writes[el] + 1;
                    end
                end

                /* Source traffic is tagged by the runner's registered
                 * context selector, which is the same ownership bit used by
                 * the source adapter's address mapper. */
                source_layer = el;
                source_job = a_source_context_select_prefetch ?
                             a_prefetch_job_seq : a_job_seq;
                if (source_job < MAX_JOBS) begin
                    if (s_request_fire) begin
                        job_source_req[source_layer][source_job] =
                            job_source_req[source_layer][source_job] + 1;
                        layer_source_req[source_layer] =
                            layer_source_req[source_layer] + 1;
                    end
                    if (s_mem_fire) begin
                        job_source_mem_req[source_layer][source_job] =
                            job_source_mem_req[source_layer][source_job] + 1;
                        layer_source_mem_req[source_layer] =
                            layer_source_mem_req[source_layer] + 1;
                    end
                    if (s_mem_resp_fire) begin
                        job_source_resp[source_layer][source_job] =
                            job_source_resp[source_layer][source_job] + 1;
                        layer_source_resp[source_layer] =
                            layer_source_resp[source_layer] + 1;
                    end
                    if (s_response_fire) begin
                        job_source_producer_resp[source_layer][source_job] =
                            job_source_producer_resp[source_layer][source_job] + 1;
                        layer_source_producer_resp[source_layer] =
                            layer_source_producer_resp[source_layer] + 1;
                    end
                    if (s_idle) begin
                        job_source_idle[source_layer][source_job] =
                            job_source_idle[source_layer][source_job] + 1;
                        layer_source_idle[source_layer] =
                            layer_source_idle[source_layer] + 1;
                    end
                end

                if ((a_state == S_JOB) && a_producer_job_ready &&
                    a_current_job_has_next) begin
                    /* Kept as an event counter even when the valid pulse is
                     * one cycle; this is the only bounded prefetch command. */
                    obs_event_count = obs_event_count + 1;
                end
            end
        end
    end

    initial begin
        fd_jobs = 0;
        fd_layers = 0;
        fd_checks = 0;
        fd_events = 0;
        /* The run script creates this unique directory before simulation. */
        fd_jobs = $fopen("build/reports/ds_job_timeline_20260909/job_timeline.csv", "w");
        fd_layers = $fopen("build/reports/ds_job_timeline_20260909/layer_timeline.csv", "w");
        fd_checks = $fopen("build/reports/ds_job_timeline_20260909/profiler_checks.txt", "w");
        fd_events = $fopen("build/reports/ds_job_timeline_20260909/event_counts.csv", "w");
        if ((fd_jobs == 0) || (fd_layers == 0) || (fd_checks == 0) || (fd_events == 0))
            $fatal(1, "DS_JOB_TIMELINE_OPEN_FAIL");
        $fwrite(fd_jobs,
            "layer,job,job_accept,job_done,ctx_valid,ctx_accept,ctx_complete,fill_start,fill_done,next_prefetch_start,next_prefetch_done,cfg_prefetch_start,cfg_prefetch_done,stream_first,stream_last,stream_beats,dw_first,dw_last,dw_beats,pw_first,pw_last,pw_tokens,result_first,result_last,result_tokens,write_first,write_last,output_writes,source_req,source_mem_req,source_resp,source_producer_resp,source_idle,wait_idle,stream_stall,producer_fill_overlap,producer_source_overlap,pw_stream_overlap,output_pw_overlap\n");
        $fwrite(fd_layers,
            "layer,start,done,cycles,context_events,fill_start,fill_done,jobs_accept,jobs_done,stream_beats,dw_beats,pw_tokens,result_tokens,output_in,output_out,sram_writes,source_req,source_mem_req,source_resp,source_producer_resp,source_idle,state_shape,state_sweep,state_dw_weight,state_dw_param,state_cfg,state_context,state_fill,state_wait_fill,state_job,state_wait_job,state_finish,state_wait_prefill,state_wait_cfg_prefetch,sweep_idle,sweep_run,sweep_done,sweep_param,sweep_setup_geom,sweep_setup_rows,sweep_setup_target,sweep_weight_req,sweep_weight_resp,sweep_param_req,sweep_param_resp,sweep_token_wait,sweep_unpublished_wait,sweep_dw_blocked,reserved0,reserved1,reserved2,reserved3,reserved4,reserved5,reserved6,reserved7,reserved8,reserved9\n");
        $fwrite(fd_events, "event,value\n");
    end

    final begin
        integer expected_jobs;
        integer valid_jobs;
        integer total_jobs;
        integer total_stream;
        integer total_dw;
        integer total_pw;
        integer total_result;
        integer total_writes;
        integer total_source_req;
        integer total_source_resp;
        integer next_start;
        integer next_done;
        integer overlap_a;
        integer overlap_b;
        integer overlap_c;
        integer overlap_d;
        integer checks;
        integer fail;
        integer timeline_rows;
        integer layer_cycles;
        integer layer_context_events;
        integer context_valid_seen;

        total_jobs = 0;
        total_stream = 0;
        total_dw = 0;
        total_pw = 0;
        total_result = 0;
        total_writes = 0;
        total_source_req = 0;
        total_source_resp = 0;
        timeline_rows = 0;
        fail = 0;
        checks = 0;

        for (i = 0; i < LAYERS; i = i + 1) begin
            expected_jobs = (i == 0) ? 32 :
                            (i == 1) ? 16 :
                            (i == 2) ? 32 :
                            (i == 3) ? 8 :
                            (i == 4) ? 16 : 8;
            layer_cycles = (layer_start_cycle[i] >= 0 &&
                            layer_done_cycle[i] >= layer_start_cycle[i]) ?
                           (layer_done_cycle[i] - layer_start_cycle[i] + 1) : -1;
            layer_context_events = 0;
            context_valid_seen = 0;
            for (j = 0; j < MAX_JOBS; j = j + 1) begin
                if (job_seen[i][j] != 0) begin
                    timeline_rows = timeline_rows + 1;
                    if (job_ctx_valid[i][j] != 0)
                        context_valid_seen = context_valid_seen + 1;
                    layer_context_events = layer_context_events +
                        job_ctx_accept[i][j];
                    if (j + 1 < MAX_JOBS) begin
                        next_start = job_prefetch_start[i][j+1];
                        next_done = job_prefetch_done[i][j+1];
                    end else begin
                        next_start = -1;
                        next_done = -1;
                    end
                    overlap_a = 0;
                    overlap_b = 0;
                    overlap_c = 0;
                    overlap_d = 0;
                    if (next_start >= 0 && next_done >= next_start &&
                        job_accept[i][j] >= 0 && job_done[i][j] >= job_accept[i][j]) begin
                        overlap_a = ((next_done < job_done[i][j]) ? next_done : job_done[i][j]) -
                                    ((next_start > job_accept[i][j]) ? next_start : job_accept[i][j]) + 1;
                        if (overlap_a < 0) overlap_a = 0;
                    end
                    if (j + 1 < MAX_JOBS &&
                        job_source_req[i][j+1] != 0 &&
                        job_accept[i][j] >= 0 && job_done[i][j] >= job_accept[i][j]) begin
                        /* Use the target job's source interval only when
                         * explicit events establish its bounds; otherwise
                         * leave the measured overlap at zero. */
                        overlap_b = 0;
                    end
                    if (job_stream_first[i][j] >= 0 && job_pw_last[i][j] >= job_stream_first[i][j]) begin
                        overlap_c = ((job_pw_last[i][j] < job_stream_last[i][j]) ? job_pw_last[i][j] : job_stream_last[i][j]) -
                                    ((job_pw_first[i][j] > job_stream_first[i][j]) ? job_pw_first[i][j] : job_stream_first[i][j]) + 1;
                        if (overlap_c < 0) overlap_c = 0;
                    end
                    if (job_result_first[i][j] >= 0 && job_pw_last[i][j] >= job_result_first[i][j]) begin
                        overlap_d = ((job_result_last[i][j] < job_pw_last[i][j]) ? job_result_last[i][j] : job_pw_last[i][j]) -
                                    ((job_result_first[i][j] > job_pw_first[i][j]) ? job_result_first[i][j] : job_pw_first[i][j]) + 1;
                        if (overlap_d < 0) overlap_d = 0;
                    end
                    $fwrite(fd_jobs,
                        "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        i+1, j, job_accept[i][j], job_done[i][j],
                        job_ctx_valid[i][j], job_ctx_accept[i][j],
                        job_ctx_complete[i][j], job_fill_start[i][j],
                        job_fill_done[i][j], next_start, next_done,
                        (j + 1 < MAX_JOBS) ? job_cfg_prefetch_start[i][j+1] : -1,
                        (j + 1 < MAX_JOBS) ? job_cfg_prefetch_done[i][j+1] : -1,
                        job_stream_first[i][j], job_stream_last[i][j],
                        job_stream_count[i][j], job_dw_first[i][j],
                        job_dw_last[i][j], job_dw_count[i][j],
                        job_pw_first[i][j], job_pw_last[i][j],
                        job_pw_count[i][j], job_result_first[i][j],
                        job_result_last[i][j], job_result_count[i][j],
                        job_write_first[i][j], job_write_last[i][j],
                        job_write_count[i][j], job_source_req[i][j],
                        job_source_mem_req[i][j], job_source_resp[i][j],
                        job_source_producer_resp[i][j], job_source_idle[i][j],
                        job_wait_idle[i][j], job_stream_stall[i][j],
                        overlap_a, overlap_b, overlap_c, overlap_d);
                    total_jobs = total_jobs + 1;
                    total_stream = total_stream + job_stream_count[i][j];
                    total_dw = total_dw + job_dw_count[i][j];
                    total_pw = total_pw + job_pw_count[i][j];
                    total_result = total_result + job_result_count[i][j];
                    total_writes = total_writes + job_write_count[i][j];
                    total_source_req = total_source_req + job_source_req[i][j];
                    total_source_resp = total_source_resp + job_source_resp[i][j];
                    if ((job_stream_count[i][j] != 128) ||
                        (job_dw_count[i][j] != 128) ||
                        (job_ctx_accept[i][j] > 1) ||
                        (job_ctx_complete[i][j] > 1))
                        fail = fail + 1;
                end
            end
            $fwrite(fd_layers,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                i+1, layer_start_cycle[i], layer_done_cycle[i], layer_cycles,
                layer_context_events, layer_fill_start[i], layer_fill_done[i],
                layer_job_accept[i], layer_job_done[i], layer_stream_beats[i],
                layer_dw_beats[i], layer_pw_tokens[i], layer_result_tokens[i],
                layer_output_cmd_in[i], layer_output_cmd_out[i],
                layer_sram_writes[i], layer_source_req[i],
                layer_source_mem_req[i], layer_source_resp[i],
                layer_source_producer_resp[i], layer_source_idle[i],
                layer_state_cycles[i][1], layer_state_cycles[i][2],
                layer_state_cycles[i][3], layer_state_cycles[i][4],
                layer_state_cycles[i][5], layer_state_cycles[i][6],
                layer_state_cycles[i][7], layer_state_cycles[i][8],
                layer_state_cycles[i][9], layer_state_cycles[i][10],
                layer_state_cycles[i][11], layer_state_cycles[i][12],
                layer_state_cycles[i][13],
                layer_sweep_state_cycles[i][0],
                layer_sweep_state_cycles[i][1],
                layer_sweep_state_cycles[i][2],
                layer_sweep_state_cycles[i][3],
                layer_sweep_state_cycles[i][4],
                layer_sweep_state_cycles[i][5],
                layer_sweep_state_cycles[i][6],
                layer_sweep_weight_req[i], layer_sweep_weight_resp[i],
                layer_sweep_param_req[i], layer_sweep_param_resp[i],
                layer_sweep_token_wait[i], layer_sweep_unpublished_wait[i],
                layer_sweep_dw_blocked[i],
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        end

        $fwrite(fd_events, "layer_start_count,%0d\n", layer_start_count);
        $fwrite(fd_events, "layer_done_count,%0d\n", layer_done_count);
        $fwrite(fd_events, "prefetch_commands,%0d\n", obs_event_count);
        $fwrite(fd_events, "timeline_rows,%0d\n", timeline_rows);
        $fwrite(fd_events, "jobs,%0d\n", total_jobs);
        $fwrite(fd_events, "stream_beats,%0d\n", total_stream);
        $fwrite(fd_events, "dw_beats,%0d\n", total_dw);
        $fwrite(fd_events, "pw_tokens,%0d\n", total_pw);
        $fwrite(fd_events, "result_tokens,%0d\n", total_result);
        $fwrite(fd_events, "output_writes,%0d\n", total_writes);
        $fwrite(fd_events, "source_req,%0d\n", total_source_req);
        $fwrite(fd_events, "source_resp,%0d\n", total_source_resp);

        checks = checks + 1;
        if (layer_start_count != 6) fail = fail + 1;
        checks = checks + 1;
        if (layer_done_count != 6) fail = fail + 1;
        checks = checks + 1;
        if (total_jobs != 112) fail = fail + 1;
        checks = checks + 1;
        if (total_stream != 14336) fail = fail + 1;
        checks = checks + 1;
        if (total_dw != 14336) fail = fail + 1;
        checks = checks + 1;
        if (total_writes != 21504) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.group_total_pw_tokens != 73728) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.group_total_dw_macs != 497664) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.group_total_pw_macs != 4194304) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.group_ledger_errors != 0) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.error_count != 0) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.total_checks != 10) fail = fail + 1;
        checks = checks + 1;
        if (u_fullnet.case_hw_cycles != 219970) fail = fail + 1;

        $fwrite(fd_checks, "status=%s\n", (fail == 0) ? "PASS" : "FAIL");
        $fwrite(fd_checks, "profiler_checks=%0d\n", checks);
        $fwrite(fd_checks, "profiler_failures=%0d\n", fail);
        $fwrite(fd_checks, "layers=%0d/%0d\n", layer_done_count, LAYERS);
        $fwrite(fd_checks, "jobs=%0d/112\n", total_jobs);
        $fwrite(fd_checks, "stream_beats=%0d/14336\n", total_stream);
        $fwrite(fd_checks, "dw_beats=%0d/14336\n", total_dw);
        $fwrite(fd_checks, "output_writes=%0d/21504\n", total_writes);
        $fwrite(fd_checks, "pw_tokens=%0d/73728\n", u_fullnet.group_total_pw_tokens);
        $fwrite(fd_checks, "dw_macs=%0d/497664\n", u_fullnet.group_total_dw_macs);
        $fwrite(fd_checks, "pw_macs=%0d/4194304\n", u_fullnet.group_total_pw_macs);
        $fwrite(fd_checks, "network_mac=%0d/5136896\n",
                u_fullnet.group_total_dw_macs +
                u_fullnet.group_total_pw_macs + 442368 + 2560);
        $fwrite(fd_checks, "network_ops=%0d/10273792\n",
                (u_fullnet.group_total_dw_macs +
                 u_fullnet.group_total_pw_macs + 442368 + 2560) * 2);
        $fwrite(fd_checks, "errors=%0d/0\n", u_fullnet.error_count);
        $fwrite(fd_checks, "exact_checks=%0d/10\n", u_fullnet.total_checks);
        $fwrite(fd_checks, "hw_cycles=%0d/219970\n", u_fullnet.case_hw_cycles);
        $fwrite(fd_checks, "obs_events=%0d\n", obs_event_count);
        $fwrite(fd_checks, "obs_signal_errors=%0d\n", obs_error_count);

        if (fd_jobs != 0) $fclose(fd_jobs);
        if (fd_layers != 0) $fclose(fd_layers);
        if (fd_checks != 0) $fclose(fd_checks);
        if (fd_events != 0) $fclose(fd_events);
        $display("DS_JOB_TIMELINE_%s checks=%0d failures=%0d layers=%0d jobs=%0d stream=%0d dw=%0d writes=%0d cycles=%0d",
                 (fail == 0) ? "PASS" : "FAIL", checks, fail,
                 layer_done_count, total_jobs, total_stream, total_dw,
                 total_writes, u_fullnet.case_hw_cycles);
    end
endmodule

`default_nettype wire
