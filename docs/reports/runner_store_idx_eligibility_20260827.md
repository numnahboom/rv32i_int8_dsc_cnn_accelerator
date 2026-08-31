# Output-buffer store-index cone reduction (2026-08-27)

## Scope and change

The runner's synchronous output-buffer read address previously depended on
`store_idx` through the vector4 eligibility predicates. For DS stores,
`store_count` is exactly `pixel_count * store_active_channels`, and the cursor
advances only by whole channel groups. Therefore the channel-position test
already proves that four channels remain; the redundant `store_idx+3 <
store_count` tests were removed from `store_word_eligible` and
`store_next_word_eligible` in `rtl/cnn/cnn_layer_runner.v`.

This preserves scalar/vector4 ordering, tails, SRAM alignment fallback, and
single-outstanding behavior while removing the store-index dependency from the
word-address selection cone.

## Functional validation

Fresh Vivado 2025.2 XSim passed:

```text
tb_cnn_top_tiled_dsblock_datapath             2256 checks
tb_cnn_top_sram_tiled_dsblock_datapath        480 checks
tb_cnn_top_backpressure                       768 checks
tb_cnn_top_fullnet_sram_datapath                10 checks
```

The fullnet remained bit-exact with `5,136,896` MACs and `958,174` hardware
cycles.

## Fresh runner-only OOC result

Command used the existing recurrence OOC flow with
`RUNNER_OOC_PERIOD=10.000` and output directory
`build/reports/vivado_cnn_layer_runner_store_idx_eligibility_10ns_20260827/`.
The `xc7z020clg400-1` design routed with zero routing errors and zero unrouted
nets. The explicit historical target query still reports
`tile_h_start_reg -> tiled_store_addr_current_reg: path_count=0`.

| Metric | Prior recurrence | This candidate | Delta |
|---|---:|---:|---:|
| WNS | -3.354 ns | -2.707 ns | +0.647 ns |
| TNS | -4674.572 ns | -3250.077 ns | +1424.495 ns |
| WHS | +0.096 ns | +0.075 ns | -0.021 ns |
| Setup failing endpoints | 6137 / 82199 | 5363 / 82243 | improved |
| Slice LUTs | 33,242 | 33,259 | +17 |
| Slice registers | 34,385 | 34,498 | +113 |
| BRAM tiles | 32 | 32 | unchanged |
| DSPs | 70 | 70 | unchanged |
| Total on-chip power estimate | 0.293 W | 0.248 W | -0.045 W |

The former output-buffer address path is absent from the worst path. The new
runner-wide worst setup path is `phase_count_for01/CLK ->
sram_input_count_reg_reg[30]/D`, with 12.610 ns data delay (9.794 ns logic,
2.816 ns route). WNS remains negative, so this is not timing closure or
full-top evidence.
