# Stem spatial2 channel-pair pipeline (2026-08-28)

## Scope

`rtl/cnn/conv3x3_stem_engine_new.v` now evaluates adjacent output channels as
a pair. The three activation operands are shared; each channel has three
independent 8x8 products, product registers, a registered three-term
reduction, a carry-save accumulator, and its own `requant_activation_unit`
pipeline. The existing one-byte `out_wr_*` interface is preserved by a
lane-A-then-lane-B serializer, so the runner and output-buffer ABI are
unchanged.

The pair advances by two output channels and skips exactly 18 weight triplet
entries per pair. Input address progression, row wrap, output pixel/channel
ordering, and all quantization parameters remain unchanged. The pair does not
alter the network's MAC workload.

## Functional evidence

Using Vivado Simulator 2021.2 and the current dirty-tree snapshot:

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_pair` | PASS, 64 writes, 463 cycles; independent signed weights/biases/shifts across 2x2 pixels |
| `tb_conv3x3_stem_engine_new_addr_split` | PASS, 8 pair MAC runs, 72 MAC cycles, II=1 |
| `tb_conv3x3_stem_engine_new_csa` | PASS, signed extrema runs, 32 writes |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 writes |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_tail_sram_datapath` | PASS, 10 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, exact logits, 10/10 checks |

The full-network run reports 5,136,896 MACs, 888,937 hardware cycles, and
exact hardware/software logits. The full-network inference report's 1,000,000
cycle ceiling is met by this candidate.

Verilator 5.020 `--lint-only --timing -Wno-fatal -Wall` completed without
errors. The Stem source itself emits no lint warnings; the only remaining
warnings are pre-existing width warnings inside the shared
`requant_activation_unit.v` implementation.

## Isolated post-route screen

Vivado 2025.2, `xc7z020clg400-1`, 8 ns clock, OOC, `RuntimeOptimized`,
`maxThreads=2`, route completed with zero route errors:

| Metric | Result |
| --- | ---: |
| WNS / TNS | +0.373 ns / 0.000 ns |
| WHS / THS | +0.098 ns / 0.000 ns |
| LUT | 13,413 / 53,200 (25.21%) |
| FF | 5,918 / 106,400 (5.56%) |
| DSP | 8 / 220 (3.64%) |
| BRAM | 0 / 140 (0.00%) |
| Total on-chip power | 0.611 W |

Reports and DCP are under
`build/reports/vivado_stem_channel_pair_20260828_final/`. This is an isolated Stem
OOC result, not full-top timing closure or board validation; the extra lane
does increase isolated power and must be judged against fresh full-top
throughput and power before retention as the global design point.
