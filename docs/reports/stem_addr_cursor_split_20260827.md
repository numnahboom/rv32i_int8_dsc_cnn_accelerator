# Stem cursor-to-accumulator split

Date: 2026-08-27  
Device: `xc7z020clg400-1`, Vivado 2025.2, 8 ns clock

`rtl/cnn/conv3x3_stem_engine_new.v` now has a registered `product_sum_reg`
between the distributed-RAM reads/three 8x8 products and `acc_reg`. The new
`ST_OPERAND` state captures one tap's three-product sum; `ST_MAC` consumes the
registered sum and advances the cursor. The convolution arithmetic, output
ordering, requantization, handshake, and image dimensions are unchanged.

This is a legal one-cycle-per-tap stage split. A stem operation therefore adds
9 cycles per output channel (for a 1x1, 16-channel direct test: 210 to 354
cycles, +144 cycles).

## Functional evidence

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_addr_split` | PASS, 16 writes, 354 cycles |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 writes, 226 cycles |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS |
| `tb_cnn_top_backpressure` | PASS, 768 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10/10 logits, 958,045 cycles |

Commands used:

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_addr_split
SIM_ONLY="tb_conv3x3_stem_engine_new_requant tb_cnn_top_tiled_stem_datapath tb_cnn_top_sram_stem_dsblock_datapath tb_cnn_top_backpressure" ./scripts/run_all_sims.sh
SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" ./scripts/run_all_sims.sh
```

## Fresh isolated OOC evidence

The reproducible Tcl flow is `scripts/vivado_stem_addr_cursor_split_20260827.tcl`.
Candidate reports are under
`build/reports/vivado_stem_addr_cursor_split_20260827/`; a same-flow baseline
run is under `build/reports/vivado_stem_addr_cursor_baseline_20260827/`.

| Metric | Baseline | Split | Delta |
| --- | ---: | ---: | ---: |
| WNS | -7.388 ns | -6.520 ns | +0.868 ns |
| TNS | -5966.763 ns | -3986.121 ns | +1980.642 ns |
| WHS | +0.155 ns | +0.131 ns | -0.024 ns |
| THS | 0.000 ns | 0.000 ns | 0 |
| Slice LUTs | 10,892 | 11,085 | +193 |
| Slice registers | 2,906 | 2,873 | -33 |
| DSPs | 10 | 10 | 0 |
| fully routed nets | 10,331 | 10,301 | -30 |

The prior worst cursor/address-to-accumulator path was 15.287 ns
(6.183 ns logic / 9.104 ns route, 21 levels, 9 CARRY4) in
`vivado_stem_addr_cursor_baseline_20260827/timing_maxpaths_post_route.txt`.
After the split, the corresponding cursor-to-`product_sum_reg` path is
13.407 ns (5.061 ns logic / 8.346 ns route, 17 levels, 6 CARRY4), and the
registered `product_sum_reg`-to-`acc_reg` path is 6.798 ns setup delay with
1.193 ns slack. The target path is materially improved, although overall OOC
timing remains negative-WNS and this is not timing closure.

The Tcl audit writes the discovered endpoints to `discovered_groups.txt` and
the two cone reports to `cursor_to_product_sum_max.txt` and
`product_sum_to_acc_max.txt` (with matching min reports).
