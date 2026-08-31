# DS double-bank source recurrence (2026-08-27)

## Implementation

`ds_input_tile_buffer_bram` now contains independent bank-0 and bank-1 input
memories with an explicit write-bank and read-bank. `ds_block_tile_engine_new`
tracks active-bank ownership plus valid/tag state. A complete tile is committed
only after its final scalar/vector4 write; an active bank rejects writes and a
start with an invalid or mismatched tag enters the existing error path.

`cnn_layer_runner` launches the current DS tile from bank A, advances the tile
scheduler, and streams the next tile into bank B through the existing single
outstanding external-read path. The next engine launch waits for both the
compute-done and prefetch-commit conditions, so slow/backpressured reads drain
without same-bank accesses. Source stride is decoded once into
`source_stride_reg`; tiled address setup derives halo/row bases from that
snapshot and the hot loop uses fixed channel/pixel/row increments.

## Verification

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_ds_block_tile_engine_banked
PASS ... overlap_writes=16 outputs=6

GENERATE_TEST_VECTORS=0 SIM_ONLY=tb_cnn_top_tiled_dsblock_datapath ./scripts/run_all_sims.sh
PASS ... cases=2 checks=2256

GENERATE_TEST_VECTORS=0 SIM_ONLY=tb_cnn_top_fullnet_sram_datapath ./scripts/run_all_sims.sh
PASS ... hw_cycles=862651 checks=10 errors=0 mem_reads=78890 mem_writes=10
```

The focused bank test exercises active-bank backpressure, concurrent inactive
bank writes, commit tags, and wrong-tag rejection. The tiled test covers the
two tiled cases and exact output writes.

## OOC result

The fresh fully routed Vivado 2025.2 XC7Z020 OOC run is in
`build/reports/vivado_ds_block_tile_engine_new_8ns_ooc_20260827_explore`.
It has zero routing errors and 17,464 Slice LUTs (16,452 LUT-as-logic), but
post-route WNS is `-3.182 ns` at 8 ns; WHS is `+0.098 ns`. The plain
RuntimeOptimized run was `WNS=-3.174 ns`, `WHS=+0.093 ns`. Therefore this
candidate is functionally/performance positive but does not meet the required
8 ns DS OOC setup criterion; it is not timing closure evidence.
