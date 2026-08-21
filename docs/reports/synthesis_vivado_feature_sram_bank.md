# Vivado Initial Synthesis Report

- Date: 2026-06-14T15:06:26+0800
- Tool: Vivado 2021.2
- Top module: `feature_sram_bank`
- Part: `xck26-sfvc784-2LV-c`
- Clock constraint: 10.000 ns
- Status: PASSED
- Timing summary: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Clock utilization report: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Checkpoint write: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device


## Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 1709 |
| FF/latch primitive cells | 9 |
| BRAM-like primitive cells | 0 |
| DSP primitive cells | 0 |
| Worst observed max-path slack | unknown ns |

## Generated Reports

- `build/reports/vivado_feature_sram_bank/utilization.txt`
- `build/reports/vivado_feature_sram_bank/utilization_hierarchical.txt`
- `build/reports/vivado_feature_sram_bank/timing_summary.txt`
- `build/reports/vivado_feature_sram_bank/clock_utilization.txt`
- `build/reports/vivado_feature_sram_bank/feature_sram_bank_synth.dcp` if checkpoint write passed

## Notes

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
