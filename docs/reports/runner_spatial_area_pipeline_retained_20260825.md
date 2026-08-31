# Runner spatial-area pipeline — retained candidate

Date: 2026-08-25

## Design change

`rtl/cnn/cnn_layer_runner.v` adds `ST_CALC_SPATIAL` immediately after
descriptor capture. It registers both `conv_out_h * conv_out_w` and
`tiled_out_h * tiled_out_w` before descriptor validation. `valid_config()`,
`output_count_for()`, and `sram_output_count_for()` consume the registered
areas, so the following area-times-channel arithmetic is separated from the
input-dimension arithmetic. No tensor operation, precision, descriptor rule,
memory protocol, or bus outstanding-request behavior was changed.

## Functional and cycle screening

The complete Verilator suite passed:

| Gate | Result |
| --- | --- |
| `run_all_sims.sh` | 41/41 PASS |
| tiled Stem | 16,384 checks PASS |
| tiled DSBlock | 2,256 checks PASS |
| SRAM bounds / packed input / backpressure | PASS |
| fullnet logits | 10/10 PASS |

The fullnet measured `1,011,623` cycles. The same-worktree control measured
`995,230` cycles, a delta of `+16,393` cycles (one descriptor-area pipeline
cycle per executed layer, with the retained surrounding design state). This
remains below the `2,000,000`-cycle limit.

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_all_sims.sh'
```

## XC7Z020 post-route comparison

Vivado 2025.2, part `xc7z020clg400-1`, 10 ns core clock, `Explore`, and the
same out-of-context top-level flow were used. Control figures are from the
immediately preceding same-worktree control run.

| Metric | Control | Spatial-area candidate | Delta |
| --- | ---: | ---: | ---: |
| WNS | -5.656 ns | -5.583 ns | +0.073 ns |
| TNS | -16,894.835 ns | -15,493.366 ns | +1,401.469 ns |
| WHS | +0.077 ns | +0.016 ns | -0.061 ns |
| Slice LUTs | 30,366 (57.08%) | 30,306 (56.97%) | -60 |
| Slice registers | 19,268 (18.11%) | 19,301 (18.14%) | +33 |
| BRAM tiles | 46 (32.86%) | 46 (32.86%) | 0 |
| DSPs | 50 (22.73%) | 50 (22.73%) | 0 |
| Estimated total on-chip power | 0.262 W | 0.220 W | -0.042 W |

The candidate routed with zero routing errors and zero hold violations. The
worst routed path migrated to:

```text
u_layer_runner/stride_reg_reg[7]/C
  -> u_layer_runner/tiled_load_count_reg[7]/D
```

It contains one `DSP48E1` level (13 logic levels total), rather than the
previous input-height-to-FSM two-DSP cascade. The candidate run artifacts are
under:

`build/reports/vivado_cnn_top_impl_runner_area_20260825/`

## Status

This is a meaningful net setup/TNS improvement with positive hold slack and
lower estimated power, so the RTL candidate is retained. It is not timing
closure: WNS remains negative (`-5.583 ns`, approximately 61.6 MHz at the
10 ns constraint), and the post-route OOC result does not prove board-level
timing or hardware power. The implementation flow therefore reports
`FAILED_TIMING_CLOSURE` despite completing routing.
