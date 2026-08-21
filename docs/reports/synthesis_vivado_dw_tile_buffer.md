# Vivado Initial Synthesis Report

- Date: 2026-06-15T14:43:33+0800
- Tool: Vivado 2021.2
- Top module: `dw_tile_buffer`
- Part: `xck26-sfvc784-2LV-c`
- Clock constraint: 10.000 ns
- Status: PASSED
- Timing summary: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Clock utilization report: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Checkpoint write: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device


## Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 50272 |
| FF/latch primitive cells | 64 |
| BRAM-like primitive cells | 0 |
| DSP primitive cells | 0 |
| Worst observed max-path slack | unknown ns |

## Generated Reports

- `build/reports/vivado_dw_tile_buffer/utilization.txt`
- `build/reports/vivado_dw_tile_buffer/utilization_hierarchical.txt`
- `build/reports/vivado_dw_tile_buffer/timing_summary.txt`
- `build/reports/vivado_dw_tile_buffer/clock_utilization.txt`
- `build/reports/vivado_dw_tile_buffer/dw_tile_buffer_synth.dcp` if checkpoint write passed

## Notes

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
