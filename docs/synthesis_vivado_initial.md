# Vivado Initial Synthesis Report

- Date: 2026-07-17T13:23:23+0800
- Tool: Vivado 2021.2
- Top module: `cnn_top`
- Part: `xck26-sfvc784-2LV-c`
- Clock constraint: 10.000 ns
- Status: PASSED
- Timing summary: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Clock utilization report: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Checkpoint write: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device


## Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 49801 |
| FF/latch primitive cells | 18387 |
| BRAM-like primitive cells | 42 |
| DSP primitive cells | 60 |
| Worst observed max-path slack | unknown ns |

## Generated Reports

- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `build/reports/vivado_cnn_top/timing_summary.txt`
- `build/reports/vivado_cnn_top/clock_utilization.txt`
- `build/reports/vivado_cnn_top/cnn_top_synth.dcp` if checkpoint write passed

## Notes

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
