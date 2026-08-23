# Standalone DSBlock XSim reconciliation

Date: 2026-08-23  
Tool: Vivado 2025.2 XSim; comparison run with WSL Verilator 5.020

## Diagnosis

The 60 mismatches were not caused by commit `fbea96a` (`fc_unit_new.v`): the
failing test does not instantiate `fc_unit_new`. They were introduced by the
earlier `9c6a694` `dw_mac_lanes.v` change that replaced two direct
`row_sum(lane, cycle_idx)` calls with a generated continuous wire array
`row_sum_w`. Vivado XSim reproduced 60 one-count rounding differences in case
6 (all at pixel 0, output channels 145--233); WSL Verilator passed the same
RTL, so the previous Verilator-only result was insufficient evidence.

The smallest semantic-safe reconciliation removes that generated wire and
restores the direct function calls. This preserves the original three-cycle
MAC protocol and arithmetic definition. `fc_unit_new.v` is unchanged.

## Verification

After the reconciliation:

```text
Vivado 2025.2 XSim:
  tb_ds_block_tile_engine_new: PASS cases=7 checks=2191
  tb_dw_mac_lanes:             PASS cases=4 checks=10
  tb_cnn_top_fullnet_sram_datapath: PASS cases=1 checks=10
  fullnet: hw_cycles=993869, total_macs=5136896, logits=10/10
  PASS cnn_xsim_regression tests=2

WSL Verilator:
  tb_ds_block_tile_engine_new: PASS cases=7 checks=2191
```

The full selected XSim command was run separately for the standalone test and
for the affected MAC plus full-network tests using
`scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin`.

Residual risk: removing the generated net gives up the LUT-sharing/timing
optimization from `9c6a694`; any replacement must be checked in both Vivado
XSim and Verilator, not only in Verilator.
