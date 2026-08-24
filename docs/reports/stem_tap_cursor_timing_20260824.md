# Stem tap-address cursor verification

Date: 2026-08-24  
Candidate commit: `b970a5c`  
Parent baseline: `5ffc44f` (`b970a5c^`)

## Implementation evidence

Fresh unique Vivado 2025.2 RuntimeOptimized OOC run:

```text
$env:VIVADO_IMPL_OUT_DIR='D:\Stuff\Project\build\reports\vivado_cnn_top_impl_stem_cursor_20260824'
$env:VIVADO_IMPL_RUN_ID='stem-cursor-20260824'
$env:VIVADO_IMPL_DIRECTIVE='RuntimeOptimized'
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_cnn_top_impl.tcl -tclargs cnn_top xc7z020clg400-1
```

Artifacts are under `build/reports/vivado_cnn_top_impl_stem_cursor_20260824/`.
The routed design completed with zero unrouted nets. The post-route summary is:

| Metric | Result |
| --- | ---: |
| WNS | -7.768 ns |
| TNS | -28665.969 ns |
| WNS failing endpoints | 13885 / 56253 |
| WHS | +0.058 ns |
| THS | 0.000 ns |
| Hold failing endpoints | 0 / 56253 |
| Route status | 0 failed, 0 unrouted, 0 partially routed |

Worst setup path is from
`u_layer_runner/u_ds_block_engine/rq_scan_idx_reg[0]_rep__1/C` to
`u_layer_runner/u_ds_block_engine/u_pw_requant/product_s1_reg__0/C[1]`.
It has 15.983 ns data delay (9.336 ns logic, 6.647 ns route), 8 logic
levels, and -7.768 ns slack. This is outside the stem engine; the cursor
change does not introduce a new stem path as the top-level critical path.

The parent baseline was WNS -8.114 ns, TNS -36158.195 ns, WHS +0.067 ns,
with no hold failures. Thus this run improves setup WNS by 0.346 ns and
TNS by 7492.226 ns while retaining positive hold slack.

## Regression comparison

The nine failures from the candidate's 41-test Verilator run were rerun from
a clean detached worktree at `5ffc44f` using:

```text
GENERATE_TEST_VECTORS=0 SIM_CONTINUE_ON_FAIL=1 \
SIM_ONLY="tb_cnn_top_ops_datapath tb_cnn_top_multilayer_datapath tb_cnn_top_tail_sram_datapath tb_cnn_top_e2e_sram_datapath tb_cnn_top_fullnet_sram_datapath tb_mmio_cnn_top_fullnet tb_rv_custom_if_cnn_top_fullnet tb_npc_bridge_cnn_top_fullnet tb_npc_rv_core_cnn_top_fullnet" \
SIM_LOG_DIR=build/reports/verilator_baseline_5ffc44f ./scripts/run_all_sims.sh
```

Every failure reproduced exactly on the baseline: same status, mismatch
address/value, checks, performance counters, and final status where present.

| Test | Baseline | Candidate | Exact diagnostic |
| --- | --- | --- | --- |
| `tb_cnn_top_ops_datapath` | FAIL | FAIL | case 2, `0x0002c010`, expected 2, actual 0, checks 1290 |
| `tb_cnn_top_multilayer_datapath` | FAIL | FAIL | case 1, `0x0002b010`, expected -3, actual 0, checks 1866 |
| `tb_cnn_top_tail_sram_datapath` | FAIL | FAIL | case 0, `0x00036010`, expected -2, actual 0, checks 10 |
| `tb_cnn_top_e2e_sram_datapath` | FAIL | FAIL | case 0, `0x00014010`, expected -1, actual 0, checks 10 |
| `tb_cnn_top_fullnet_sram_datapath` | FAIL | FAIL | case 0, `0x0004d410`, expected 2, actual 0; 993876 cycles, status `0f2a5482` |
| `tb_mmio_cnn_top_fullnet` | FAIL | FAIL | case 0, `0x0004d410`, expected 2, actual 0; 496939 polls, status `0f2a5482` |
| `tb_rv_custom_if_cnn_top_fullnet` | FAIL | FAIL | case 0, `0x0004d410`, expected 2, actual 0; 496939 polls, status `0f2a5482` |
| `tb_npc_bridge_cnn_top_fullnet` | FAIL | FAIL | case 0, `0x0004d410`, expected 2, actual 0; 993878 polls, status `0f2a5482` |
| `tb_npc_rv_core_cnn_top_fullnet` | FAIL | FAIL | logit 4 expected 39, actual 0; argmax 6 vs 4, status `0f2a5482` |

The candidate passed the targeted tiled-stem XSim and Verilator tests
(16384 checks each). No candidate-only behavioral or cycle regression was
found.
