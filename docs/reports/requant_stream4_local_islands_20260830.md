# Local stream4 requant islands (2026-08-30)

## Scope

This is a non-production sink experiment for the quad-local, tagless DW
stream.  It does not alter `cnn_top`, the runner, or the production PW path.
The external adapter ABI remains one accepted 16-lane DW result followed by
four ordered four-lane write beats.

`ds_dw_requant_stream4_write_adapter_local.v` replaces the single 512-bit
record/variable-slice adapter with four independent 4-lane islands.  Each
island captures its own raw data, multiplier/shift record, mask, pixel tag and
activation limits, then time-multiplexes one exact `requant_activation_unit`
across its four lanes and stores a registered 32-bit beat.  Four islands thus
retain the original 16-DSP sink budget.  A shallow round-robin serializer retires
islands 0, 1, 2, 3 and only the selected island sees output backpressure.
`USE_LOCAL_REQUANT` selects this sink only in the non-production tagless
pipeline; its default is zero.

## Functional validation

`scripts/run_ds_dw_requant_stream4_write_adapter_local_sim.sh` passed 24
bundles / 96 beats against the independent fixed-point core.  The test covers
random signed operands, varied shifts, masks/tails, changing zero-point and
activation limits, output bubbles, and output backpressure with stability
checks while stalled.

The tagless pipeline regression was rerun with `USE_LOCAL_REQUANT=1` and
passed exact storage checks:

```
PASS tb_ds_word_window_dw_tagless_stream4_pipeline
cycles=50355 writes=256 reads=1536 overlap=385
```

## XC7Z020 OOC evidence

Command/script: `scripts/vivado_ds_word_window_dw_tagless_stream4_quadlocal_localrq_ooc_20260830.tcl`.
Part `xc7z020clg400-1`, 8 ns clock, RuntimeOptimized synthesis, Explore
placement, AggressiveExplore physical optimization, and routed implementation
with `general.maxThreads=2`.

Final routed reports in
`build/reports/vivado_ds_word_window_dw_tagless_stream4_quadlocal_localrq_ooc_20260830/`:

| Metric | Result |
|---|---:|
| WNS | +0.457 ns |
| TNS / setup failures | 0.000 ns / 0 |
| WHS / hold failures | +0.096 ns / 0 |
| LUT | 6,053 (11.38%) |
| FF | 12,339 (11.60%) |
| BRAM tile | 40 (28.57%) |
| DSP48E1 | 32 (14.55%) |
| Total on-chip power | 0.154 W |
| Route errors | 0 |

Relative to the same quad-local producer with the old shared sink (WNS
+0.316 ns, WHS +0.071 ns), the local sink route improved WNS by 0.141 ns and
kept hold closure while reducing sink DSP use back to 16.  The former
adapter-specific `input_fire` and `raw_reg` wide-control nets no longer appear
among the routed high-fanout entries; producer raw-vector entries are 128
loads.  The remaining >256 fanout entries are inherited/control-local to the
exact requant unit (`v[9]` pipeline enable, 1,309 loads per scalar unit) and
the quad-local producer's registered pixel/control paths.  The routed WNS is
0.043 ns below the requested +0.5 ns OOC safety gate, so this is a negative
physical-gate result despite zero setup/hold failures; it is not full-top or
production closure evidence.

## Files

- `rtl/cnn/ds_dw_requant_stream4_write_adapter_local.v`
- `rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v` (non-production
  parameter hook)
- `sim/tb_ds_dw_requant_stream4_write_adapter_local.v`
- `sim/filelist_ds_dw_requant_stream4_write_adapter_local.f`
- `scripts/run_ds_dw_requant_stream4_write_adapter_local_sim.sh`
- `scripts/vivado_ds_word_window_dw_tagless_stream4_quadlocal_localrq_ooc_20260830.tcl`
