# Rejected historical candidates: Stem spatial16/vector4 and spatial8x2/vector4

This report records completed spatial16/vector4 and follow-up 8x2/vector4
experiments. Both candidates are rejected: the 16-lane run and its 8x2 split
failed the 125 MHz timing screen. The working RTL is restored to the scalar
Stem configuration with the retained ST_RQ_SUM pipeline; the metrics below
are retained as rejection evidence and do not describe the current working
tree.

Date: 2026-08-25. Target: `xc7z020clg400-1`.

## RTL change

`rtl/cnn/spatial_mac8x3.v` replicates the three signed int8 products for eight
output channels. `conv3x3_stem_engine_new.v` uses two physically separate
eight-channel weight banks and MAC groups, while still accumulating all sixteen
channels over the same nine tap cycles. Channels 0..7 and 8..15 then use two
existing `requant_activation_vector4` transactions. Their tagged FIFOs are
drained in channel order through the unchanged scalar output write interface. The
configuration port, tiled/non-tiled address progression, output tags, and
precision/requantization path remain unchanged; no SRAM interface was added.

The vector4 `output_pixels` bound is set to `pixel_idx+1` so its existing
absolute pixel tag semantics remain valid when reusing it for successive
pixels. Scalar drain selection deliberately holds the other lanes in their
FIFOs, covering internal ready/valid backpressure without dropping outputs.

## Functional and cycle screening

All commands used Verilator 5.020 through `scripts/run_sim.sh` with
`GENERATE_TEST_VECTORS=0` after the RTL change:

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 tagged writes, 39 cycles |
| `tb_conv3x3_stem_engine_new_spatial` | PASS, 64 tagged writes over 2x2 pixels, 150 cycles |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks, ready stalls and response delays 0..3 |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10/10 exact logits, 774,688 cycles, 78,890 reads, 10 writes |

The fullnet result is below the retained 949,792-cycle PW double-bank/vector4
baseline and the 2,000,000-cycle requirement. The directed spatial test checks
pixel/channel boundary ordering and output completeness while the engine's
internal vector4 lanes are selectively stalled by the scalar drain.

## Implementation screen

The initial 16-lane implementation was routed in
`build/reports/vivado_stem16_ooc_20260825/` and rejected for timing. A follow-up
8-lane-by-2 implementation was routed by
`scripts/vivado_stem8x2_ooc_20260825.tcl`; reports are under
`build/reports/vivado_stem8x2_ooc_20260825/`. The split reduces area and power,
but still does not meet the 125 MHz target:

| Metric | 16-lane baseline | 8x2 split |
| --- | ---: | ---: |
| WNS / TNS | -11.040 / -29,994.178 ns | -10.364 / -17,450.668 ns |
| Setup failing endpoints | 8,974 / 42,188 | 8,017 / 42,188 |
| WHS / THS | +0.096 / 0 ns | +0.098 / 0 ns |
| LUT / FF / DSP / BRAM | 21,260 / 22,689 / 32 / 0 | 18,206 / 22,689 / 32 / 0 |
| Slice utilization | 78.86% (10,488 / 13,300) | 70.26% (9,344 / 13,300) |
| Total on-chip power | 0.486 W | 0.435 W |

Both runs fully routed with zero routing errors. The 8x2 worst path is
`kernel_x_idx_reg[1]` to `acc_reg_reg[12][30]`: 18.311 ns data-path delay,
including 10.940 ns routing. The split is a real area/power improvement and
reduces setup violation by 0.676 ns, but it is not a timing-closure solution.

The remaining critical cone is still the unregistered weight lookup, three
products, product reduction, and accumulator add. A future candidate needs a
pipeline boundary or a materially different sequential MAC schedule; another
same-cycle fanout-only split is unlikely to close 8 ns.
