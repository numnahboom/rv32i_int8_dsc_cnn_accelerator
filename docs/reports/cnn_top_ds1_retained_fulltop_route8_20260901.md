# `cnn_top` retained DS1 full-top implementation (8 threads)

Date: 2026-09-01
Tool: Vivado 2025.2 (build 6299465)
Part: `xc7z020clg400-1`
Clock: `clk`, 8.000 ns (125 MHz)
Directive: `Explore`
Thread setting: `general.maxThreads=8`

## Scope and command

This is the complete `cnn_top` implementation flow with
`USE_DS1_RETAINED_ORCHESTRATOR=1`, including the retained DS1 adapter,
orchestrator, session, bridge, fill/replay pipeline, DW dependencies, and the
existing full runner/Stem/GAP/FC/SRAM sources. It is not the standalone DS1
orchestrator OOC screen. The run uses the project top-level core-clock XDC
(`constraints/cnn_top_unified64_ooc_8ns.xdc`) and the existing top-level
out-of-context implementation convention (there are no board pin/IO-delay
constraints in this repository).

Launcher: `scripts/run_cnn_top_ds1_retained_8ns_impl.ps1`
Flow: `scripts/vivado_cnn_top_impl.tcl`
Run directory:
`build/reports/vivado_cnn_top_ds1_retained_8ns/runs/20260901T1048_retained_fulltop_threads8/`

The actual parameter was captured by Vivado in `run_settings.txt` and in the
console line `CNN_TOP_IMPL_SETTINGS general.maxThreads=8`. Vivado also reports
`Running DRC with 8 threads` immediately before placement.

## Result

Status: **FAILED_IMPLEMENTATION** at the precondition DRC of
`place_design`. `opt_design` completed, but placement did not start; therefore
there is no valid post-placement/post-route timing, route-status, or
post-implementation power result for this run.

The exact blocking DRCs were:

```text
DSP48E1 over-utilized: 222 required, 220 available
DSPs over-utilized:    222 required, 220 available
LUT as Logic over-utilized: 54941 required, 53200 available
```

`route_design` was not reached. Consequently route errors are **not
applicable (0 reported because routing was never invoked)**; this is a
placement/resource failure, not a successful route.

## Synthesis accounting before the placement failure

| Resource | Used | Available | Utilization | Gate (<70%) |
| --- | ---: | ---: | ---: | --- |
| Slice LUTs | 63,959 | 53,200 | 120.22% | FAIL |
| LUT as Logic | 59,245 | 53,200 | 111.36% | FAIL |
| Slice Registers | 77,071 | 106,400 | 72.44% | FAIL |
| Block RAM Tile | 92 | 140 | 65.71% | PASS |
| DSPs | 222 | 220 | 100.91% | FAIL |

The hierarchical report identifies the duplicate retained/legacy DS compute
structures as the dominant source:

| Hierarchy | LUTs | FFs | BRAM36 | BRAM18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| `u_layer_runner/gen_ds1_retained_runner/u_ds1_retained_adapter` | 22,665 | 39,683 | 42 | 4 | 97 |
| `u_layer_runner/u_ds_block_engine` | 23,004 | 28,819 | 28 | 0 | 96 |

Together these two branches account for 193 of 222 DSPs and 45,669 of
63,959 LUTs, while the retained branch does not remove the always-instantiated
legacy `u_ds_block_engine`.

## Timing and power evidence

No post-route WNS/TNS/WHS/THS exists because placement failed. The read-only
post-synthesis timing report is diagnostic only:

```text
WNS -4.626 ns, TNS -3222.092 ns, 3941 failing endpoints
WHS +0.189 ns, THS 0.000 ns
Worst synthesis path: u_layer_runner/in_w_reg_reg[1]/C
  -> u_layer_runner/u_tile_scheduler/cur_w_reg[3]/R
Data path delay 12.018 ns (logic 3.711 ns, route estimate 8.307 ns)
```

The post-synthesis power estimate is 0.634 W total on-chip (medium confidence),
but it is **not** an implementation power result. Post-implementation power is
therefore unverified.

## Hard-gate audit

| Requirement | Evidence | Result |
| --- | --- | --- |
| 125 MHz, WNS/WHS >= 0 after route | No placement/route; post-route slack unavailable | NOT MET / UNVERIFIED |
| Full-network <=2.0M cycles | No full-top runtime was produced by this implementation run | UNVERIFIED |
| LUT/FF/DSP/BRAM each <70% | LUT 120.22%, FF 72.44%, DSP 100.91%, BRAM 65.71% | FAIL |
| Post-implementation power <=3 W | Route failed; only 0.634 W synthesis estimate exists | UNVERIFIED |
| >=20 GOPS/W at real throughput | No routed throughput/power pair | UNVERIFIED |

Primary evidence files are `manifest.txt`, `run_settings.txt`,
`utilization_synth.txt`, `query/utilization_hierarchical_synth.txt`,
`query/timing_synth_summary.txt`, `query/power_synth_estimate.txt`, and
`vivado_console.txt` under the run directory above.
