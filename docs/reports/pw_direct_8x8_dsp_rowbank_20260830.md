# PW direct 8x8 row-bank result path (2026-08-30)

## Scope

This is a non-production prototype.  It does not modify `pw_direct_8x8_dsp`,
`pw_systolic_array_8x8`, the layer runner, or the full-network testbench.
`pw_direct_8x8_dsp_rowbank` accepts one K token per cycle and uses two local
ownership banks.  A complete reduction transitions `FREE -> ACCUM -> READY ->
DRAIN -> FREE`; the next reduction is admitted to the other bank while the
completed bank is drained.

The completed result is loaded one 256-bit row at a time.  Each row is issued
as four adjacent two-lane beats through `requant_activation_row2`, with the
existing exact ten-stage requant arithmetic and a narrow ready/valid output.
There is no 2048-bit output transaction, two-slot wide bundle, or global scalar
FIFO.  Config, mask, and base tags are captured per bank.  An input operand
stage and per-row activation/weight replication keep scheduler state out of
the MAC timing cone.  The MAC cell has a single active accumulator and
snapshots its final next-sum into the selected result bank; this retains one
DSP per lane rather than inferring a second DSP for a pipelined bank adder.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_pw_direct_8x8_dsp_rowbank_sim.sh'
```

The Verilator testbench uses an independent signed integer requant reference,
random signed operands/configuration, source bubbles, held output stalls, and
checks row/beat tags, lane masks, ordering, and exactly-once output.  It covers
all combinations of `Cin=16/32/48/128`, `P=1/8/17`, and `Cout=8/13/16` (100
tail-containing 8x8 blocks, 3,200 row beats).  It also observed admissions to
the second bank while the first bank was in DRAIN.

Observed result:

```text
PASS tb_pw_direct_8x8_dsp_rowbank blocks=100 pairs=3200 cycles=12141
OVERLAP admissions=1520
```

The 2-lane output is intentionally a prototype ABI; it is not connected to
the production runner and no full-network logits or end-to-end cycle claim is
made here.

## XC7Z020 8 ns OOC post-route

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_pw_direct_8x8_dsp_rowbank_ooc_20260830.tcl
```

Target is `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`, and an
8.000 ns clock.  The routed OOC result is:

| Metric | Post-route |
|---|---:|
| WNS / TNS / setup failing endpoints | +0.642 ns / 0.000 ns / 0 |
| WHS / THS / hold failing endpoints | +0.098 ns / 0.000 ns / 0 |
| Slice LUTs | 3,215 / 53,200 (6.04%) |
| Slice registers | 9,856 / 106,400 (9.26%) |
| DSP48E1 | 72 / 220 (32.73%) |
| Block RAM tiles | 0 / 140 (0.00%) |
| Total on-chip power | 0.305 W |
| Routable nets / routing errors | 13,267 / 0 |

The resource gate for the prototype is met: 64 MAC DSPs plus 8 requant DSPs,
with WNS margin above the requested +0.5 ns screen and no setup/hold failures.
The dominant remaining path is the replicated input-valid enable to a MAC
cell control register; it is 7.303 ns data delay and 0.642 ns slack, mostly
routing.  This is an OOC unit result and does not establish full-top timing.

## Comparison with stream2 slots

The current stream2 OOC reference is 8,018 LUT, 11,996 registers, 8 DSP, and
0.250 W (`docs/reports/requant_activation_stream2_slots_20260830.md`).  The
row-bank result path is materially smaller in LUT (3,215, -59.9%) and
registers (9,856, -17.8%) while eliminating the 2048-bit slot/FIFO topology.
Its total OOC power is 0.305 W (+0.055 W, +22.0%) because the comparison now
includes the required 64-DSP PW MAC fabric and two-lane requantizer.  Thus the
power comparison gate is not met against the RQ-only stream2 reference; this
prototype is evidence for the narrow result topology and bank overlap, not a
claim of final energy acceptance.  Its power remains well below the 3 W
system limit, but only a full-top integrated measurement can establish the
network GOPS/W target.

## Artifacts

- `rtl/cnn/pw_direct_8x8_dsp_rowbank.v`
- `rtl/cnn/requant_activation_row2.v`
- `sim/tb_pw_direct_8x8_dsp_rowbank.v`
- `sim/filelist_pw_direct_8x8_dsp_rowbank.f`
- `scripts/run_pw_direct_8x8_dsp_rowbank_sim.sh`
- `scripts/vivado_pw_direct_8x8_dsp_rowbank_ooc_20260830.tcl`
- `build/reports/vivado_pw_direct_8x8_dsp_rowbank_ooc_20260830/`
