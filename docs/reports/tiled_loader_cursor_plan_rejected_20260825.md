# Tiled-loader cursor-plan candidate rejected (2026-08-25)

The tiled-loader cursor/plan-capture candidate was rejected on timing.  Its
functional behavior was correct in directed tiled stem, tiled DS, SRAM tiled
DS, and fullnet checks, but it failed the required runner-local 8 ns timing
gate.  Only the candidate hunks were removed from `cnn_layer_runner.v` and
`tile_scheduler.v`; the retained spatial-area pipeline and tiled-store
`out_w` snapshot remain in the worktree.

Fresh Vivado 2025.2 synthesis evidence for the candidate (part
`xc7z020clg400-1`) is in `build/reports/tiled_loader_wrapper_synth.log` and
`build/reports/cnn_top_synth.dcp`.  The refined 8 ns local query is recorded in
`build/reports/tiled_loader_8ns_query_refined.log`:

| Local path | Delay | Result |
| --- | ---: | --- |
| `in_w_reg -> tiled_src_x_reg` | 14.166 ns | fail |
| `in_w_reg -> tiled_src_y_reg` | 13.828 ns | fail |
| `tiled_load_channel_reg -> mem_req_addr_reg` CE | 12.050 ns | fail |
| `tiled_load_channel_reg -> sram_input_rd_en_reg` | 10.916 ns | fail |
| `in_w_reg -> u_tile_scheduler/valid_reg` | 10.114 ns | fail |

No full P&R was launched because the local pre-P&R gate failed.  The candidate
therefore provides no timing-closure or board-validation evidence.

The restored control baseline was checked with `./scripts/run_all_sims.sh`
(Verilator): the first 10/41 tests passed before the broad suite was stopped
to avoid duplicating unrelated long regressions.  The relevant fullnet smoke
was then run with `./scripts/run_multi_sample_rtl.sh`: 3/3 samples passed,
each at 1,021,031 cycles with matching argmax and status `0f946782`.
