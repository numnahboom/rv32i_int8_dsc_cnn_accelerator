# Tiled-store base address capture (2026-08-27)

## Scope

This candidate targets the route-B family in `rtl/cnn/cnn_layer_runner.v`:

`tile_h_start_reg_reg[*]/C -> tiled_store_addr_current_reg[*]/D`

The existing stride-capture change is retained.  No top-level route was run.

## Implementation

The tiled-store external and internal-SRAM base addresses, column jumps, and
row jumps are now captured in registers during `ST_TILED_LOAD_SETUP`, while
the scheduler tile coordinates and descriptor-derived dimensions are already
available.  `ST_TILED_STORE_SETUP` transfers those static terms into the
active store cursors.  The store-loop state machine and its transaction
cadence are unchanged.

## Functional verification

The focused XSim regression was run after the candidate patch:

```text
scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_layer_runner_sram_bounds,tb_cnn_top_backpressure,tb_cnn_top_tiled_stem_datapath,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath,tb_cnn_top_sram_stem_dsblock_datapath
PASS cnn_xsim_regression tests=6
```

The serial fullnet Verilator check also passed:

```text
PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10
PERF ... hw_cycles=1089117 ... errors=0 ... mem_reads=78890 mem_writes=10
```

## Runner OOC comparison

Both runs used `scripts/vivado_cnn_layer_runner_tile_store_base_20260827.tcl`
with `xc7z020clg400-1`, an 8 ns clock, and `RuntimeOptimized` synthesis.  The
baseline was run with the base-address candidate temporarily absent; the
candidate was restored before functional verification.

| Metric | Baseline | Candidate |
|---|---:|---:|
| WNS (ns) | -6.490 | -9.044 |
| TNS (ns) | -40278.211 | -58011.191 |
| WHS (ns) | +0.016 | +0.040 |
| THS (ns) | 0.000 | 0.000 |
| Slice LUTs | 33015 | 33121 |
| Slice Registers | 34301 | 34444 |
| BRAM tiles | 32 | 32 |
| DSPs | 69 | 69 |
| Route errors | 0 | 0 |
| Target path count | 20 | 0 |

The baseline target path had slack `-6.422 ns` and data-path delay
`14.447 ns` (`9.152 ns` logic, `5.295 ns` route), from
`tile_h_start_reg_reg[5]_replica_1/C` to `tiled_store_addr_current_reg[31]/D`.
The candidate query reported `from_count=5`, `to_count=32`, and
`path_count=0`, so the assigned tile-height-to-store-current cone disappeared.

However, the candidate worsened the runner-wide post-route WNS by `2.554 ns`
and TNS by `17732.980 ns`, with a small LUT/FF increase.  The new runner-wide
worst path is outside the assigned target family (`in_w_reg_reg[3]/C`).

## Boundary

The result establishes functional equivalence for the focused tests and full
net, plus runner-OOC target-cone removal.  It does not establish full-top
timing closure, board timing, or hardware behavior.  The runner-wide OOC
timing regression should be considered before retaining this candidate.
