# Tiled-load FSM CE tag isolation (2026-08-27)

## Scope

This candidate targets only the high-fanout `tiled_load_channel` to runner FSM
state-CE family.  It does not change the stem/DS engines, SRAMs, output buffer,
tile scheduler, top level, or bus protocol.

## Implementation

`rtl/cnn/cnn_layer_runner.v` now registers three descriptor-local load-control
tags: current padding, next padding, and SRAM word eligibility.  The tags are
initialized after the registered tile address setup and advanced on the same
scalar or vector4 cursor transition as the load.  Tiled-load FSM decisions use
the tags rather than the live channel comparator/carry chain, while addresses
and cursor progression retain their existing request order.  No per-byte or
per-channel wait state was added; no multicycle or false-path constraint was
used.

## Functional verification

Focused XSim command:

```text
scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_layer_runner_sram_bounds,tb_cnn_top_ctrl_bounds,tb_cnn_top_backpressure,tb_cnn_top_tiled_stem_datapath,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath
```

Result: `PASS cnn_xsim_regression tests=6`; checks were 27, 5 cases, 768,
16,384, 2,256, and 480 respectively.  The directed tests cover SRAM bounds,
ready/backpressure, tiled padding/edges, external scalar loads, and SRAM
vector4 loads.

The additional SRAM stem/DS directed test also passed independently:
`tb_cnn_top_sram_stem_dsblock_datapath`, 576 checks.

Serial fullnet Verilator command:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_runner_tiled_load_tags_20260827 ./scripts/run_all_sims.sh
```

Result: `PASS`, exact logits, `hw_cycles=982605`, `mem_reads=78890`,
`mem_writes=10`, status `0x0efe4d82`, and zero errors.

## Runner OOC timing

The reproducible flow is
`scripts/vivado_cnn_layer_runner_tiled_load_tags_20260827.tcl` using
Vivado 2025.2, `xc7z020clg400-1`, 8 ns, and post-route timing.

| Metric | Prior runner recurrence capture | Tag isolation | Delta |
|---|---:|---:|---:|
| WNS (ns) | -5.472 | -5.701 | -0.229 |
| TNS (ns) | -32016.582 | -31669.736 | +346.846 |
| WHS (ns) | +0.093 | +2.750 | +2.657 |
| Slice LUTs | 33124 | 34223 | +1099 |
| Slice registers | 34415 | 34426 | +11 |
| BRAM tiles | 32 | 32 | 0 |
| DSPs | 70 | 69 | -1 |
| Total on-chip power (W) | 0.300 | 0.289 | -0.011 |
| Unrouted nets | 0 | 0 | 0 |

The new runner-wide worst setup path is the intended registered cone,
`tiled_load_channel_reg[2]_replica/C -> tiled_load_next_padding_tag_reg/D`,
with 13.694 ns data delay.  The explicit target audit reports
`from_count=17`, `to_count=47`, `path_count=0` for
`tiled_load_channel_reg*/C -> FSM_onehot_state_reg*/CE`; the old direct
channel-to-state-CE family is absent.  The overall runner OOC WNS remains
negative and is 0.229 ns worse than the preceding recurrence capture, so this
is cone-isolation evidence rather than timing closure.

The full-top routed baseline remains separate evidence; no full-top route was
run for this candidate.
