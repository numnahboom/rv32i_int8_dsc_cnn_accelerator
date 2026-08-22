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
