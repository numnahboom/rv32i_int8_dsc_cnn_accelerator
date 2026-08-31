# dual32 MAC local island prototype — 2026-08-30

## Scope and disposition

This is a standalone OOC/testbench slice. It was not connected to `cnn_top`,
`cnn_layer_runner`, or the retained CSA full-top baseline. It is therefore not
evidence for complete-network logits, complete-network cycles, or full-top
post-route timing. The prototype has two 32-MAC islands (64 MAC nominal for PW
and STEM); DW intentionally uses island 0 only.

Disposition: **NEGATIVE_RESULT for system promotion**. The RTL/reference checks
pass, but the routed 8 ns OOC result fails setup and hold by a wide margin.

## Files and commands

New RTL/test files:

- `rtl/cnn/dual32_mac_local_island.v`
- `rtl/cnn/dual32_mac_local_island_ooc_wrapper.v`
- `sim/tb_dual32_mac_local_island.v`
- `sim/filelist_dual32_mac_local_island.f`

Scripts:

- `scripts/run_dual32_mac_local_island_sim.sh`
- `scripts/vivado_dual32_mac_local_island_ooc_20260830.tcl`
- `scripts/report_dual32_mac_local_island_timing_min_20260830.tcl`

Generated OOC artifacts are under
`build/reports/vivado_dual32_mac_local_island_ooc_20260830/`, including
`dual32.xdc`, `dual32_mac_local_island_ooc.dcp`, `timing_summary.rpt`,
`timing_summary_min.rpt`, `timing_max.rpt`, `timing_min.rpt`,
`utilization.rpt`, `power.rpt`, and `high_fanout.rpt`.

