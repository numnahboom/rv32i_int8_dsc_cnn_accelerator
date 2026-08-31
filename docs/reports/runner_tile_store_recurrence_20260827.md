# Tiled-store recurrence address generator (2026-08-27)

## Scope

This candidate targets Route-B in `rtl/cnn/cnn_layer_runner.v`, from
`tile_h_start_reg` to `tiled_store_addr_current_reg`.  It changes only the
runner tiled-store address state and adds a runner-only OOC Tcl screen.

## Implementation

The first tiled-store address is formed during setup, but the coordinate
arithmetic is split across `ST_TILED_STORE_BASE_ADD`,
`ST_TILED_STORE_BASE_MUL`, and `ST_TILED_STORE_BASE_FINISH`.  The active loop
uses independent row-base and column-base registers.  Within a pixel, the
address advances by one fixed channel element (4 external bytes or 1 SRAM
byte); at a pixel boundary the column base advances by the full output-channel
stride, and at a tile-row boundary the row base advances by the full output
row stride.  External scalar stores, internal SRAM scalar stores, vector4
stores, tails, and ready/backpressure paths retain their existing transaction
cadence and ordering.

The three setup states add 3 cycles per scheduled tile.  The fullnet run below
used 43 tiles, hence the measured +129 cycles versus the exact parent baseline.

## Functional verification

Focused XSim command:

```text
scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_layer_runner_sram_bounds,tb_cnn_top_backpressure,tb_cnn_top_tiled_stem_datapath,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath,tb_cnn_top_sram_stem_dsblock_datapath
```

Result: `PASS cnn_xsim_regression tests=6`; individual checks were 27, 768,
16384, 2256, 480, and 576.  This covers tiled scalar external stores,
stride/padding/tile edges, vector4 SRAM stores and tails, SRAM bounds, and
ready/response backpressure.

Serial fullnet Verilator command:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_runner_tiled_store_recurrence_20260827 ./scripts/run_all_sims.sh
```

Result: `PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10`, exact logits,
`hw_cycles=1089246`, `mem_reads=78890`, `mem_writes=10`, `errors=0`.
The parent exact baseline was 1,089,117 cycles; the +129-cycle delta is the
three setup states for each of 43 tiles.

## Runner OOC result

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -notrace -source scripts/vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl
```

The run used `xc7z020clg400-1`, 8 ns, `RuntimeOptimized`, and completed with
zero route errors and zero unrouted nets.  Compared with the preceding base
capture (`runner_tile_store_base_20260827.md`):

| Metric | Base capture | Recurrence |
|---|---:|---:|
| WNS (ns) | -6.490 | -5.472 |
| TNS (ns) | -40278.211 | -32016.582 |
| WHS (ns) | +0.016 | +0.093 |
| Slice LUTs | 33015 | 33124 |
| Slice registers | 34301 | 34415 |
| BRAM tiles | 32 | 32 |
| DSPs | 69 | 70 |
| Total on-chip power (W) | not recorded | 0.300 |

The new runner-wide worst setup path is outside Route-B:
`store_idx_reg[1]/C -> u_out_buffer/u_output_memory/xpm_memory_base_inst/gen_wr_a.gen_byte_narrow.for_mem_cols[1].mem_reg_2/ADDRBWRADDR[7]`,
12.822 ns data delay (5.723 ns logic, 7.099 ns route).  The explicit target
query reports `from_count=5 to_count=32 path_count=0`, so no
`tile_h_start_reg -> tiled_store_addr_current_reg` paths remain.

This is routed runner-fabric evidence only: WNS remains negative, so it does
not establish timing closure, full-top timing, board timing, or hardware
behavior.
