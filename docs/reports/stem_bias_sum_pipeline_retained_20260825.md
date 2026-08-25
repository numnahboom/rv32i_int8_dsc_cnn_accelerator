# Stem accumulator+bias register pipeline — retained positive result

Date: 2026-08-25

## Candidate

`rtl/cnn/conv3x3_stem_engine_new.v` adds `ST_RQ_SUM`, registering the signed
64-bit accumulator+bias sum before the existing requantization product. This
separates the bias RAM/CARRY4 prefix from the DSP product without changing
arithmetic, interface, or network operations. The added state costs one cycle
per output channel (16 cycles for a 1x1 output), but preserves all outputs.

## Functional screening

The candidate passed all selected Verilator tests:

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_requant` | PASS |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10 checks, 1,011,614 cycles |

Command: `GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_conv3x3_stem_engine_new_requant tb_cnn_top_tiled_stem_datapath tb_cnn_top_sram_stem_dsblock_datapath tb_cnn_top_fullnet_sram_datapath' SIM_CONTINUE_ON_FAIL=1 SIM_LOG_DIR=build/reports/stem_sum_candidate ./scripts/run_all_sims.sh`

## Synthesis control and screening

The valid installed tool was explicitly selected as
`D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat`; the old 2021.2
failure is not evidence against this candidate. Isolated synthesis on
`xc7z020clg400-1` at 10 ns completed for both candidate and same-snapshot
baseline:

| Metric | Baseline | ST_RQ_SUM | Delta |
| --- | ---: | ---: | ---: |
| LUT primitive cells | 1286 | 1285 | -1 |
| FF/latch primitive cells | 412 | 413 | +1 |
| LUT as logic | 1038 | 1038 | 0 |
| LUT as distributed memory | 484 | 484 | 0 |
| DSPs (site report) | 10 | 10 | 0 |
| worst observed max-path slack (synthesis report) | -6.682 ns | -4.904 ns | +1.778 ns |

The candidate then completed a real Explore post-route OOC run with Vivado
2025.2. It routed cleanly and produced `WHS=+0.148 ns`, `WNS=-4.534 ns`,
`setup failing endpoints=1`, zero hold failures, 1579 Slice LUTs, 480 Slice
registers, 0 BRAM tiles, 10 DSPs, and vectorless estimated total on-chip power
0.150 W. This is a meaningful isolated improvement, but it is not timing
closure (`WNS` remains negative), and it is not full `cnn_top` post-route
evidence.

The candidate RTL is retained. The runner and synthesis wrapper defaults were
also repaired to the installed Vivado 2025.2 path; explicit `-Vivado` remains
supported.

## Full `cnn_top` post-route integration

The candidate was then screened in the complete top-level flow, using Vivado
2025.2, `xc7z020clg400-1`, and `Explore`:

```text
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
run: build/reports/vivado_cnn_top_impl/runs/20260825T102436063-22496/
status: FAILED_TIMING_CLOSURE (route and signoff reports completed)
```

The control is the immediately preceding same-worktree run
`20260825T094309991-13628`, whose manifest has the candidate RTL absent from
the tracked dirty diff. Both runs fully routed with zero routing errors and
used the same 10 ns core-clock OOC constraint. The candidate comparison is:

| Metric | Control | ST_RQ_SUM | Delta |
| --- | ---: | ---: | ---: |
| WNS | -6.958 ns | -5.656 ns | +1.302 ns |
| TNS | -25145.500 ns | -16894.836 ns | +8250.664 ns |
| setup failing endpoints | 13042 | 9731 | -3311 |
| WHS | +0.050 ns | +0.077 ns | +0.027 ns |
| THS | 0.000 ns | 0.000 ns | 0 |
| Slice LUTs | 30497 (57.33%) | 30366 (57.08%) | -131 |
| Slice registers | 19430 (18.26%) | 19268 (18.11%) | -162 |
| BRAM tiles | 46 (32.86%) | 46 (32.86%) | 0 |
| DSPs | 51 (23.18%) | 50 (22.73%) | -1 |
| estimated total on-chip power | 0.253 W | 0.262 W | +0.009 W |

The candidate therefore improves setup, hold, setup endpoint count, and
post-route utilization on the full top, with a small vectorless power
increase. It remains far from 125 MHz closure (`WNS < 0`) and the power
estimate is not a board measurement. The routed candidate reports are under
the run directory above (`manifest.txt`, `timing_summary.txt`,
`timing_maxpaths.txt`, `route_status.txt`, `utilization_post_route.txt`, and
`power.txt`).

The fullnet Verilator gate above measured `1,011,614` cycles versus the
same-worktree control's `995,230` cycles: `+16,384` cycles, exactly one added
`ST_RQ_SUM` cycle for each of the 1024 stem pixels and 16 output channels.
It remains below the 2,000,000-cycle requirement and passed all 10 logits.

The primary post-route path moved out of Stem. The candidate's worst path is
`u_layer_runner/u_ds_block_engine/rq_desc_acc_reg[0]/C` to
`u_layer_runner/u_ds_block_engine/u_pw_requant/product_s1_reg/C[45]`, with
13.871 ns data delay, 8 CARRY4 plus 3 DSP48E1 levels, and -5.656 ns slack.
This identifies the DSBlock pointwise requant accumulator/DSP cascade as the
next timing target; no further Stem change is justified by this integration
run.
