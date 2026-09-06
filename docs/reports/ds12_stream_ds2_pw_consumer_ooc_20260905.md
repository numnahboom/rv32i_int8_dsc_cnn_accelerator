# DS2 PW consumer isolated OOC physical screen (2026-09-05)

Status: **NEGATIVE RESULT — synthesis completed, placement stopped by target
over-utilization DRC**

This report is reserved for the complete isolated OOC run of
`rtl/cnn/ds12_stream_ds2_pw_consumer.v` after the local `lane_accum` plus
double result-bank storage refactor. It is a module-level physical screen and
must not be described as full-top, full-network, power, energy, or hardware
closure.

## Contract

- Tool: Vivado 2025.2
- Part: `xc7z020clg400-1`
- Top: `ds12_stream_ds2_pw_consumer`
- Clock: `clk`, 8.000 ns
- Flow: out-of-context synth, place, physical optimization, route, and
  post-route utilization/timing reports
- Script: `scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl`
- Direct source manifest: `scripts/ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f`
- Generated source manifest and artifacts:
  `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/`

## Reproduction

```powershell
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source (Resolve-Path 'scripts\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl') `
  -log (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905')\vivado.log `
  -journal (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905')\vivado.jou -notrace
```

## Results

The run reached `DS2_PW_OOC_STAGE synth_done` and generated the post-synthesis
checkpoint, utilization report, and timing report. Vivado then ran the placer
precondition DRC and stopped before placement; therefore no post-route DCP,
post-route utilization, or post-route timing summary exists.

| Metric | Synthesis result | Post-route result |
| --- | ---: | ---: |
| LUT as logic | 58,087 / 53,200 (109.19%) | not available |
| FF / slice registers | 123,606 / 106,400 (116.17%) | not available |
| BRAM36/FIFO | 0 / 140 (0.00%) | not available |
| DSP48E1 | 16 / 220 (7.27%) | not available |
| WNS | -5.550 ns (synthesis estimate) | not available |
| TNS | -207,956.375 ns (synthesis estimate) | not available |
| WHS | +0.256 ns (synthesis estimate) | not available |
| THS | 0 ns (synthesis estimate) | not available |

The placement DRC reported four `UTLZ-1` errors: FDRE 123,605 versus 106,775
compatible sites, LUT-as-logic 58,087 versus 53,200, and slice/register
over-utilization at 123,606 versus 106,400. The placer consequently reported
`place_design failed` and did not start route.

Synthesis emitted `Synth 8-11357` RAM-structure warnings for `weight_reg`
(16,384 registers), `activation_reg` (65,536), and `result_psum_reg` (32,768).
It inferred 16 `DSP48E1` cells and **0 BRAM**. The previous layer-sized
`accum[32][8][64]` / 524,288-bit accumulator warning is absent from the full
Vivado log; the active RTL has `lane_accum[0:63]` plus two `result_psum` banks.
This confirms removal of that specific old accumulator warning, but also shows
that the remaining activation/result arrays were still dissolved into FFs for
this direct OOC top. It does not establish storage mapping in a runner or
full-top design.

Authoritative artifacts:

- log: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/vivado.log`
- settings: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/run_settings.txt`
- generated manifest: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/source_manifest.txt`
- synth utilization: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/utilization_synth.rpt`
- synth timing estimate: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/timing_summary_synth_estimate.rpt`
- synth DCP: `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905/ds12_stream_ds2_pw_consumer_ooc_8ns_post_synth.dcp`

The result is decisive for this exact isolated boundary: the current RTL
cannot be placed on `xc7z020clg400-1` without a storage-mapping change. No RTL,
TB, pure top, DS1, or interface was changed in this measurement slice.
