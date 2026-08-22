# Vivado 2025.2 `xc7z020clg400-1` OOC implementation

Date: 2026-08-22  
Top: `cnn_top`  
Part: `xc7z020clg400-1`  
Vivado: 2025.2 (build 6299465)  
Scope: 100 MHz generic core-clock, out-of-context FPGA-fabric evidence only.

## Result

The standard wrapper was run with:

```powershell
.\scripts\run_cnn_impl.ps1 `
  -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' `
  -Part xc7z020clg400-1 -Top cnn_top
```

Run directory:
`build/reports/vivado_cnn_top_impl/runs/20260822T142930310-49364/`

Vivado accepted the timing-capable Zynq-7020 part and synthesis completed. The
wrapper Tcl then stopped after a successful `place_design` because its
`get_property PLACE_STATUS [current_design]` query returned an empty string in
Vivado 2025.2. The manifest is `FAILED_IMPLEMENTATION_STATUS`; this is a flow
compatibility failure, not an RTL or non-timing-device classification.

The retained log contains the following independent evidence:

- `place_design completed successfully`
- post-placement estimated WNS `-37.328 ns`
- physical-optimization estimated WNS/TNS `-37.314 ns` / `-20202.882 ns`
- the standard flow did not reach `route_design`, so no routed timing closure,
  post-route utilization, power, or board result is claimed.

An isolated retry opened the generated synthesis checkpoint and ran
`opt_design`, `place_design`, and `phys_opt_design`. It was stopped during
physical optimization after confirming the same strongly negative estimated
timing; therefore it did not produce a valid routed checkpoint and is not a
replacement for a completed signoff run.

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

- `manifest.txt`: `FAILED_IMPLEMENTATION_STATUS`, with `place_status` empty.
- `vivado.log`: complete standard-flow log through successful placement.
- `route_retry.log`: isolated checkpoint retry and its timing estimates.
- `utilization_synth.txt`, `clocks_synth.txt`: synthesis reports.

## Checks and limits

`git diff --check` passed. PowerShell AST parsing of
`scripts/run_cnn_impl.ps1` reported zero errors. No RTL was changed for this
experiment. This result is not K26 evidence, not board-level I/O or clock
closure, not power measurement, and not hardware validation.

Next implementation step is to make the status-query compatibility fix in the
implementation flow (or use a corrected equivalent Tcl flow), then rerun the
full `opt/place/phys_opt/route` and signoff reports. Any future timing claim
must use post-route WNS/TNS/WHS/THS and explicitly retain the generic OOC scope.
