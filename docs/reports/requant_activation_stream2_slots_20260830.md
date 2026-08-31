# Two-slot two-lane PW requant drain (2026-08-30)

## Contract and implementation

`rtl/cnn/requant_activation_stream2.v` is the two-lane elastic wrapper around
the exact ten-stage `requant_activation_unit`.  Both lanes share the same
global ready/valid advance, and a ten-stage sideband pipe carries the pair
index, pixel/cout base, and two-bit mask in lockstep with the arithmetic.

`rtl/cnn/requant_activation_stream2_slots.v` accepts the existing 8x8 PW
result ABI: one 2048-bit signed accumulator bundle (64 lanes), one 64-bit
mask, and eight channel parameter lanes reused across the eight pixels.  Two
local slots let the next complete bundle be captured while the older slot is
drained.  Each slot captures all operands, metadata, and requant configuration;
the latter is important because the producer may change configuration while
the prior slot remains in flight.

The drain issues pairs at indices 0,2,...,62.  Masked lanes are appended in
pixel-major/channel-minor order to a scalar FIFO.  A one-entry elastic input
stage separates the variable 2048-bit slot extraction from the first requant
DSP inputs and prevents an `issue_idx`-to-DSP wide-mux timing path.  The age
pointer alternates the slots after completion so a newly refilled slot cannot
overtake the older pending slot.

One protocol bug found during differential testing was corrected explicitly:
the FIFO count increment is a two-bit value.  In Verilog, the original
`mask[0]+mask[1]` expression was one bit wide and wrapped when both lanes were
valid, eventually corrupting FIFO accounting.  The count now uses an explicit
two-bit increment and reserves two entries before accepting a pair.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_requant_activation_stream2_slots_sim.sh'
```

`tb_requant_activation_stream2_slots` uses 2,048 complete 8x8 bundles and an
independent `requant_activation_core` reference for every accumulator lane.
It exercises 54,586 masked scalar outputs over 115,136 cycles, including:

- signed extrema and deterministic random accumulator/bias/multiplier values;
- all-zero, full, sparse, edge, alternating, and random tail masks;
- changing zero-point, activation limits, and shifts on every bundle family;
- source valid bubbles and input hold while both slots are occupied;
- irregular short/long output backpressure, including FIFO pressure;
- exact pixel/channel ordering, exactly-once outputs, and stable output data
  during every `valid_out && !ready_out` stall.

Observed result:

```text
PASS tb_requant_activation_stream2_slots bundles=2048 outputs=54586 cycles=115136
```

Verilator lint of the same file list also passed with no reported diagnostics.

## XC7Z020 8 ns OOC post-route

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_requant_activation_stream2_slots_ooc_20260830.tcl
```

Target is `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`, and an
8.000 ns clock.  The routed OOC result is:

| Metric | Post-route |
|---|---:|
| WNS / TNS / setup failing endpoints | +0.607 ns / 0.000 ns / 0 |
| WHS / THS / hold failing endpoints | +0.098 ns / 0.000 ns / 0 |
| Slice LUTs | 8,018 / 53,200 (15.07%) |
| Slice registers | 11,996 / 106,400 (11.27%) |
| DSP48E1 | 8 / 220 (3.64%) |
| Block RAM tiles | 0 / 140 (0.00%) |
| Total on-chip power | 0.250 W |
| Routed nets / routing errors | 14,788 / 0 |

The worst sampled setup path is the scalar FIFO write-pointer-to-channel
write path, with 7.386 ns data delay (1.420 ns logic, 5.966 ns routing), leaving
0.607 ns at 8 ns.  This is an OOC unit result and does not establish full
`cnn_top` timing, end-to-end cycles, or final energy acceptance.

## Artifacts

- `rtl/cnn/requant_activation_stream2.v`
- `rtl/cnn/requant_activation_stream2_slots.v`
- `sim/tb_requant_activation_stream2_slots.v`
- `sim/filelist_requant_activation_stream2_slots.f`
- `scripts/run_requant_activation_stream2_slots_sim.sh`
- `scripts/vivado_requant_activation_stream2_slots_ooc_20260830.tcl`
- `build/reports/vivado_requant_activation_stream2_slots_ooc_20260830/`
