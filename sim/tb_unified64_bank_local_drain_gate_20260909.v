`timescale 1ns/1ps
`default_nettype none

/*
 * Gate-1 profiler for the bank-local completion/drain candidate.
 *
 * The fullnet harness owns reset, vectors, exactness, and termination.  This
 * wrapper only observes the shared64 sweep instance and proves that a bank
 * which is already complete can coexist with a MAC stage consuming the other
 * bank while the current global drain guard is false.
 */
module tb_unified64_bank_local_drain_gate_20260909;
    tb_cnn_top_fullnet_sram_datapath #(
        .USE_GROUP_SHARED64_DS(1),
        .USE_SHARED_UNIFIED64(1),
        .PACKED_WEIGHTS(1),
        .VECTOR_FILE("tests/vectors/cnn_top_fullnet_sram_cases.hex")
    ) u_fullnet ();

    wire clk = u_fullnet.clk;
    wire rst_n = u_fullnet.rst_n;
    wire bank_ready0 =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready0;
    wire bank_ready1 =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_ready1;
    wire bank_live0 =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_live0;
    wire bank_live1 =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.bank_live1;
    wire in_stage_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_valid;
    wire in_stage_bank =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.in_stage_bank;
    wire drain_active =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_active;
    wire rq_stage_valid =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.rq_stage_valid;
    wire rq_busy =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.rq_busy;
    wire mac_last_pending =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.mac_last_pending;
    wire drain_start =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.drain_start;
    wire current_active =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.current_active;
    wire current_bank =
        u_fullnet.dut.gen_group_shared64_ds_runner.u_group_shared64_runner_adapter.u_group_adapter.u_sweep.u_shared_ds.current_bank;

    integer cycle_count;
    integer window_count;
    integer window_bank0_count;
    integer window_bank1_count;
    integer drain_start_count;
    integer complete_seen_count;
    integer run_count;
    integer max_run;
    integer first_window_cycle;
    integer first_window_bank;
    integer first_window_ready0;
    integer first_window_ready1;
    integer first_window_live0;
    integer first_window_live1;
    integer first_window_stage_bank;
    integer first_window_mac_last;
    integer first_window_current_active;
    integer first_window_current_bank;

    wire bank0_complete_other_mac =
        !drain_active && !rq_stage_valid && !rq_busy && bank_ready0 && bank_live1 &&
        in_stage_valid && (in_stage_bank == 1'b1);
    wire bank1_complete_other_mac =
        !drain_active && !rq_stage_valid && !rq_busy && bank_ready1 && bank_live0 &&
        in_stage_valid && (in_stage_bank == 1'b0);
    wire complete_other_mac_window = bank0_complete_other_mac || bank1_complete_other_mac;

    initial begin
        cycle_count = 0;
        window_count = 0;
        window_bank0_count = 0;
        window_bank1_count = 0;
        drain_start_count = 0;
        complete_seen_count = 0;
        run_count = 0;
        max_run = 0;
        first_window_cycle = -1;
        first_window_bank = -1;
        first_window_ready0 = 0;
        first_window_ready1 = 0;
        first_window_live0 = 0;
        first_window_live1 = 0;
        first_window_stage_bank = 0;
        first_window_mac_last = 0;
        first_window_current_active = 0;
        first_window_current_bank = 0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            run_count = 0;
        end else begin
            cycle_count = cycle_count + 1;
            if (bank_ready0 || bank_ready1)
                complete_seen_count = complete_seen_count + 1;
            if (drain_start)
                drain_start_count = drain_start_count + 1;
            if (complete_other_mac_window) begin
                window_count = window_count + 1;
                run_count = run_count + 1;
                if (bank0_complete_other_mac)
                    window_bank0_count = window_bank0_count + 1;
                if (bank1_complete_other_mac)
                    window_bank1_count = window_bank1_count + 1;
                if (run_count > max_run)
                    max_run = run_count;
                if (first_window_cycle < 0) begin
                    first_window_cycle = cycle_count;
                    first_window_bank = bank0_complete_other_mac ? 0 : 1;
                    first_window_ready0 = bank_ready0;
                    first_window_ready1 = bank_ready1;
                    first_window_live0 = bank_live0;
                    first_window_live1 = bank_live1;
                    first_window_stage_bank = in_stage_bank;
                    first_window_mac_last = mac_last_pending;
                    first_window_current_active = current_active;
                    first_window_current_bank = current_bank;
                end
            end else begin
                run_count = 0;
            end
        end
    end

    final begin
        $display("BANK_LOCAL_DRAIN_GATE cycles=%0d complete_seen=%0d drain_start=%0d window=%0d bank0_complete_other_mac=%0d bank1_complete_other_mac=%0d max_window_run=%0d first_window_cycle=%0d first_bank=%0d ready=%0d/%0d live=%0d/%0d in_stage_bank=%0d mac_last=%0d current=%0d/%0d drain_guard=%0d/%0d/%0d",
                 cycle_count, complete_seen_count, drain_start_count, window_count,
                 window_bank0_count, window_bank1_count, max_run,
                 first_window_cycle, first_window_bank, first_window_ready0,
                 first_window_ready1, first_window_live0, first_window_live1,
                 first_window_stage_bank, first_window_mac_last,
                 first_window_current_active, first_window_current_bank,
                 drain_active, rq_stage_valid, rq_busy);
        if (window_count > 0)
            $display("PASS BANK_LOCAL_DRAIN_GATE window_proven=1 global_drain_guard_blocks_other_bank_mac=1");
        else
            $display("FAIL BANK_LOCAL_DRAIN_GATE window_proven=0");
    end
endmodule

`default_nettype wire
