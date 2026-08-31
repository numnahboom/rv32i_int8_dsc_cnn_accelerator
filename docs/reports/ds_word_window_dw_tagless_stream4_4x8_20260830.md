# 4x8 word-window/tagless DW producer screen (2026-08-30)

## Scope

`ds_word_window_dw_tagless_stream4_4x8` is a non-production wrapper around
the established word-window producer, quad-local sixteen-lane DW core, local
stream4 requant sink, and tagless epoch/tile scratch sessions.  It does not
instantiate PW and does not modify the runner or the full network.  The
underlying producer received only backward-compatible `OUTPUT_HEIGHT` and
`OUTPUT_WIDTH` generics; its default remains the existing 8x8 behavior.

The wrapper fixes output geometry to four rows by eight columns.  Output
indices remain row-major 0..31, and each accepted raw result remains one
sixteen-lane bundle followed by four ordered four-lane stream4 beats.  Thus
two adjacent 4x8 sessions can later be paired at the PW boundary without
changing lane or pixel ordering.

## Geometry and traffic

| output / stride | footprint vectors | source words (4/vector) | DW tokens | output pixels |
|---|---:|---:|---:|---:|
| 4x8 / 1 | 6x10 = 60 | 240 | 288 | 32 |
| 4x8 / 2 | 9x17 = 153 | 612 | 288 | 32 |

The stride-one fill is 240 words versus 288 one-token/cycle DW work, so a
next-bank fill can be hidden after the pipeline is warm.  The testbench
observed concurrent source fill and compute (512, 1,535, and 4,091 cycles for
Cin=16, 48, and 128 respectively).  Stride two is intentionally read-bound
(612 > 288) and is reported as such.

For two adjacent 4x8 tiles forming one 8x8 PW block, the DW token and output
counts are unchanged, while source traffic is 480 words versus 400 for an
8x8 stride-one tile (+20%), or 1,224 versus 1,156 at stride two (+5.9%).
That is the principal cycle/energy overhead of the split geometry; no MACs
are removed and no precision or metric definition changes.

## Exact Verilator regression

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_word_window_dw_tagless_stream4_4x8_sim.sh'
```

Verilator 5.020 passed all seven cases: Cin=16/48/128 at stride 1 and 2,
plus a Cin=48 stride-one five-lane tail.  The checks include source request
bubbles, output backpressure/data stability, padding footprints, alternating
bank ownership, changing epochs, exact scratch masks, and exact 288-token /
128-write sessions.

| Cin | stride | footprint | words/fill | total source reads | tokens/session | cycles |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 6x10 | 240 | 64 | 288 | 2,507 |
| 16 | 2 | 9x17 | 612 | 64 | 288 | 3,764 |
| 48 | 1 | 6x10 | 240 | 192 | 288 | 6,443 |
| 48 | 2 | 9x17 | 612 | 192 | 288 | 8,630 |
| 128 | 1 | 6x10 | 240 | 512 | 288 | 16,283 |
| 128 | 2 | 9x17 | 612 | 512 | 288 | 20,795 |
| 48 tail | 1 | 6x10 | 240 | 192 | 288 | 6,443 |

The cycle values are isolated wrapper-bench values including fill, source
response latency, scratch reads, and test backpressure; they are not
full-network inference cycles.

## XC7Z020 8 ns OOC post-route

Command/script:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_tagless_stream4_4x8_ooc_20260830.tcl
```

Part `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`,
`flatten_hierarchy none`, RuntimeOptimized synthesis, Explore placement,
AggressiveExplore physical optimization, and 8.000 ns clock.

| metric | routed result |
|---|---:|
| WNS | +0.516 ns |
| TNS / setup failures | 0.000 ns / 0 |
| WHS / hold failures | +0.093 ns / 0 |
| routing errors | 0 |
| Slice LUTs | 6,066 (11.40%) |
| Slice registers | 12,349 (11.61%) |
| DSP48E1 | 33 (15.00%) |
| Block RAM tiles | 44 (31.43%) |
| estimated total on-chip power | 0.155 W |

The requested nonnegative timing/resource gate is met, and WNS clears the
local +0.5 ns setup screen by 0.016 ns.  It does **not** meet a stricter
WHS>=+0.5 ns safety-margin interpretation: hold slack is +0.093 ns.  The
remaining minimum-delay path is a registered shell-bank write-data command
to RAMB36 DIADI.  The setup critical path is a local quad DSP output path
(7.475 ns data delay, 4.585 ns logic and 2.890 ns routing), not a new
4x8 address recurrence.

The high-fanout report also shows that the full design is not below a literal
256-load limit: local requant `v[9]` enables reach 1,309 loads, producer
pixel/mask controls reach 633--645, and local packed-data controls reach 422.
These are inherited arithmetic/serializer controls rather than a new
epoch/tag data-plane broadcast, but they prevent claiming the requested
`session/control fanout<256` gate without a further local-island redesign.

## Decision

The 4x8 variant is functionally complete and physically routable with a
small resource/power footprint, and the stride-one 240-word fill can be
hidden under its 288-token compute window.  It remains a non-production
candidate: the literal +0.5 ns hold and <256 fanout gates are not met, and
the two-tile pairing costs 20% extra stride-one source traffic.  Do not
integrate it into `cnn_top`, the runner, or PW until those physical and
system-level tradeoffs are revisited with a fresh full-top implementation.
