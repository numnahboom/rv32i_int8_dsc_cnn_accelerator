# Tiled-input stride parameter capture

Date: 2026-08-27  
Device: `xc7z020clg400-1`, Vivado 2025.2, 8 ns runner OOC

## Change

`rtl/cnn/cnn_layer_runner.v` now uses the already registered halo origins
(`tiled_input_halo_row_offset_reg` and `tiled_input_halo_col_offset_reg`) in
the current/next tiled-input padding predicates.  The predicates therefore no
longer recompute `tile_*_start_reg * effective_stride` while generating the
per-element request and `tiled_input_index_next_reg` control.  The registered
halo values are captured in `ST_TILED_ADDR_OFFSETS`, before any tiled load
request, so the descriptor ABI, tile data, padding/stride meaning, request
cadence, single-outstanding handshake, and backpressure behavior are unchanged.
No new state or active-load cycle was added.

## Functional verification

Command:

```text
& .\scripts\run_cnn_xsim.ps1 -VivadoBin 'D:\Software\vivado2025.2\2025.2\Vivado\bin' -Tests @('tb_cnn_layer_runner_sram_bounds','tb_cnn_top_ctrl_bounds','tb_cnn_top_backpressure','tb_cnn_top_tiled_stem_datapath','tb_cnn_top_tiled_dsblock_datapath','tb_cnn_top_sram_tiled_dsblock_datapath')
```

Result: `PASS cnn_xsim_regression tests=6`; SRAM bounds 6 cases/27 checks,
control bounds 5 cases, backpressure 2 cases/768 checks, tiled Stem 16,384
checks, tiled DSBlock 2,256 checks, and SRAM tiled DSBlock 480 checks.  These
tests cover tiled padding/boundaries, stride-bearing tiled vectors, SRAM
loads, and ready/response stalls.  No request or cycle schedule change was
observed in the focused tests.

After the local timing screen passed, the serial fullnet Verilator check was:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_runner_stride_capture_20260827 ./scripts/run_all_sims.sh"
```

Result: `PASS`, 10/10 logits, `hw_cycles=1089117`, status `0x109e5d82`,
`mem_reads=78890`, `mem_writes=10`, and zero errors.  The fullnet report also
records layer word/scalar SRAM transactions; this candidate itself adds no
transaction type or request.

## Runner OOC timing

The reproducible post-route flow is
`scripts/vivado_cnn_layer_runner_stride_capture_20260827.tcl`.  It builds
`cnn_layer_runner` only (not `cnn_top`) at 8 ns, then runs opt/place/phys-opt/
route and writes reports under
`build/reports/vivado_cnn_layer_runner_stride_capture_20260827/`.

The baseline was generated with the same script and worktree, temporarily
using the two original padding expressions; the source was restored to the
candidate before the final verification.

| Metric | Baseline | Halo-origin capture | Delta |
| --- | ---: | ---: | ---: |
| WNS | -6.875 ns | -6.490 ns | +0.385 ns |
| TNS | -42642.641 ns | -40278.210 ns | +2364.431 ns |
| WHS | +0.091 ns | +0.016 ns | -0.075 ns |
| Slice LUTs | 33189 | 33015 | -174 |
| Slice registers | 34299 | 34301 | +2 |
| BRAM tiles | 32 | 32 | 0 |
| DSPs | 69 | 69 | 0 |
| Unrouted nets | 0 | 0 | 0 |

The candidate remains setup-negative and is not timing closure.  The new
runner OOC worst path is `store_channel_pos_reg[7]/C` to
`u_out_buffer/u_output_memory/xpm_memory_base_inst/gen_wr_a.gen_byte_narrow.for_mem_cols[1].mem_reg_3/ENBWREN`,
13.963 ns datapath delay.  It is outside the assigned stride/input-address
cone.

## Target-cone result

Baseline target audit had 20 paths from `stride_reg_reg[*]/C` to
`tiled_input_index_next_reg*/CEC`; its worst path was
`stride_reg_reg[6]/C -> tiled_input_index_next_reg0/CEC`, WNS `-6.422 ns`,
13.924 ns data delay (5.141 ns logic, 8.783 ns route), 20 logic levels and
7 CARRY4s.  The candidate audit matched 58 source pins and 2 destination pins
but found `path_count=0`.  Thus the requested direct stride-to-index-CE cone
is absent in this runner OOC netlist.  The complete-top route DCP remains
unmodified; no full-top route was run for this candidate.

Remaining risk: the runner OOC result is not a substitute for integrated
top-level timing, and fullnet Verilator does not establish FPGA timing or
hardware behavior.
