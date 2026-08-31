# Masked four-lane requant stream unit (2026-08-30)

## Scope and contract

`rtl/cnn/requant_activation_stream4_masked.v` is the four-lane elastic
requant stream used to drain a logical sixteen-lane DW result as four ordered
four-lane beats.  The existing implementation was retained: it wraps the
exact ten-stage `requant_activation_stream4` arithmetic and advances a
four-bit lane-mask pipeline with the same global elastic advance condition.
Consequently, `valid_in && ready_in` is the only input acceptance event,
`out_lane_mask` stays aligned with the corresponding packed four-byte result,
and all operands/configuration are held by the underlying pipeline after
acceptance.  A logical 16-lane bundle is four consecutive beats with channel
tags at 0, 4, 8, and 12 (the existing DW write adapter's contract).

## Functional validation

The focused test is:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_requant_activation_stream4_masked_sim.sh'
```

`tb_requant_activation_stream4_masked` drives 16 logical bundles (64
four-lane beats / 256 lane results) and uses four independent instances of
`requant_activation_core` as a fixed-point reference.  It covers:

- signed positive/negative accumulator, bias, and multiplier extrema with
  overflow-safe combinations;
- deterministic moderate random operands and independently changed
  zero-point, activation limits, and post-multiply shifts;
- masks including all-zero, single-lane, sparse, full, and random tails;
- input valid hold under `ready_in` stalls and a deterministic output
  backpressure pattern with repeated multi-cycle stalls;
- exact pixel/channel ordering, mask propagation, packed lane data, and
  exactly-once output handshakes.

Observed result:

```text
PASS tb_requant_activation_stream4_masked beats=64 outputs=64 cycles=187
```

## 8 ns XC7Z020 OOC post-route

The physical screen is:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_requant_activation_stream4_masked_ooc_20260830.tcl
```

Target: `xc7z020clg400-1`, 8.000 ns clock (125 MHz), Vivado 2025.2,
`general.maxThreads=2`, out-of-context synthesis/place/route.

| Metric | Post-route result |
|---|---:|
| WNS / TNS / setup failing endpoints | +1.288 ns / 0.000 ns / 0 |
| WHS / THS / hold failing endpoints | +0.098 ns / 0.000 ns / 0 |
| Pulse-width slack / failing endpoints | +3.020 ns / 0.000 ns / 0 |
| Slice LUTs | 1,603 / 53,200 (3.01%) |
| Slice registers | 5,345 / 106,400 (5.02%) |
| DSP48E1 | 16 / 220 (7.27%) |
| Block RAM tiles | 0 / 140 (0.00%) |
| Total on-chip power | 0.172 W |
| Routed nets / routing errors | 6,603 / 0 |

The worst sampled reg-to-reg path has 6.709 ns data delay (3.220 ns logic,
3.489 ns routing, 12 logic levels), leaving 1.288 ns slack.  This is an OOC
unit result only; it is not evidence of full `cnn_top` timing closure or end-
to-end cycle/energy acceptance.

## Artifacts

- `rtl/cnn/requant_activation_stream4_masked.v`
- `sim/tb_requant_activation_stream4_masked.v`
- `sim/filelist_requant_activation_stream4_masked.f`
- `scripts/run_requant_activation_stream4_masked_sim.sh`
- `scripts/vivado_requant_activation_stream4_masked_ooc_20260830.tcl`
- `build/reports/vivado_requant_activation_stream4_masked_ooc_20260830/`
