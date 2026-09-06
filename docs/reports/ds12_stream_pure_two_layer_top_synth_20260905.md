# DS12 pure two-layer synthesis resource screen (2026-09-05)

Status: **DONE — authoritative synth-only failure terminal captured; no utilization report was produced.**

## Contract

- Tool: Vivado 2025.2 (`D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat`)
- Part: `xc7z020clg400-1`
- Top: `ds12_stream_pure_two_layer_top`
- Mode: synthesis-only, out-of-context; no placement, routing, timing closure,
  post-route utilization, hardware, or full-network claim.
- Script: `scripts/vivado_ds12_stream_pure_two_layer_top_synth_20260905.tcl`
- Sources: `build/reports/ds12_stream_pure_two_layer_top_synth_20260905/source_manifest.txt`

## Reproduction

From `D:\Stuff\Project`:

```powershell
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source (Resolve-Path 'scripts\vivado_ds12_stream_pure_two_layer_top_synth_20260905.tcl') `
  -log (Resolve-Path 'build')\ds12_stream_pure_two_layer_top_synth_20260905.vivado.log `
  -journal (Resolve-Path 'build')\ds12_stream_pure_two_layer_top_synth_20260905.vivado.jou -notrace
```

The script reads 12 pure RTL files and does not read the legacy
`ds12_stream_two_layer_top.v` or the testbench. It records `part`, `top`,
synthesis mode, directive, and thread limit in
`build/reports/ds12_stream_pure_two_layer_top_synth_20260905/run_settings.txt`.

## Attempts and evidence

1. `RuntimeOptimized`, `-flatten_hierarchy rebuilt`, 8-thread setting: Vivado
   exited with code `-1073740940` during synthesis before report generation.
2. `RuntimeOptimized`, `-flatten_hierarchy none`, one synthesis process: same
   synthesis-stage behavior; the process reached about 30 GB private memory and
   was stopped before resource reports were generated.
3. `Quick` was rejected as an invalid Vivado directive (`Common 17-161`), then
   the script was corrected to the valid `Default` directive.
4. `Default`, `-flatten_hierarchy none`, one synthesis process: same large-array
   expansion and no report output; the run was stopped after reaching about
   30 GB private memory.
5. Recovery rerun with the current 12-source manifest and unchanged
   `Default`, `-flatten_hierarchy none`, one-process script: Vivado returned
   wrapper exit code `7` after reaching `Finished RTL Optimization Phase 2`,
   `Start RTL Component Statistics`, and `Start Cross Boundary and Area
   Optimization`. The process then exited without emitting Vivado's normal
   `Exiting Vivado` line or the script DONE marker; no utilization, timing, or
   checkpoint file was created. The recovery log's final line is the
   `Synth 8-3917` warning at line 475.

The authoritative Vivado logs are:

- `build/ds12_stream_pure_two_layer_top_synth_20260905.vivado.log`
- `build/ds12_stream_pure_two_layer_top_synth_20260905_retry_none.vivado.log`
- `build/ds12_stream_pure_two_layer_top_synth_20260905_retry_mt1.vivado.log`
- `build/ds12_stream_pure_two_layer_top_synth_20260905_retry_default.vivado.log`
- `build/ds12_stream_pure_two_layer_top_synth_20260905_recovery.vivado.log`
- `build/ds12_stream_pure_two_layer_top_synth_20260905_recovery.console.log`

The recovery run reached `Finished Synthesize` at 00:40:02 elapsed,
`Finished RTL Optimization Phase 2` at 01:28:11 elapsed, and recorded a
28,964.742 MB peak. Its synthesis log contains these RAM-inference/runtime
warnings (`Synth 8-11357`): `bank_mem_reg` (55,808 registers), `feature_reg`
(131,072), DS1 `activation_reg` (16,384), DS1 `accum_reg` (131,072),
`result_accum_reg` (32,768), DS2 `weight_reg` (16,384), DS2 `activation_reg`
(65,536), and DS2 `accum_reg` (524,288). It also records undeclared-before-use
warnings (`Synth 8-6901`), DS2 4-to-6-bit port-width warnings (`Synth 8-689`),
and a multi-driven `cfg_mem_resp_ready` critical warning (`Synth 8-6858/6859`).
These are synthesis observations only; the `Part Resource Summary` values
(`DSPs: 220`, `BRAMs: 280`) are device capacities, not design utilization.

All completed synthesis attempts issued warnings that the current RTL arrays
could not be inferred as block RAM and were dissolved into registers, including
`lane*_mem_reg` (16 lanes × 16,384 bits), `feature_reg` (131,072 registers),
and DS2 `activation_reg`/`accum_reg` (65,536/524,288 registers). The logs also
contain the existing undeclared-before-use warnings in
`ds12_stream_dual_vector_activation_store.v` and DS2 4-to-6-bit port-width
warnings. These are recorded observations; no datapath or testbench RTL was
changed in this measurement slice.

Because `synth_design` did not complete, LUT/FF/BRAM/DSP totals and percentages
are intentionally not reported. An authoritative top-level resource result
requires a storage-oriented RTL change (or equivalent Vivado-supported RAM
template) before rerunning this unchanged measurement contract.
