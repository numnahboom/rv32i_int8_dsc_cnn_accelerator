# Tiled-store word-cursor timing trial (rejected)

Date: 2026-08-24  
Baseline commit: `673cb40` (FC bias-sum pipeline)  
Target: `xc7z020clg400-1`, `cnn_top`, Vivado 2025.2, post-route OOC, Explore

## Candidate

The trial changed only `rtl/cnn/cnn_layer_runner.v`. The external tiled-store
byte-address cursor was represented as a 30-bit word cursor with a separately
registered two-bit byte offset. Per-write increments therefore used a 30-bit
`+1`/jump operation instead of a 32-bit byte-address add. The one-outstanding
request and ready-stall protocol, output layout, arithmetic, and network
operations were unchanged.

The candidate was reverted after the routed result because setup timing became
worse. No candidate RTL remains in the working tree.

## Functional evidence

Windows XSim command:

```powershell
& .\scripts\run_cnn_xsim.ps1 -VivadoBin 'D:\Software\vivado2025.2\2025.2\Vivado\bin' -Tests @('tb_cnn_top_tiled_stem_datapath','tb_cnn_top_tiled_dsblock_datapath','tb_cnn_top_sram_tiled_dsblock_datapath','tb_cnn_top_backpressure','tb_cnn_top_fullnet_sram_datapath')
```

Result: `PASS cnn_xsim_regression tests=5`; tiled Stem `16384` checks, tiled
DSBlock `2256`, SRAM tiled DSBlock `480`, backpressure `768`, fullnet `10/10`.
Fullnet reported `995230` cycles, `5136896` MACs, and `10` checked logits.

WSL Verilator command:

```bash
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_cnn_top_tiled_stem_datapath tb_cnn_top_tiled_dsblock_datapath tb_cnn_top_sram_tiled_dsblock_datapath tb_cnn_top_backpressure tb_cnn_top_fullnet_sram_datapath" SIM_CONTINUE_ON_FAIL=1 SIM_LOG_DIR=build/reports/verilator_addr_cursor ./scripts/run_all_sims.sh
```

Result: all selected simulations passed. Fullnet: `hw_cycles=995230`,
`checks=10`, `errors=0`.

## Routed result

Command:

```powershell
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
```

Evidence: `build/reports/vivado_cnn_top_impl/runs/20260824T204740596-32696/`.

| metric | baseline (`673cb40`) | word cursor trial | delta |
| --- | ---: | ---: | ---: |
| WNS (ns) | -6.520 | -6.945 | -0.425 |
| TNS (ns) | -22702.494 | -22705.719 | -3.225 |
| WHS (ns) | +0.050 | +0.068 | +0.018 |
| THS (ns) | 0 | 0 | 0 |
| route | 0 unrouted | 0 unrouted | unchanged |
| fullnet cycles | 995230 | 995230 | 0 |
| total on-chip power | 0.220 W | 0.218 W | -0.002 W |
| LUT | 57.10% | 57.21% | +0.11 pp |
| DSP | 22.73% | 23.18% | +0.45 pp |

The top setup path remained the tiled-store cursor family, now ending at
`u_layer_runner/tiled_store_addr_word_current_reg[29]/D`. The path contains
the generated `tiled_store_addr_word_current1` adder and the routed carry
chain; it did not produce the intended setup improvement. The next paths also
remain in the same cursor family, with one tiled-store SRAM cursor path
following it.

## Decision

This is not a retained optimization. The small hold improvement (`+0.018 ns`)
does not compensate for the simultaneous WNS and TNS regressions, while cycle
count and functional behavior are unchanged. The RTL was restored and
`git diff --check` passed. This report is the only task-owned committed file.
