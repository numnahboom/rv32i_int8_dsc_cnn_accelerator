# Feature-tile ping-pong ownership controller (2026-08-29)

## Scope

`rtl/cnn/feature_tile_pingpong_ctrl.v` is a standalone two-bank ownership
primitive. It has no memory, loader, vector datapath, or production-runner
connections. Each bank carries a compact `{bank, epoch, tag, extent}`
descriptor and follows the registered fence sequence:

```
FREE -> FILLING -> READY -> ACTIVE -> CONSUMED -> FREE
```

`fill_start` captures a descriptor and enters FILLING. A matching
`fill_done` publishes a registered descriptor and enters READY. A matching
`acquire` publishes a registered active descriptor and enters ACTIVE.
`consume_done` enters CONSUMED, and a matching `release` returns the bank to
FREE. A bank in FILLING/READY/CONSUMED is independent of the other bank, so
the idle bank can be filled while the other bank is ACTIVE.

Every command has a registered ready signal and a one-entry registered result
queue. Result valid/data remain stable until the corresponding point-to-point
ready is asserted. Invalid state or stale descriptor requests receive one
`ok=0` response (`ERR_STATE=1`, `ERR_DESCRIPTOR=2`) and do not change state;
this covers double acquire/release and stale epoch/tag/extent traffic.

## Functional validation

`sim/tb_feature_tile_pingpong_ctrl.v` drives 900 randomized clock transitions
with independent output stalls, random descriptor corruption, legal state-aware
traffic, back-to-back bank swaps, and simultaneous bank activity. The reference
model checks every response, descriptor echo, state transition, response
stability while stalled, stale/double-operation rejection, and exactly-once
command response behavior.

Run:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_feature_tile_pingpong_ctrl_sim.sh'
```

Observed result: `PASS checks=900 accepted=708 overlap=1`.

## XC7Z020 8 ns routed OOC screen

Wrapper: `rtl/cnn/feature_tile_pingpong_ctrl_ooc_wrapper.v`

Run:

```text
vivado.bat -mode batch -source scripts/vivado_feature_tile_pingpong_ctrl_ooc_20260829.tcl
```

Reports are under
`build/reports/vivado_feature_tile_pingpong_ctrl_ooc_20260829/`.

| Metric | Routed OOC result |
|---|---:|
| Part / clock | xc7z020clg400-1 / 125 MHz (8.000 ns) |
| WNS / TNS | +1.412 ns / 0.000 ns |
| WHS / THS | +0.165 ns / 0.000 ns |
| LUT / FF | 138 (0.26%) / 128 (0.12%) |
| DSP / BRAM | 0 / 0 |
| Total on-chip power | 0.104 W (Vivado vectorless, medium confidence) |
| Route status | 176/176 routable nets fully routed; 0 routing errors |

This is an OOC controller gate only. It is not full-top timing closure or
evidence that a future vector16 integration meets end-to-end CNN cycles,
resources, or power.
