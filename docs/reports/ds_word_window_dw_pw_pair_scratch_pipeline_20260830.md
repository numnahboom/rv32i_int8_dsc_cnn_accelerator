# 4x8 + paired scratch + packed rowbank end-to-end screen (2026-08-30)

## Scope and contract

`ds_word_window_dw_pw_pair_scratch_pipeline` is a non-production integration
shell.  It instantiates two 4x8 `ds_word_window_dw_producer_island` blocks,
one shared stream4 requant adapter, an eight-row scratch image, and
`dw_pw_pair_scratch_rowbank2_packed_consumer`.  The upper and lower producer
jobs represent the two 4x8 halves of an 8x8 spatial tile.  Each 16-lane DW
result is split into two eight-channel PW groups: stream4 bases 0/1 map to
group `2*g`, and bases 2/3 map to `2*g+1`.  Thus upper lanes are retained and
not silently dropped.  A row transfer uses the paired scratch acquire/write /
commit fence; the PW job may consume the opposite bank while a later transfer
or DW job is active.  The row image is implemented by `row_image_bram_store`:
each stream4 beat is one registered 36-bit plane write and every transfer uses
the store's registered eight-plane gather response.  The old explicit
`row_mem`/`row_mask_mem` register image and reset loop are removed.

The production runner, `cnn_top`, and full-network ABI are untouched.

## Functional validation

Command:

```text
bash scripts/run_ds_word_window_dw_pw_pair_scratch_pipeline_sim.sh
```

Result:

```text
PASS pair scratch pipeline fence outputs=32 cycles=122 overlap=0 writes=0 reads=8
```

The smoke bench seeds the simulation-only BRAM model with a deterministic
8-pixel/8-channel row image, then exercises the actual BRAM gather and paired
fence, loads the packed 8x8 weight image, and checks all 32 output beats and
masks.  Existing
independent differential benches remain authoritative for the producer
(`tb_ds_word_window_dw_tagless_stream4_4x8`) and packed consumer
(`tb_dw_pw_pair_scratch_rowbank2_packed_consumer`) including Cin=16/48/128,
P=1/8/17, Cout tails, reverse groups, arbitrary half order, and stalls.

This integration bench is a fence/shell smoke test rather than a full random
DW-to-logit differential: producer source-fill and configuration traffic are
covered by the independent producer bench, and PW arithmetic/packed loading
by the independent consumer bench.

## 8 ns XC7Z020 OOC result

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_pw_pair_scratch_pipeline_ooc_20260830.tcl
```

Vivado synthesized, placed, and routed the reduced
`MAX_CIN=8 MAX_COUT=8 MAX_GROUPS=16` shell without DRC errors.  The row image
maps to eight explicit BRAM36 planes; the shell now clears the placement gate:

| resource | post-route | XC7Z020 available | result |
|---|---:|---:|---|
| LUT as logic | 9,346 | 53,200 | 17.57% |
| FF | 29,051 | 106,400 | 27.30% |
| RAMB36 | 36 | 140 | 25.71% |
| RAMB18 | 24 | 280 | 8.57% |
| DSP48E1 | 120 | 220 | 54.55% |
| WNS / TNS | +0.286 ns / 0 | — | all setup endpoints pass |
| WHS / THS | +0.086 ns / 0 | — | all hold endpoints pass |
| Total on-chip power | 0.422 W | 3 W | pass (OOC estimate) |

The synthesis report is
`build/reports/vivado_ds_word_window_dw_pw_pair_scratch_pipeline_ooc_20260830/utilization_post_synth.txt`;
post-route timing, utilization, power, fanout, route, and DRC reports are in
`build/reports/vivado_ds_word_window_dw_pw_pair_scratch_pipeline_ooc_20260830/`.
The OOC shell is not full-top evidence and has not been integrated into the
runner.

The BRAM replacement removes the 67k-LUT placement failure and the former
register image's dynamic data mux.  It does not by itself solve the shell's
global-control fanout: post-route still reports `bank_state` at 7,326 loads,
DW pixel controls at 2,541 loads, and PW psum/control nets above 2,000 loads.
The 0.286 ns OOC setup margin is useful but not a full-top prediction.

## Decision

Keep this shell and its protocol as non-production integration evidence only.
Do not promote it to `cnn_layer_runner` or `cnn_top`.  The row-image BRAM
replacement is now a viable physical candidate for further architectural
work, but the next candidate must localize the remaining producer/PW control
domains and prove full-network exactness before any full-top implementation.
