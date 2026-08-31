# Vivado Initial Synthesis Report

- Date: 2026-08-25T21:21:30+0800
- Tool: Vivado 2025.2
- Top module: `cnn_top`
- Part: `xc7z020clg400-1`
- Clock constraint: 10.000 ns
- Status: PASSED
- Timing summary: PASSED
- Clock utilization report: PASSED
- Checkpoint write: PASSED

## Primary Site Utilization

| Metric | Used |
| --- | ---: |
| CLB LUTs | unknown |
| LUT as logic | 28333 |
| LUT as memory | 1736 |
| CLB registers | unknown |
| Block RAM tiles | 46 |
| DSPs | 43 |

## Primitive Instance Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 35247 |
| FF/latch primitive cells | 20728 |
| BRAM-like primitive cells | 46 |
| DSP primitive cells | 0 |
| Worst observed max-path slack | -6.858 ns |

## Generated Reports

- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `build/reports/vivado_cnn_top/timing_summary.txt`
- `build/reports/vivado_cnn_top/clock_utilization.txt`
- `build/reports/vivado_cnn_top/cnn_top_synth.dcp` if checkpoint write passed

## Notes

The primary resource figures above come from report_utilization site rows. Primitive-instance counts use get_cells and are a different accounting basis; do not report them as CLB LUT utilization.

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
