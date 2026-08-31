# Tiled-input row-base recurrence isolation (2026-08-28)

## Scope

This candidate targets the integrated top-level route's worst tiled-load cone,
`tiled_input_row_stride_reg_reg -> tiled_input_row_base_reg0 -> tiled_input_index_next`.
The change is local to `rtl/cnn/cnn_layer_runner.v`; no engine, memory protocol,
precision, or tile schedule was changed.

## RTL change

Added the registered `tiled_input_next_row_base_reg` cursor.  It is initialized
in `ST_TILED_ADDR_INDEX` to `row_base + row_stride`, then advanced by the fixed
row stride only when a scalar or vector4 load wraps a tile-input row.  The
row-wrap index function now adds `tiled_input_tile_col_base_reg` to this
precomputed cursor rather than recomputing `row_base + row_stride` in the
per-request cone.  Existing row-base and index updates remain in lockstep, so
padding, scalar fallback, vector4 tails, request ordering, single-outstanding
ready/response behavior, and backpressure semantics are unchanged.

The setup path adds no active load state; it uses the existing registered
address setup states.  The only additional state is 32 bits of storage.

## Functional validation

Focused Vivado XSim command:

```text
& .\scripts\run_cnn_xsim.ps1 -VivadoBin 'D:\Software\vivado2025.2\2025.2\Vivado\bin' -Tests @('tb_cnn_layer_runner_sram_bounds','tb_cnn_top_ctrl_bounds','tb_cnn_top_backpressure','tb_cnn_top_tiled_stem_datapath','tb_cnn_top_tiled_dsblock_datapath','tb_cnn_top_sram_tiled_dsblock_datapath')
```

Result: `PASS cnn_xsim_regression tests=6`; checks were 27, 5 cases, 768,
16,384, 2,256, and 480 respectively.

Fullnet Verilator command:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_runner_rowbase_recurrence_20260828 ./scripts/run_all_sims.sh
```

Result: exact logits, `hw_cycles=958174`, `mem_reads=78890`, `mem_writes=10`,
status `0x0e9ede82`, and zero errors.  The reported layer transaction counts
remain scalar/word SRAM transactions with no new request class.

## Runner-only post-route evidence

The runner OOC flow was run on `xc7z020clg400-1` with Vivado 2025.2 at a 10 ns
clock using `scripts/vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl`
with `RUNNER_OOC_OUT=vivado_cnn_layer_runner_rowbase_recurrence_10ns_20260828`
and `RUNNER_OOC_PERIOD=10`.  It is runner-only and does not replace a fresh
`cnn_top` post-route result.  The checkpoint was queried with
`scripts/query_runner_rowbase_recurrence_20260828.tcl`.

| Metric | Candidate |
|---|---:|
| Clock period / nominal frequency | 10 ns / 100 MHz |
| Post-route WNS | -2.865 ns |
| Post-route WHS | +0.094 ns |
| Post-route TNS | -4831.452 ns |
| Slice LUTs | 33,439 (62.86%) |
| Slice registers | 34,601 (32.52%) |
| DSPs | 70 (31.82%) |
| BRAM36 | 32 |
| Estimated total on-chip power | 0.300 W |
| Unrouted nets | 0 |

The explicit row-base query reports no direct timing path from the registered
stride source to the registered tiled index destination (`from_count=48`,
`to_count=30`, `path_count=0`; the netlist contains the new
`tiled_input_next_row_base_reg` cursor).  The new runner-wide worst path is
outside this target: `store_channel_pos_reg[1]/C` to output-buffer BRAM
`ENBWREN`, WNS `-2.865 ns`.  The old row-base recurrence still has setup paths
from `input_addr_reg` into the row-base multiply, but the active-load
row-wrap recurrence no longer traverses stride -> row-base -> index in one
cone.

## Recommendation

Keep the RTL candidate and its focused/fullnet regressions: it is behavior
preserving and removes the targeted recurrence dependency.  Do not claim
timing closure or top-level improvement from this runner-only screen.  A fresh
full `cnn_top` implementation is required to determine whether the integrated
critical path moved; the 10 ns runner result remains setup-negative.
