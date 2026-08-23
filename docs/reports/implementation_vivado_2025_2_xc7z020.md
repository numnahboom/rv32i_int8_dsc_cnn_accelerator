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