Simulation command (WSL, Verilator 5.020):

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_dual32_mac_local_island_sim.sh > build/dual32_mac_local_island_sim_20260830.log 2>&1'
```

The OOC command was Vivado 2025.2 `vivado.bat -mode batch` with
`scripts/vivado_dual32_mac_local_island_ooc_20260830.tcl`; the post-checkpoint
hold summary used
`scripts/report_dual32_mac_local_island_timing_min_20260830.tcl`.

## Functional and traffic evidence

The testbench computes an independent signed accumulation and exact
requantization reference. Every accepted commit is checked for word, mask,
pixel, channel, tag, and mode, in FIFO order; missing and unexpected commits
are also errors. `ref_checks` is the number of active output bytes checked.
`in_bubble` is an intentional input-valid gap, and `out_stall` is a cycle with
`valid_out && !ready_out`. No input backpressure occurred in these cases.

| case | exact refs | cycles | source words | parameter words | commits | in stall | bubbles | out stall | active MAC | capacity | utilization |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| STEM, tk=3, P=4/C=16 mask | 64 | 30 | 3 | 12 | 16 | 0 | 0 | 5 | 192 | 192 | 100.0% |
| PW DS1, Cin=16, P=8/C=8 | 64 | 44 | 32 | 32 | 16 | 0 | 2 | 5 | 1,024 | 1,024 | 100.0% |
| PW DS6, Cin=128, P=8/C=8 | 64 | 168 | 256 | 256 | 16 | 0 | 14 | 5 | 8,192 | 8,192 | 100.0% |
| DW finite block, tk=9, P=4/C=8 | 32 | 26 | 9 | 18 | 8 | 0 | 1 | 3 | 288 | 288 | 100.0% |
| PW P17/C13 tails, six blocks | 221 | 260 | 192 | 192 | 96 | 0 | 12 | 26 | 3,536 | 6,144 | 57.6% |
| **total** | **445** | **592** | **492** | **510** | **152** | **0** | — | — | **13,232** | **15,840** | **83.5%** |

The final line was `PASS dual32_local_island commits=152 cycles=592
source_words=492 param_words=510`. The DW parameter count is two 32-bit words
per accepted token; it is not four. The DW case is deliberately finite (`tk=9`)
and does **not** cover a complete Cin=128 DW reduction. Likewise, STEM covers
only the stated four-pixel block, not the full 32x32 stem image. No full-network
reference or MAC/cycle result was run for this standalone macro.

## Routed OOC results

Device `xc7z020clg400-1`, Vivado 2025.2, 8.000 ns clock (125 MHz), routed
design. Values below are from the reports listed above.

| metric | result |
|---|---:|
| WNS / TNS | −2.673 ns / −2694.759 ns |
| setup failing / total endpoints | 1,895 / 27,322 |
| WHS / THS | −0.502 ns / −1681.084 ns |
| hold failing / total endpoints | 5,324 / 27,322 |
| pulse-width worst slack | +3.500 ns, 0 failing |
| LUT / FF | 6,429 (12.08%) / 6,314 (5.93%) |
| DSP / BRAM | 96 (43.64% of 220) / 0 (0% of 140) |
| estimated total on-chip power | 0.371 W, medium confidence |
| route/DRC errors | 0; route completed successfully; one timing critical warning |

The previous unsplit requant version was about −8.732 ns WNS in the same OOC
lineage; the three-stage requant split improved WNS by about 6.06 ns, but did
not close timing. This is a meaningful local improvement, not a promotion.

## Worst-path diagnosis

The first 20 setup paths are overwhelmingly one accumulation-to-product
family. Representative worst paths and RTL cones are:

1. `u_dut/u_island0/q0_acc_reg[0][0]/C` →
   `u_dut/u_island0/q1_prod_reg[0]/C[1]`, slack −2.673 ns, data delay
   8.888 ns = logic 5.958 ns (67.034%) + route 2.930 ns (32.966%), 11 logic
   levels (9 CARRY4 + DSP48E1 + LUT2). The RTL cone is the `q0_sum` sign-extended
   add at lines 482–489 and the `q1_prod` multiply/register at lines 648–658
   of `dual32_mac_local_island.v`.
2. `u_dut/u_island0/q1_prod_reg[0]__0/CLK` →
   `u_dut/u_island0/qf_fixed_reg[0][8]/D`, slack −2.277 ns, data delay
   10.225 ns = logic 4.150 ns (40.585%) + route 6.075 ns (59.415%), 18 logic
   levels. This is the round/shift/fixed-point cone at lines 638–646; its
   dominant issue is physical spread/routing, not only RTL arithmetic depth.
3. `u_dut/u_island1/q0_acc_reg[1][1]/C` →
   `u_dut/u_island1/q1_prod_reg[1]/C[1]`, slack −2.208 ns, data delay
   8.423 ns = logic 5.981 ns (71.009%) + route 2.442 ns (28.991%), 11 logic
   levels. It is the same `q0_sum`/`q1_prod` cone in the second island.

The largest non-clock high-fanout nets are
`u_dut/u_island1/q2_valid_i_1_n_0` (3,240 loads, worst delay 6.960 ns) and
the corresponding island-0 net (3,234 loads, worst delay 9.447 ns). These are
the synthesized inversions of the `q2_valid` state used by the elastic
`q2_ready -> qf_ready -> q1_ready -> q0_ready` chain and output/busy gating
(RTL lines 491–507 and the q2 register update at lines 627–636), not a useful
64-MAC data net. They fan out to 3,120/3,114 slice loads plus 120 DSP/other
loads. Other control/address nets include `og2[1]` at 433/420 loads and
`q2_bytes` carry nets at 374 loads. The clock itself has 6,409 loads, as
expected for this unbuffered OOC wrapper.

## Promotion-rate calculation and stop line

For a 5,136,896-MAC network at 125 MHz and this OOC power estimate, the
constant is 1,284,224 GOPS-cycle units, so

`GOPS/W = 1,284,224 / (power_W * cycles)`.

The measured local service rates are:

- PW DS6: `8192 / 168 = 48.76` active MAC/cycle, implying 105,347 cycles if
  extrapolated blindly; this clears a 135k-cycle screen but is only one
  8x8 PW block and cannot be used as a full-network claim.
- All five measured cases combined: `13232 / 528 = 25.06` active MAC/cycle,
  implying 204,979 cycles; this misses the 135k screen and gives only
  16.89 GOPS/W at 0.371 W.
- Tail workload: `3536 / 260 = 13.60` active MAC/cycle, implying 377,713
  cycles and 9.16 GOPS/W.

At 0.371 W, 20 GOPS/W requires at most 173,076 cycles (29.68 active
MAC/cycle). Thus the mixed measured rate is below the energy promotion line,
even before accounting for full-network memory and fence overhead. The
prototype cannot be promoted on this evidence.

## Localized recovery assessment

A one-round CE/valid-island patch is not a credible reversal. The largest
setup family is a 9-CARRY4-plus-DSP arithmetic path with 5.958 ns logic delay,
while the requant family separately has 6.075 ns routing delay and the valid
inversion already drives more than 3,200 loads per island. A local valid
replication could reduce fanout, but it would not remove the independent
accumulator/product critical cone or the q1-to-qf physical spread; it also
adds control state and must preserve elastic ordering. Therefore this slice
stops at the negative result. Any further attempt needs a new architecture or
an explicit physical partitioning contract, followed by a fresh 8 ns OOC gate;
it should not be integrated into the full top as-is.
