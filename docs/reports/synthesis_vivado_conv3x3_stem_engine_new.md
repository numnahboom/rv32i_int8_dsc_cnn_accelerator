# Vivado Initial Synthesis Report

- Date: 2026-08-25T16:50:58+0800
- Tool: Vivado 2025.2
- Top module: `conv3x3_stem_engine_new`
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
| LUT as logic | 1174 |
| LUT as memory | 484 |
| CLB registers | unknown |
| Block RAM tiles | 0 |
| DSPs | 13 |

## Primitive Instance Quick Counts

| Metric | Value |
| --- | ---: |
| LUT primitive cells | 1318 |
| FF/latch primitive cells | 836 |
| BRAM-like primitive cells | 0 |
| DSP primitive cells | 0 |
| Worst observed max-path slack | -4.179 ns |

## Generated Reports

- `build/reports/vivado_conv3x3_stem_engine_new/utilization.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/utilization_hierarchical.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/timing_summary.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/clock_utilization.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/conv3x3_stem_engine_new_synth.dcp` if checkpoint write passed

## Notes

The primary resource figures above come from report_utilization site rows. Primitive-instance counts use get_cells and are a different accounting basis; do not report them as CLB LUT utilization.

This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints.
