# Single-producer DS/PW local ownership flags (2026-08-30)

## Scope

This candidate changes only the non-production single-producer DS/PW screen.
`pw_direct_8x8_dsp_rowbank` no longer decodes a two-bit `bank_state` array in
its ready/busy/drain cones.  Two scalar local flags (`bank_live0/1` and
`bank_ready0/1`) represent ownership and completion.  A single `ready_event`
selects the oldest ready bank; the drain bank and row metadata are captured at
that event and subsequent row loading uses the registered drain context.

The shared producer start handshake was also corrected: the one physical
producer must accept both `active_half` values.  The old dual-producer gating
left lower-half commands in `ST_IDLE` with `REQUIRE_BOTH_HALVES=1`.

Eight synthesis-only identity LUTs split the 64-DSP stage-valid enable by row.
This preserves cycle behavior while giving the placer local enable domains.

## Functional evidence

Commands:

```text
bash scripts/run_pw_direct_8x8_dsp_rowbank_sim.sh
bash scripts/run_ds_word_window_dw_pw_single_producer_pipeline_overlap_sim.sh
```

Results:

```text
PASS tb_pw_direct_8x8_dsp_rowbank blocks=100 pairs=3200 cycles=12141
PASS real producer overlap outputs=32 cycles=6173 overlap=68 source_words=720 tokens=288 half_writes=192 pw_reads=8
```

The second test uses real source-word fills with a three-cycle response queue,
all nine DW tap configurations, two sequential 4x8 producer halves, a row-0
transfer/commit, and a simultaneous refill/DW job while PW is active.  It
checks zero-valued output data, output mask and stability under backpressure,
producer source/token/half-write counts, and requires
`dut.active && dut.u_pw.feeder_busy` overlap to be observed.

## 8 ns OOC evidence

The fresh run uses Vivado 2025.2, `xc7z020clg400-1`, `general.maxThreads=2`
and the existing 8 ns OOC script.  Reports are in
`build/reports/vivado_ds_word_window_dw_pw_single_producer_pipeline_ooc_20260830/`.

| metric | post-route | local gate |
|---|---:|---:|
| WNS | +0.474 ns | >= +0.5 ns |
| TNS / setup failures | 0 ns / 0 | 0 / 0 |
| WHS / hold failures | +0.082 ns / 0 | >= 0 / 0 |
| LUT | 7,519 (14.13%) | <70% |
| FF | 24,617 (23.14%) | <70% |
| RAMB36 / RAMB18 | 34 / 12 (24.29% / 4.29%) | <70% |
| DSP48E1 | 104 (47.27%) | <70% |
| estimated total on-chip power | 0.391 W | <=3 W |
| route status | 0 errors, 0 partial/unrouted | clean |

For comparison, the prior seeded-smoke snapshot was WNS +0.309 ns and
0.380 W.  The row-local enable buffering improved WNS by 0.165 ns, but added
LUT/control activity and raised estimated power by 0.011 W relative to that
snapshot.  The old `bank_state` 7,326-load net is absent; the remaining top
post-route fanout is `in_stage_valid` at 7,332 loads, followed by DW
`out_pixel_idx[5]` at 2,541 and `cfg_fire` at 1,120.  The remaining critical
path is a DW DSP-to-output register path (7.517 ns data delay, 4.509 ns logic
and 3.008 ns routing), so this local ownership refactor does not yet clear
the +0.5 ns screening margin and is not a full-top integration candidate.
