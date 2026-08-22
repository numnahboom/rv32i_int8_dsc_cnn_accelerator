# Vivado 2025.2 `xc7z020clg400-1` OOC implementation

Date: 2026-08-23
Top: `cnn_top`
Part: `xc7z020clg400-1`
Vivado: 2025.2 (build 6299465)
Scope: 100 MHz generic core-clock, out-of-context FPGA-fabric evidence only.

## Result and flow compatibility

The standard wrapper was run with:

```powershell
.\scripts\run_cnn_impl.ps1 `
  -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' `
  -Part xc7z020clg400-1 -Top cnn_top -Directive RuntimeOptimized
```

Run directories:

- `build/reports/vivado_cnn_top_impl/runs/20260822T142930310-49364/` (original compatibility failure)
- `build/reports/vivado_cnn_top_impl/runs/20260823T013523276-36852/` (compatibility-fixed rerun)

Vivado accepted the timing-capable Zynq-7020 part and synthesis completed. The
The original wrapper Tcl stopped after a successful `place_design` because its
`get_property PLACE_STATUS [current_design]` query returned an empty string in
Vivado 2025.2. The compatibility fix no longer trusts that optional property:
it checks placed-cell LOC assignments and validates the explicit
`report_route_status` output. The wrapper also preserves a final Tcl manifest
when a native Vivado launch reports a late wrapper exception, instead of
overwriting it as `FAILED_WRAPPER_START`.

The retained log contains the following independent evidence:

- `place_design completed successfully`
- post-placement estimated WNS `-37.328 ns`
- physical-optimization estimated WNS/TNS `-37.314 ns` / `-20202.882 ns`
- the standard flow did not reach `route_design`, so no routed timing closure,
  post-route utilization, power, or board result is claimed.

The compatibility-fixed rerun completed synthesis and placement, then reached
`route_design`. It was intentionally interrupted after route initialization
while the host run was being bounded; its log ends with `route_design was
cancelled`, so it is not post-route signoff evidence. No WNS/TNS/WHS/THS or
post-route resource claim is made from this run.

## Synthesis resource snapshot

From `utilization_synth.txt` in the run directory:

| Resource | Used | xc7z020 available | Utilization |
|---|---:|---:|---:|
| Slice LUTs | 29,933 | 53,200 | 56.27% |
| Slice registers | 18,355 | 106,400 | 17.25% |
| Block RAM tiles | 46 | 140 | 32.86% |
| DSPs | 65 | 220 | 29.55% |

These are synthesis/OOC values, not post-route values.

## Evidence files

- Original `manifest.txt`: `FAILED_IMPLEMENTATION_STATUS`, with `place_status` empty.
- `vivado.log`: complete standard-flow log through successful placement.
- Compatibility-fixed run `vivado_console.txt`/`vivado.log`: synthesis, placement, and route initialization; route was cancelled by interruption.
- `utilization_synth.txt`, `clocks_synth.txt`: synthesis reports.

## Checks and limits

`git diff --check` passed. PowerShell AST parsing of
`scripts/run_cnn_impl.ps1` reported zero errors. No RTL was changed for this
experiment. This result is not K26 evidence, not board-level I/O or clock
closure, not power measurement, and not hardware validation.

The next implementation run should be allowed to finish `route_design` and
signoff reports. Any future timing claim must use post-route WNS/TNS/WHS/THS
and explicitly retain the generic OOC scope.
