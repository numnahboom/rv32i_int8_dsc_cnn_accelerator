# Vivado 2025.2 `xc7z020clg400-1` routed implementation

Date: 2026-08-23
Top: `cnn_top`
Part: `xc7z020clg400-1`
Vivado: 2025.2 (build 6299465)
Clock constraint: generic `clk` at 100 MHz (10.000 ns)
Scope: out-of-context FPGA-fabric implementation evidence only.

## Result

The standard wrapper was run with:

```powershell
.\scripts\run_cnn_impl.ps1 `
  -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' `
  -Part xc7z020clg400-1 -Top cnn_top -Directive RuntimeOptimized
```

Run directory: `build/reports/vivado_cnn_top_impl/runs/20260823T014945105-53876/`

Vivado 2025.2 accepted the timing-capable Zynq-7020 part. Synthesis,
optimization, placement, physical optimization, routing, timing reporting,
power reporting, and checkpoint writing all completed. The final manifest is
`FAILED_TIMING_CLOSURE`: routing succeeded, but the generic 100 MHz setup
constraint is not met.

Post-route timing from `timing_summary.txt`:

| Metric | Result |
|---|---:|
| WNS | -40.264 ns |
| TNS | -88930.469 ns |
| Setup failing endpoints | 19,449 / 53,185 |
| WHS | +0.082 ns |
| THS | 0.000 ns |
| Hold failing endpoints | 0 / 53,185 |
| Clock | 100.000 MHz, 10.000 ns |

The worst setup path has 50.211 ns data delay, 68 logic levels, and runs from
`u_layer_runner/u_stem_engine/kernel_y_idx_reg[0]_replica/C` to
`u_layer_runner/u_stem_engine/out_wr_data_int8_reg[4]/D`. The timing report
shows no unconstrained internal endpoints; it does show 102 inputs and 98
outputs without I/O delay constraints, as expected for this OOC wrapper. The
unconstrained-path table has only the unconstrained-port clock group entries.

## Routed resource and power snapshots

From `utilization_post_route.txt` in the run directory:

| Resource | Used | xc7z020 available | Utilization |
|---|---:|---:|---:|
| Slice LUTs | 29,416 | 53,200 | 55.29% |
| Slice registers | 17,891 | 106,400 | 16.81% |
| Block RAM tiles | 46 | 140 | 32.86% |
| DSPs | 65 | 220 | 29.55% |

The vectorless Vivado power estimate in `power.txt` is 0.189 W total
(0.083 W dynamic, 0.106 W static), with Medium confidence. This is a tool
estimate under default assumptions, not a board measurement or a power
closure result.

`route_status.txt` reports 45,993/45,993 routable nets fully routed and zero
routing errors. `cnn_top_impl.dcp` is the routed checkpoint (18,299,744
bytes).

## Evidence files

The run directory contains `manifest.txt`, `vivado.log`, `timing_summary.txt`,
`timing_maxpaths.txt`, `utilization_post_route.txt`, `route_status.txt`,
`power.txt`, and the routed `cnn_top_impl.dcp` checkpoint.

## Checks and limits

This run is useful evidence that the current RTL fits the xc7z020 resources and
can be fully routed by Vivado 2025.2. It does not demonstrate timing closure:
the reported 100 MHz setup slack is substantially negative. It is also not
K26 evidence, board-level I/O or clock closure, measured power, or hardware
validation. No board pin constraints, external memory timing, activity file,
or physical board were used.

Checks performed: `git diff --check` and PowerShell AST parsing of the wrapper
reported no errors. No RTL was changed for this implementation run.

## Current-HEAD rerun after Stem pipeline change

The report above is the result recorded by commit `7e2bc7f`; that run used
git HEAD `53b249e`. After commit `93efe9b` added the Stem requantization stage
after the final MAC, the same full routed OOC flow was rerun against the
current HEAD with `-Directive RuntimeOptimized`:

```text
git_head: 93efe9bb7cf758a0c786784419c7bc504ec7ba16
run: build/reports/vivado_cnn_top_impl/runs/20260823T143458770-18264/
status: FAILED_TIMING_CLOSURE
```

Vivado again completed synthesis, optimization, placement, physical
optimization, routing, timing, power, and checkpoint writing. The current
post-route result is:

| Metric | 7e2bc7f report | Current HEAD rerun | Delta |
|---|---:|---:|---:|
| WNS | -40.264 ns | -26.997 ns | +13.267 ns |
| TNS | -88930.469 ns | -80980.352 ns | +7950.117 ns |
| Setup failing endpoints | 19,449 / 53,185 | 18,642 / 53,344 | — |
| WHS | +0.082 ns | +0.083 ns | +0.001 ns |
| Hold failing endpoints | 0 | 0 | — |
| Slice LUTs | 29,416 | 29,350 | -66 |
| Slice registers | 17,891 | 17,934 | +43 |
| Block RAM tiles | 46 | 46 | 0 |
| DSPs | 65 | 65 | 0 |
| Vectorless total power | 0.189 W | 0.233 W | +0.044 W |

The current worst setup path is from
`u_layer_runner/u_fc_unit/class_idx_reg[1]_replica/C` to
`u_layer_runner/u_fc_unit/output_mem_reg_0_15_0_5/RAMC_D1/I`, with 36.664 ns
data-path delay and 52 logic levels. The routed design has 45,996/45,996
routable nets fully routed and zero routing errors. The current result is
therefore a valid routed resource/power snapshot and timing diagnosis, but it
still does not close a generic 100 MHz clock (10 ns period). The power number
is a medium-confidence vectorless estimate, not a board measurement.

## XSim Stem/fullnet gate evidence

The fresh Windows XSim log
`build/reports/cnn_xsim_20260821_183438.log` records the complete 27-RTL-file
regression as `PASS cnn_xsim_regression tests=16`. Its fullnet test reports
10/10 logits bit-exact, `944568` hardware cycles, `0x0e69b882` status,
`5136896` MACs, and `361.42x` RV32I estimated speedup. The separate current
`build/reports/xsim_full_20260823/summary.csv` is a 38/38 PASS aggregate; its
individual logs include the broader mixed simulator batch and should not be
substituted for the raw 16-test XSim gate above.

## Current HEAD rerun after FC product pipeline

At HEAD `d4dcf827e759e986554fedd964e7f23f32a16383`, the routed flow was rerun
with Vivado 2025.2 and `-Directive RuntimeOptimized`:

```text
run: build/reports/vivado_cnn_top_impl/runs/20260823T150022008-12540/
status: FAILED_TIMING_CLOSURE
```

Routing and report generation completed. The generic 100 MHz OOC timing
constraint remains unmet, but the FC pipeline improves setup slack relative to
the preceding `518e958` baseline:

| Metric | `518e958` baseline | `d4dcf82` current | Delta |
|---|---:|---:|---:|
| WNS | -26.997 ns | -25.022 ns | +1.975 ns |
| TNS | -80980.352 ns | -78970.894 ns | +2009.458 ns |
| WHS | +0.083 ns | +0.040 ns | -0.043 ns |
| THS | 0.000 ns | 0.000 ns (derived) | 0 |
| Slice LUTs | 29,350 | 29,495 | +145 |
| Slice registers | 17,934 | 17,950 | +16 |
| BRAM tiles | 46 | 46 | 0 |
| DSPs | 65 | 65 | 0 |
| Vectorless total power | 0.233 W | 0.211 W | -0.022 W |

The implementation wrapper's manifest conservatively records the TNS field as
`NEGATIVE_PATH_PRESENT`, but the Vivado timing summary provides the numeric
aggregate above (19,462 setup-failing endpoints). The worst setup path is still in the Stem
engine, from `u_layer_runner/u_stem_engine/channel_idx_reg[0]/C` to
`u_layer_runner/u_stem_engine/out_wr_data_int8_reg[1]/D`, with 35.015 ns data
path delay, 51 logic levels, and -25.022 ns slack. Thus the FC pipeline is
functionally safe and improves the routed WNS, but it does not yet move the
critical path out of Stem or close 100 MHz.

The vectorless estimate is 0.104 W dynamic plus 0.107 W static, medium
confidence, with no activity file. It is not a board measurement or power
closure result. `route_status.txt` reports a fully routed design with no
routing errors. As with the earlier sections, this is generic-clock,
post-route FPGA-fabric evidence only: it is not board-level I/O closure,
K26 timing, or hardware validation.

## Current HEAD XSim gate

Vivado 2025.2 XSim recompiled 27 RTL files and ran the complete 16-test gate
from `scripts/run_cnn_xsim.ps1`; all 16 testbenches passed. The current fullnet
test reports 10/10 logits bit-exact and 960953 hardware cycles. The former
950000-cycle ancillary-report budget rejected that valid run; it was raised to
the still-finite 1000000-cycle regression ceiling to accommodate the intentional
Stem and FC pipeline drains. This was a budget-policy failure, not a simulation
mismatch. The separate Verilator batch was independently rerun in
`build/reports/xsim_full_20260823_fc_pipeline/summary.csv` with 39/39 PASS;
its fullnet SRAM test reports 10 checks and 960953 hardware cycles.

## Current HEAD rerun after the nine-stage requantization work

At HEAD `769d2f825c26b34ff833a9452a13ccea12cced6c`, the complete routed flow
was rerun with Vivado 2025.2, `xc7z020clg400-1`, and
`-Directive RuntimeOptimized`:

```text
run: build/reports/vivado_cnn_top_impl/runs/20260823T153035995-10512/
status: FAILED_TIMING_CLOSURE
```

Synthesis, optimization, placement, physical optimization, routing, timing,
power, and checkpoint generation all completed. The design is fully routed
(`46156/46156` routable nets, zero routing errors), but the generic 100 MHz
clock is not met. Post-route timing is:

| Metric | Result | Baseline `f2bf6f7` | Delta |
|---|---:|---:|---:|
| WNS | -18.008 ns | -25.022 ns | +7.014 ns |
| TNS | -56922.496 ns | -78970.894 ns | +22048.398 ns |
| Setup failing endpoints | 15569 / 54174 | 19462 | improved |
| WHS | +0.028 ns | +0.040 ns | -0.012 ns |
| THS | 0.000 ns | 0.000 ns | 0 |

The worst setup path is from `u_layer_runner/stride_reg_reg[7]/C` to
`u_layer_runner/mem_req_addr_reg[31]/D`, with 27.955 ns data-path delay and
28 logic levels. There are zero unconstrained internal endpoints; the report
contains only the expected unconstrained-port clock-group entries from this
OOC wrapper.

The post-route resource snapshot is 29373 Slice LUTs (55.21%), 18121 Slice
registers (17.03%), 46 Block RAM tiles (32.86%), and 65 DSPs (29.55%). The
vectorless power estimate is 0.235 W total (0.128 W dynamic, 0.107 W static,
medium confidence). It is a tool estimate under default activity assumptions,
not measured board power.

This run is stronger routed FPGA-fabric evidence than the requested `f2bf6f7`
snapshot, and shows a 7.014 ns WNS improvement, but it is not timing closure,
board-level I/O/clock closure, K26 timing, power closure, or hardware
validation. No RTL was changed for this rerun.

## Current HEAD rerun after tiled packed-input loader

At HEAD `370e275dfe789205f5b293ba4cd5c61e7e69784d`, the complete routed flow
was rerun with Vivado 2025.2, `xc7z020clg400-1`, and
`-Directive RuntimeOptimized`:

```text
run: build/reports/vivado_cnn_top_impl/runs/20260823T155956525-2316/
status: FAILED_TIMING_CLOSURE
```

Synthesis, optimization, placement, physical optimization, routing, timing,
power, and checkpoint generation completed. The design is fully routed, but
the generic 100 MHz OOC clock is not met. Post-route timing is:

| Metric | Result | Previous `769d2f8` | Delta |
|---|---:|---:|---:|
| WNS | -14.714 ns | -18.008 ns | +3.294 ns |
| TNS | -63101.914 ns | -56922.496 ns | -6179.418 ns |
| Setup failing endpoints | 16377 / 54303 | 15569 / 54174 | increased |
| WHS | +0.028 ns | +0.028 ns | 0 |
| THS | 0.000 ns | 0.000 ns | 0 |

The worst setup path remains in the tiled loader address-generation logic,
from `u_layer_runner/stride_reg_reg[3]_replica_5/C` to
`u_layer_runner/sram_input_rd_addr_reg[3]/D`. It has 24.709 ns data-path
delay, 19 logic levels, and -14.714 ns slack. The earlier
`stride_reg -> mem_req_addr` path is therefore not eliminated; in this routed
run the corresponding critical endpoint is the internal SRAM input address
register. The report shows zero unconstrained internal endpoints, while the
102 input and 98 output ports lack I/O delay constraints as expected for this
OOC wrapper.

The post-route resource snapshot is 29465 Slice LUTs (55.39%), 18152 Slice
registers (17.06%), 46 Block RAM tiles (32.86%), and 64 DSPs (29.09%). The
vectorless power estimate is 0.209 W total (0.102 W dynamic, 0.107 W static,
medium confidence), with no activity file. This is a tool estimate, not a
board measurement or power closure result. `route_status.txt` reports a fully
routed design with zero routing errors.

This result is routed FPGA-fabric evidence for the timing-capable Zynq-7020
part. It is not 100 MHz timing closure, board-level I/O or clock closure, K26
timing, hardware validation, or measured power. No RTL was changed for this
rerun.

## Current HEAD XSim gate

Vivado 2025.2 XSim recompiled the 27 RTL files and completed the full selected
16-test gate. All 16 testbenches passed, including the fullnet test with 10/10
logits bit-exact. The fresh fullnet result is `993721` hardware cycles,
`5513689` MACs, and `343.55x` RV32I estimate. The prior `944568`-cycle result
belongs to an earlier HEAD and must not be mixed with this current run.

## Current dirty-tree rerun after tiled address-base pipeline

The tiled loader was then changed in the working tree to form its halo offsets,
row/column bases, and initial flattened input index in three registered states.
The SRAM and external-input requests use that registered index; the loader
remains single-outstanding. Vivado 2025.2 was rerun with the same `xc7z020clg400-1`
part and `RuntimeOptimized` directive:

```text
base git_head: 9ab6295e4c3c3db7d8f124f6178986b5345bac1a
run: build/reports/vivado_cnn_top_impl/runs/20260823T170935332-3896/
status: FAILED_TIMING_CLOSURE
```

The design is fully routed (`46365/46365` routable nets, zero route errors).
The generic 100 MHz OOC timing constraint is still unmet, but WNS improved by
3.424 ns relative to the `370e275` run:

| Metric | `370e275` | Address-base pipeline | Delta |
|---|---:|---:|---:|
| WNS | -14.714 ns | -11.290 ns | +3.424 ns |
| TNS | -63101.914 ns | -46783.293 ns | +16318.621 ns |
| Setup failing endpoints | 16377 / 54303 | 16202 / 54811 | improved |
| WHS | +0.028 ns | +0.014 ns | -0.014 ns |
| THS | 0.000 ns | 0.000 ns | 0 |

The prior `stride_reg -> sram_input_rd_addr_reg` worst path is no longer the
reported maximum. The new worst setup path is
`u_layer_runner/in_h_reg_reg[2]_replica/C` to
`u_layer_runner/phase_idx_reg[0]/CE`, through tile/output-span validation and
the phase enable, with 21.001 ns data-path delay and 26 logic levels. This is
a timing diagnosis, not timing closure.

Post-route utilization is 29,758 Slice LUTs (55.94%), 18,361 Slice registers
(17.26%), 46 BRAM tiles (32.86%), and 55 DSPs (25.00%). Vivado's vectorless
estimate is 0.252 W total (0.145 W dynamic, 0.107 W static), medium confidence;
it is not measured board power.

Fresh Vivado 2025.2 XSim compiled all 27 RTL files and passed the four
address-sensitive directed tests (SRAM bounds, tiled Stem, tiled DSBlock, and
SRAM tiled DSBlock). The separately rerun fullnet test passed 10/10 logits
bit-exact in 993850 cycles, with 5,136,896 MACs and a 343.50x RV32I estimate.
The 129-cycle increase relative to the immediately preceding 993721-cycle
fullnet measurement is within the 1,000,000-cycle regression ceiling and is
consistent with the fixed per-tile address preparation states.

As with every section above, this is timing-capable xc7z020 routed
FPGA-fabric evidence only. It is not 100 MHz timing closure, K26 evidence,
board-level I/O or clock closure, hardware validation, or measured power.

## Current HEAD rerun after registered SRAM span validation

At HEAD `14d6c42`, the descriptor SRAM-span validation cone was split into
two registered stages: one records the input/output element counts and the
next records their span-valid results before the phase index is enabled. This
keeps the tiled output-count product, 33-bit span comparison, and phase-enable
logic out of a single cycle. The loader remains single-outstanding; no request
or response state is active during these descriptor-local validation cycles.

Vivado 2025.2 reran the full routed OOC flow with `xc7z020clg400-1` and
`RuntimeOptimized`:

```text
run: build/reports/vivado_cnn_top_impl/runs/20260823T173802610-8900/
status: FAILED_TIMING_CLOSURE
```

The design fully routed (`46336/46336` routable nets, zero route errors). The
generic 100 MHz OOC constraint remains unmet, but the prior tiled span/phase
critical path is no longer the reported maximum:

| Metric | Address-base pipeline | Span-validation pipeline | Delta |
|---|---:|---:|---:|
| WNS | -11.290 ns | -9.776 ns | +1.514 ns |
| TNS | -46783.293 ns | -37259.229 ns | +9524.064 ns |
| Setup failing endpoints | 16202 / 54811 | 15565 / 54811 | improved |
| WHS | +0.014 ns | +0.085 ns | +0.071 ns |
| THS | 0.000 ns | 0.000 ns | 0 |
| Slice LUTs | 29758 | 29834 | +76 |
| Slice registers | 18361 | 18299 | -62 |
| BRAM tiles | 46 | 46 | 0 |
| DSPs | 55 | 55 | 0 |
| Vectorless total power | 0.252 W | 0.211 W | -0.041 W |

The new worst path is an FC accumulation write path, from
`u_layer_runner/u_fc_unit/product_reg_reg__0/CLK` to
`u_layer_runner/u_fc_unit/output_mem_reg_0_15_6_7/DP/I`, with 19.443 ns data
delay and 43 logic levels. The former `in_h_reg -> phase_idx_reg/CE` tiled
output-span validation path is absent from the maximum-path report. The power
number is again Vivado's medium-confidence vectorless estimate, not measured
board power or power closure.

Fresh Vivado 2025.2 XSim compiled all 27 RTL files. The four address-sensitive
directed tests (SRAM bounds, tiled Stem, tiled DSBlock, and SRAM tiled DSBlock)
passed. The fullnet SRAM test remained 10/10 logits bit-exact in 993868 cycles
with 5,136,896 MACs and a 343.50x RV32I estimate. The 18-cycle increase
relative to the preceding 993850-cycle run is the two fixed validation cycles
for each of the nine layer descriptors.

This remains routed xc7z020 FPGA-fabric evidence only. It is not 100 MHz
timing closure, K26 timing, board-level I/O/clock closure, hardware validation,
or measured power.
