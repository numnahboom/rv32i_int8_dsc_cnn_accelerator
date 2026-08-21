# Vivado Initial Synthesis Report

- Date: 2026-08-18T11:45:33+0800
- Tool: Vivado 2021.2
- Top module: `cnn_top`
- Part: `xck26-sfvc784-2LV-c`
- Clock constraint: 10.000 ns
- Status: PASSED
- Timing summary: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Clock utilization report: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device

- Checkpoint write: FAILED: ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device


## Primary Site Utilization

| Metric | Used |
| --- | ---: |
| CLB LUTs | 30451 |
| LUT as logic | 28887 |
| LUT as memory | 1564 |
| CLB registers | 18558 |
| Block RAM tiles | 46 |
| DSPs | 65 |

## Primitive Instance Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 36554 |
| FF/latch primitive cells | 18558 |
| BRAM-like primitive cells | 46 |
| DSP primitive cells | 65 |
| Worst observed max-path slack | unknown ns |

## Generated Reports

- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `build/reports/vivado_cnn_top/timing_summary.txt`
- `build/reports/vivado_cnn_top/clock_utilization.txt`
- `build/reports/vivado_cnn_top/cnn_top_synth.dcp` if checkpoint write passed

## Notes

The primary resource figures above come from report_utilization site rows. Primitive-instance counts use get_cells and are a different accounting basis; do not report them as CLB LUT utilization.

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
