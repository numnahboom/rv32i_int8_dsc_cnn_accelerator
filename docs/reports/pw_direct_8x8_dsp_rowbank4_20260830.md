# PW direct 8x8 row-bank, four-lane packed drain (2026-08-30)

## Scope

This is a non-production successor to `pw_direct_8x8_dsp_rowbank`.  It keeps
the two-bank output-stationary 64-MAC accumulator and its ownership fence, but
drains each eight-result row as two four-lane beats (16 beats per block).  The
new `requant_activation_row4` captures all operands, sideband, and clamp
configuration at beat acceptance, then time-multiplexes one exact
`requant_activation_unit` across the four lanes.  The unit maps to four
DSP48E1s, so the complete prototype uses 64 MAC DSPs plus four requant DSPs.

The output is a registered packed 32-bit word and a four-bit lane mask.  A
held output remains stable until `ready_out`; bank release occurs only after
row 7, beat 1 is accepted.  The allocator also verifies that a stale bank
selection cannot overwrite a bank in DRAIN, which is important because the
four-DSP sink drains more slowly than the prior eight-DSP row2 sink.

No runner, production PW/DW path, full-network testbench, or full-top script
was modified.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_pw_direct_8x8_dsp_rowbank4_sim.sh'
```

The test uses an independent signed integer requant reference, source bubbles,
randomized output backpressure, held-output stability checks, configuration
changes between blocks, pixel/channel tails, and all combinations of
`Cin=16/32/48/128`, `P=1/8/17`, and `Cout=8/13/16`.  It exercises both banks
while one bank is draining.

Observed result:

```text
PASS tb_pw_direct_8x8_dsp_rowbank4 blocks=100 beats=1600 cycles=26350
OVERLAP admissions=4950
```

All 1,600 packed beats and every enabled byte matched the reference.  The
reported cycle count is local prototype stress time, not a full-network claim.

## XC7Z020 8 ns OOC post-route

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_pw_direct_8x8_dsp_rowbank4_ooc_20260830.tcl
```

Target is `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`, with an
8.000 ns clock.

| Metric | Post-route |
|---|---:|
| WNS / TNS / setup failing endpoints | +0.994 ns / 0.000 ns / 0 |
| WHS / THS / hold failing endpoints | +0.101 ns / 0.000 ns / 0 |
| Pulse-width slack / failing endpoints | +3.500 ns / 0.000 ns / 0 |
| Slice LUTs | 2,745 / 53,200 (5.16%) |
| Slice registers | 9,091 / 106,400 (8.54%) |
| DSP48E1 | 68 / 220 (30.91%) |
| Block RAM tiles | 0 / 140 (0.00%) |
| Total on-chip power | 0.289 W |
| Routed nets / routing errors | 12,060 / 0 |

The OOC screen clears the requested +0.5 ns setup margin and has no setup or
hold failures.  It is not full-top timing closure or end-to-end acceptance.

## Comparison with row2

The prior row2 prototype routed at WNS +0.642 ns, WHS +0.098 ns, 72 DSPs, and
0.305 W.  This variant uses four fewer DSPs and reports 0.289 W (−0.016 W,
−5.2%) while improving OOC WNS by 0.352 ns.  The comparison is between the
complete PW prototypes, not the RQ-only stream2 reference.

The packed four-byte sink does avoid a new *external* serialization point:
the interface transfers two beats per row instead of four, and the registered
word/mask hold is elastic under backpressure.  It does not eliminate the
internal arithmetic serialization required to stay at four DSPs: one beat
issues four scalar requant operations, so its local stress run is 26,350
cycles versus 12,141 cycles for the prior two-lane/eight-DSP row2 design.
Therefore this is a physically clean low-DSP result-path primitive, but not a
throughput-positive replacement by itself.  It should not be connected to the
runner without an architecture that hides or removes those four internal
scalar issue cycles.

## Artifacts

- `rtl/cnn/pw_direct_8x8_dsp_rowbank4.v`
- `rtl/cnn/requant_activation_row4.v`
- `sim/tb_pw_direct_8x8_dsp_rowbank4.v`
- `sim/filelist_pw_direct_8x8_dsp_rowbank4.f`
- `scripts/run_pw_direct_8x8_dsp_rowbank4_sim.sh`
- `scripts/vivado_pw_direct_8x8_dsp_rowbank4_ooc_20260830.tcl`
- `build/reports/vivado_pw_direct_8x8_dsp_rowbank4_ooc_20260830/`
