# CSA Stem full-top post-route baseline (2026-08-28)

这是当前完整 `cnn_top` 的权威 CSA Stem 基线。报告目录为
`build/reports/vivado_cnn_top_impl/runs/20260828T_stem_csa_fulltop_max2/`，
使用 Vivado 2025.2、`xc7z020clg400-1`、10 ns 约束、Explore，运行参数为
`general.maxThreads=2`。该快照用于比较后续架构，不能与隔离 OOC 结果混用。

## 功能和周期

- XSim full-network logits：10/10 bit-exact
- 完整推理：`1,003,577` cycles
- 实际 MAC：`5,136,896`（按 MAC=2 ops）
- 外部 memory：`78,890` reads、`10` writes

## 完整顶层 post-route

| metric | result | target |
| --- | ---: | ---: |
| clock constraint | 10.000 ns | 125 MHz target requires 8 ns |
| WNS / TNS | -0.799 ns / -148.049 ns | >= 0 / 0 |
| WHS / THS | +0.065 ns / 0 ns | >= 0 / 0 |
| setup failing endpoints | 613 | 0 |
| Slice LUT | 34,831 (65.47%) | <70% |
| Slice FF | 37,052 (34.82%) | <70% |
| BRAM36 | 48 (34.29%) | <70% |
| DSP48E1 | 63 (28.64%) | <70% |
| vectorless on-chip power | 0.234 W | <=3 W |

Routing completed with zero route errors. The worst setup path is
`u_layer_runner/in_w_reg_reg[1]/C -> u_layer_runner/u_tile_scheduler/cur_w_reg[4]/R`:
10.286 ns data delay, including 3.920 ns logic and 6.366 ns routing. The first
20 paths also contain FC configuration addressing and tiled-loader control
families; this is a distributed control/routing problem, not a single-path
fix.

## Interpretation

At 125 MHz the functional baseline is approximately 5.47 GOPS/W using the real
MAC count and the Vivado power estimate. Reaching 20 GOPS/W at 0.234 W would
require about 274k cycles or fewer. Therefore this baseline is functionally
valid and resource-feasible, but does not meet timing, cycle, or energy goals.

This is complete-top FPGA-fabric evidence, not board measurement. I/O timing,
activity-file accuracy, bitstream execution and hardware power remain outside
the report.
