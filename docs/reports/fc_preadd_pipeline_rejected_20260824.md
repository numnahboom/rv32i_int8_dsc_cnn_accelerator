# FC bias-preadd register experiment (rejected, 2026-08-24)

## Timing target and candidate

The latest descriptor-local PW requant Explore result was used as the
comparison point: WNS `-6.997 ns`, TNS `-26365.537 ns`, WHS `+0.061 ns`.
The timing report showed the FC bias LUTRAM -> carry chain -> three-DSP
product path as the dominant endpoint family.  A task-local experiment in
`rtl/cnn/fc_unit_new.v` inserted a descriptor-local bias/accumulator sum
register before the multiplier, adding one product-issue state per output
class while preserving the external FC handshake.

## Functional gate and decision

The candidate compiled in XSim and Verilator.  The broad XSim tail test
failed with the known `actual=x` signature.  A parent-commit isolated
worktree (`ff62974`, with no candidate RTL) was run for comparison: its
Verilator fullnet result had one pre-existing mismatch, `hw_cycles=993876`.
The candidate fullnet run had seven additional wrong outputs (all zero),
`hw_cycles=995221`, and therefore failed the candidate-specific functional
gate.  The candidate was reverted and is not retained.

Commands:

```text
& .\scripts\run_cnn_xsim.ps1 -Tests tb_cnn_top_tail_sram_datapath
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" SIM_LOG_DIR=build/reports/sim_fc_split_fullnet2 ./scripts/run_all_sims.sh'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project_parent_compare && SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" SIM_LOG_DIR=build/reports/parent_compare ./scripts/run_all_sims.sh'
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
```

The candidate routed fully with zero unrouted nets and clean hold:

| result | WNS | TNS | WHS | THS | route |
|---|---:|---:|---:|---:|---|
| candidate | -6.840 ns | -24415.678 ns | +0.040 ns | 0.000 ns | 0 unrouted |
| descriptor-local baseline | -6.997 ns | -26365.537 ns | +0.061 ns | 0.000 ns | 0 unrouted |

The timing result improved WNS by `+0.157 ns` and TNS by `+1949.859 ns`,
but the functional regression failed, so timing benefit is insufficient.
The candidate run reported 28,834 LUT, 19,592 FF, 46 BRAM, 50 DSP and
vectorless total on-chip power `0.219 W`; these are routed OOC estimates,
not board measurements.  The candidate fullnet cycle count was 995,221,
which is below 2M but is not accepted because of the output mismatches.

## Evidence locations

- Candidate routed reports: `build/reports/vivado_cnn_top_impl/runs/20260824T181131533-4516/`
- Candidate fullnet log: `build/reports/sim_fc_split_fullnet2/`
- Parent isolated fullnet log: `D:\Stuff\Project_parent_compare\build\reports\parent_compare/`

The working tree contains no retained FC RTL change from this experiment.
