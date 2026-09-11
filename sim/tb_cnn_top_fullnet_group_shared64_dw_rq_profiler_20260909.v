`timescale 1ns/1ps
`default_nettype none

/*
 * Simulation-only profiler for the local DW requant adapter ingress.
 *
 * The checked-in full-network harness owns reset, vector loading, exact
 * checks, and termination.  This wrapper only observes the adapter's
 * ready/valid boundary and the group-published sweep's publication fence.
 * No DUT signal is driven and no production source is changed.
 */
module tb_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909;
    localparam integer LAYERS = 6;
    localparam integer CAUSAL_WINDOW = 16;

    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        .USE_SHARED_UNIFIED64(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();

    wire p_clk = u_fullnet.clk;
    wire p_rst_n = u_fullnet.rst_n;
    wire [7:0] obs_layer = u_fullnet.dut.current_layer;
    wire obs_layer_start = u_fullnet.dut.layer_start &&
                           u_fullnet.dut.group_layer_select;
    wire obs_layer_done = u_fullnet.dut.group_layer_done;

    /* The group runner has one 4x8 producer reused by all six descriptors.
     * Keep this path explicit so the profiler measures the real production
     * local-requant adapter rather than a standalone approximation. */
    wire rq_valid_in =
        u_fullnet.dut.gen_group_shared64_ds_runner
        .u_group_shared64_runner_adapter.u_group_adapter.u_producer
        .u_4x8.gen_local_requant.u_requant_local.valid_in;
    wire rq_ready_in =
        u_fullnet.dut.gen_group_shared64_ds_runner
        .u_group_shared64_runner_adapter.u_group_adapter.u_producer
        .u_4x8.gen_local_requant.u_requant_local.ready_in;
    wire rq_bundle_blocked = rq_valid_in && !rq_ready_in;
    wire rq_bundle_fire = rq_valid_in && rq_ready_in;

    wire sweep_unpublished_wait =
        (u_fullnet.dut.gen_group_shared64_ds_runner
         .u_group_shared64_runner_adapter.u_group_adapter.u_sweep.state == 3'd1) &&
        !u_fullnet.dut.gen_group_shared64_ds_runner
         .u_group_shared64_runner_adapter.u_group_adapter.u_sweep.schedule_done_q &&
        !u_fullnet.dut.gen_group_shared64_ds_runner
         .u_group_shared64_runner_adapter.u_group_adapter.u_sweep.pw_published;

    integer cycle_count;
    integer active_layer;
    integer i;
    integer el;
    integer interval;
    integer block_run;
    integer recent_left [0:LAYERS-1];
    integer previous_accept [0:LAYERS-1];
    integer have_accept [0:LAYERS-1];
    integer adapter_valid_cycles [0:LAYERS-1];
    integer adapter_blocked_cycles [0:LAYERS-1];
    integer adapter_fire_count [0:LAYERS-1];
    integer accept_interval_count [0:LAYERS-1];
    integer accept_interval_sum [0:LAYERS-1];
    integer accept_interval_min [0:LAYERS-1];
    integer accept_interval_max [0:LAYERS-1];
    integer blocked_run_count [0:LAYERS-1];
    integer blocked_run_max [0:LAYERS-1];
    integer unpublished_wait_cycles [0:LAYERS-1];
    integer blocked_unpublished_intersection [0:LAYERS-1];
    integer blocked_after_unpublished_window [0:LAYERS-1];
    integer layer_start_count;
    integer layer_done_count;
    integer profiler_errors;
    integer fd_summary;
    integer fd_checks;

    initial begin
        cycle_count = 0;
        active_layer = 0;
        block_run = 0;
        layer_start_count = 0;
        layer_done_count = 0;
        profiler_errors = 0;
        for (i = 0; i < LAYERS; i = i + 1) begin
            recent_left[i] = 0;
            previous_accept[i] = -1;
            have_accept[i] = 0;
            adapter_valid_cycles[i] = 0;
            adapter_blocked_cycles[i] = 0;
            adapter_fire_count[i] = 0;
            accept_interval_count[i] = 0;
            accept_interval_sum[i] = 0;
            accept_interval_min[i] = 0;
            accept_interval_max[i] = 0;
            blocked_run_count[i] = 0;
            blocked_run_max[i] = 0;
            unpublished_wait_cycles[i] = 0;
            blocked_unpublished_intersection[i] = 0;
            blocked_after_unpublished_window[i] = 0;
        end
        fd_summary = 0;
        fd_checks = 0;
    end

    always @(posedge p_clk) begin
        if (!p_rst_n) begin
            cycle_count = 0;
            active_layer = 0;
        end else begin
            cycle_count = cycle_count + 1;

            if (obs_layer_start && (obs_layer >= 1) && (obs_layer <= LAYERS)) begin
                active_layer = obs_layer;
                layer_start_count = layer_start_count + 1;
            end

            if ((active_layer >= 1) && (active_layer <= LAYERS)) begin
                el = active_layer - 1;
                if (rq_valid_in)
                    adapter_valid_cycles[el] = adapter_valid_cycles[el] + 1;
                if (rq_bundle_fire) begin
                    adapter_fire_count[el] = adapter_fire_count[el] + 1;
                    if (have_accept[el] != 0) begin
                        interval = cycle_count - previous_accept[el];
                        accept_interval_count[el] = accept_interval_count[el] + 1;
                        accept_interval_sum[el] = accept_interval_sum[el] + interval;
                        if ((accept_interval_min[el] == 0) ||
                            (interval < accept_interval_min[el]))
                            accept_interval_min[el] = interval;
                        if (interval > accept_interval_max[el])
                            accept_interval_max[el] = interval;
                    end
                    previous_accept[el] = cycle_count;
                    have_accept[el] = 1;
                end

                if (sweep_unpublished_wait) begin
                    unpublished_wait_cycles[el] = unpublished_wait_cycles[el] + 1;
                    recent_left[el] = CAUSAL_WINDOW;
                end else if (recent_left[el] > 0) begin
                    recent_left[el] = recent_left[el] - 1;
                end

                if (rq_bundle_blocked) begin
                    adapter_blocked_cycles[el] = adapter_blocked_cycles[el] + 1;
                    block_run = block_run + 1;
                    if (sweep_unpublished_wait)
                        blocked_unpublished_intersection[el] =
                            blocked_unpublished_intersection[el] + 1;
                    if (recent_left[el] > 0)
                        blocked_after_unpublished_window[el] =
                            blocked_after_unpublished_window[el] + 1;
                end else if (block_run > 0) begin
                    blocked_run_count[el] = blocked_run_count[el] + 1;
                    if (block_run > blocked_run_max[el])
                        blocked_run_max[el] = block_run;
                    block_run = 0;
                end

                if (obs_layer_done) begin
                    layer_done_count = layer_done_count + 1;
                    if (block_run > 0) begin
                        blocked_run_count[el] = blocked_run_count[el] + 1;
                        if (block_run > blocked_run_max[el])
                            blocked_run_max[el] = block_run;
                        block_run = 0;
                    end
                    active_layer = 0;
                end
            end
        end
    end

    initial begin
        /* The run script creates this unique report directory. */
        fd_summary = $fopen("build/reports/dw_rq_local_profiler_20260909/adapter_profile.csv", "w");
        fd_checks = $fopen("build/reports/dw_rq_local_profiler_20260909/profiler_checks.txt", "w");
        if ((fd_summary == 0) || (fd_checks == 0))
            $fatal(1, "DW_RQ_PROFILER_OPEN_FAIL");
        $fwrite(fd_summary,
            "layer,valid_cycles,blocked_cycles,bundle_accepts,interval_count,interval_sum,interval_min,interval_max,blocked_run_count,blocked_run_max,unpublished_wait_cycles,blocked_unpublished_intersection,blocked_after_unpublished_window\n");
    end

    final begin
        integer total_blocked;
        integer total_intersection;
        integer total_causal;
        integer total_accepts;
        integer total_unpublished;
        integer checks;
        integer failures;
        total_blocked = 0;
        total_intersection = 0;
        total_causal = 0;
        total_accepts = 0;
        total_unpublished = 0;
        checks = 0;
        failures = 0;
        for (i = 0; i < LAYERS; i = i + 1) begin
            $fwrite(fd_summary, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    i + 1, adapter_valid_cycles[i], adapter_blocked_cycles[i],
                    adapter_fire_count[i], accept_interval_count[i],
                    accept_interval_sum[i], accept_interval_min[i],
                    accept_interval_max[i], blocked_run_count[i],
                    blocked_run_max[i], unpublished_wait_cycles[i],
                    blocked_unpublished_intersection[i],
                    blocked_after_unpublished_window[i]);
            $display("DW_RQ_PROFILE layer=%0d valid=%0d blocked=%0d accepts=%0d interval_count=%0d interval_sum=%0d interval_min=%0d interval_max=%0d block_runs=%0d block_max=%0d unpublished=%0d intersection=%0d causal_window=%0d",
                     i + 1, adapter_valid_cycles[i], adapter_blocked_cycles[i],
                     adapter_fire_count[i], accept_interval_count[i],
                     accept_interval_sum[i], accept_interval_min[i],
                     accept_interval_max[i], blocked_run_count[i],
                     blocked_run_max[i], unpublished_wait_cycles[i],
                     blocked_unpublished_intersection[i],
                     blocked_after_unpublished_window[i]);
            total_blocked = total_blocked + adapter_blocked_cycles[i];
            total_intersection = total_intersection + blocked_unpublished_intersection[i];
            total_causal = total_causal + blocked_after_unpublished_window[i];
            total_accepts = total_accepts + adapter_fire_count[i];
            total_unpublished = total_unpublished + unpublished_wait_cycles[i];
        end

        checks = checks + 1;
        if (layer_start_count != LAYERS) failures = failures + 1;
        checks = checks + 1;
        if (layer_done_count != LAYERS) failures = failures + 1;
        checks = checks + 1;
        if (total_accepts == 0) failures = failures + 1;
        checks = checks + 1;
        if (total_blocked < 0 || total_intersection < 0 || total_causal < 0)
            failures = failures + 1;

        $fwrite(fd_checks, "status=%s\n", (failures == 0) ? "PASS" : "FAIL");
        $fwrite(fd_checks, "checks=%0d\n", checks);
        $fwrite(fd_checks, "failures=%0d\n", failures);
        $fwrite(fd_checks, "layers_started=%0d/%0d\n", layer_start_count, LAYERS);
        $fwrite(fd_checks, "layers_done=%0d/%0d\n", layer_done_count, LAYERS);
        $fwrite(fd_checks, "adapter_bundle_accepts=%0d\n", total_accepts);
        $fwrite(fd_checks, "adapter_blocked_cycles=%0d\n", total_blocked);
        $fwrite(fd_checks, "sweep_unpublished_wait_cycles=%0d\n", total_unpublished);
        $fwrite(fd_checks, "blocked_unpublished_intersection=%0d\n", total_intersection);
        $fwrite(fd_checks, "blocked_after_unpublished_window=%0d\n", total_causal);
        $fwrite(fd_checks, "causal_window_cycles=%0d\n", CAUSAL_WINDOW);
        if (fd_summary != 0) $fclose(fd_summary);
        if (fd_checks != 0) $fclose(fd_checks);
        $display("DW_RQ_PROFILER_%s checks=%0d failures=%0d layers=%0d/%0d accepts=%0d blocked=%0d unpublished=%0d intersection=%0d causal_window=%0d",
                 (failures == 0) ? "PASS" : "FAIL", checks, failures,
                 layer_done_count, LAYERS, total_accepts, total_blocked,
                 total_unpublished, total_intersection, total_causal);
    end
endmodule

`default_nettype wire
