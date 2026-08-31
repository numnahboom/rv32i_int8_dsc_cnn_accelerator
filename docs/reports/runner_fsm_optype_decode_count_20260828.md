# Runner opcode-decode critical-path isolation (2026-08-28)

## Scope

This runner-only candidate targets the routed `op_type_reg -> FSM` control
cone identified in the prior 10 ns checkpoint.  The change is in
`rtl/cnn/cnn_layer_runner.v`; it keeps the descriptor operation and all
transaction-local control decisions in registered predecode fields.  The
descriptor output count is also captured during validation and consumed by
the store setup state, so the opcode-selected output-count multiplier is not
recomputed in the active FSM cone.  No engine arithmetic, precision, memory
ordering, ready/backpressure contract, or single-outstanding request rule was
changed.

## Functional validation

Focused Vivado XSim:

```text
& .\scripts\run_cnn_xsim.ps1 -VivadoBin 'D:\Software\vivado2025.2\2025.2\Vivado\bin' -Tests @('tb_cnn_layer_runner_sram_bounds','tb_cnn_top_ctrl_bounds','tb_cnn_top_backpressure','tb_cnn_top_tiled_stem_datapath','tb_cnn_top_tiled_dsblock_datapath','tb_cnn_top_sram_tiled_dsblock_datapath')
```

Result: `PASS cnn_xsim_regression tests=6`; checks were 27, 5 cases, 768,
16,384, 2,256, and 480 respectively.

Fullnet Verilator:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_runner_fsm_optype_decode_count_20260828 ./scripts/run_all_sims.sh
```

Result: exact logits, `hw_cycles=1003417`, `mem_reads=78890`,
`mem_writes=10`, status `0x0f4f9982`, and zero errors.

## Runner-only post-route evidence

The runner OOC flow used `xc7z020clg400-1`, Vivado 2025.2, and a 10 ns clock
with `scripts/vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl`.
It does not rebuild `cnn_top` and does not establish full-top timing closure.

| Metric | Candidate |
|---|---:|
| Clock period / nominal frequency | 10 ns / 100 MHz |
| Post-route WNS | -2.324 ns |
| Post-route TNS | -1715.732 ns |
| Setup failing endpoints | 3833 |
| Post-route WHS | +0.095 ns |
| Slice LUTs | 33,520 (63.01%) |
| Slice registers | 34,689 (32.60%) |
| BRAM36 | 32 (22.86%) |
| DSPs | 69 (31.36%) |
| Estimated total on-chip power | 0.242 W |
| Unrouted nets | 0 |

The fresh checkpoint query in
`build/reports/vivado_cnn_layer_runner_fsm_optype_decode_count_20260828/`
reports `from_count=32`, `to_count=1`, `path_count=0` for
`op_type_reg*/C -> FSM_onehot_state_reg[21]/D`.  The runner-wide worst path is
instead the stem requant DSP path, with 10.539 ns data delay.  The target path
is therefore removed, but the runner-wide result remains setup-negative.

## Recommendation

Retain the candidate as a behavior-preserving control-cone isolation.  Do not
claim full-top timing closure or integrated Fmax improvement from this OOC
result; a fresh `cnn_top` post-route run is required for that decision.
