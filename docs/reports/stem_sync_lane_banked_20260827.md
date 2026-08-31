# Stem lane-banked synchronous-read pipeline

Date: 2026-08-27
Device: `xc7z020clg400-1`, Vivado 2025.2

## Result

`conv3x3_stem_engine_new.v` now stores the three input byte positions and
three weight byte positions in independent lane banks. Each bank is read into
registered operands. The initial `ST_OPERAND` cycle fills the valid/tag
pipeline; each `ST_MAC` cycle consumes the current tag and issues the next
bank read, giving one tap per clock (II=1) without changing the MAC precision,
layout, output ordering, or busy/done semantics. Cursors are triplet-word
indices, so no divide or byte-lane mux is on the MAC read path. Scalar and
vec4 configuration writes retain the existing byte-linear ABI, including
cross-bank vec4 writes.

## Directed and integration verification

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_addr_split` | PASS, 16 writes, `mac_runs=16`, `mac_cycles=144`, `II=1`, 226 cycles |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 writes, 226 cycles |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_backpressure` | PASS, 768 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10/10 exact logits, 958,174 cycles, 78,890 reads, 10 writes, 0 errors |

Commands used:

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_addr_split
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_requant
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_cnn_top_tiled_stem_datapath tb_cnn_top_sram_stem_dsblock_datapath tb_cnn_top_backpressure" ./scripts/run_all_sims.sh
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" ./scripts/run_all_sims.sh
```

## Fresh isolated 8 ns OOC

Flow: `scripts/vivado_stem_sync_lane_banked_20260827.tcl`; all 12,387 nets
routed with zero routing errors. The old asynchronous input-memory-to-product
path is absent: timing max paths start at registered `operand_*_q` pins. The
new registered operand-to-accumulator cone is reported separately at 10.433 ns
data delay (`-2.486 ns` slack); this is the expected II=1 recurrence and is
the current local limiting cone.

| Metric | Parameter-capture predecessor | Sync lane-banked |
| --- | ---: | ---: |
| WNS | -4.787 ns | -4.398 ns |
| TNS | -3538.646 ns | -617.280 ns |
| WHS | +0.113 ns | +0.144 ns |
| THS | 0 ns | 0 ns |
| Slice LUTs | 11,192 | 11,461 |
| Slice registers | 2,908 | 2,886 |
| Block RAM tiles | 0 | 0 |
| DSPs | 10 | 10 |

The design remains setup-negative and is not timing closure or hardware
validation. The lane banks are explicit registered-read arrays; Vivado maps
the small input banks to registers/LUT resources rather than Block RAM.
Existing tiled/SRAM and backpressure tests cover padding/halo loading and
stall behavior, but no standalone simultaneous read/write collision test was
added because configuration writes are forbidden while `busy`.
