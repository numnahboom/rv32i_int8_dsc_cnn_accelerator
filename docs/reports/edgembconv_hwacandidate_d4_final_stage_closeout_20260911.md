# EdgeMBConv D4 最终阶段收尾（2026-09-11）

## 摘要

D4 软件网络、INT8 语义与 standalone v6 功能链已冻结；本轮停止优化，不再启动新候选、Vivado、route、power、shape sweep 或 fullnet 开发。candidate1--6 的失败记录保留为历史证据，candidate4 是功能/综合阶段的 retained 参考。恢复后的 scheduler、v2 datapath、RQ pool regin 与 DW prep 语义仿真全部通过：8192 bytes、2048 words，no-BP 24039 cycles，random BP 25389，final stall 25421，two-epoch 25389/25389，所有 ledger 守恒且 errors=0。四个 owned RTL 已与 candidate4 retained hash 精确一致，14-source manifest gate PASS。

## 1. 冻结软件账本、INT8 语义与 C0 边界

- D4：204,090 参数；11,645,440 semantic MAC；23,290,880 ops；官方 CIFAR-10 test10k INT8 top-1 为 91.46%（9,146/10,000）。
- 语义：signed INT8 activation/weight；per-output-channel symmetric weight；INT32 accumulator/bias；nearest-away-from-zero requant；signed INT8 saturation。
- `sw/model/model_quant.h` 明确属于冻结 C0 ABI，不是 D4 deployment source；其参数、accuracy、MAC、cycles 或 PPA 不得重标为 D4。

## 2. 从可运行到可实现：v3 → v6 的主线叙事

这条主线不是单纯追求更低的仿真周期，而是在吞吐、精确整数语义和 XC7Z020 物理可实现性之间反复收敛：

| 版本 | 关键进展 | exact 周期 / 物理结论 |
|---|---|---|
| v3 | 建立独立 D4 vstream、aligned 32-bit sink 与完整事务账本 | no-BP/random BP `43688/44965` |
| v4 | 引入 mb16_down、同步 DW request/response 与双 context | `36401/37927` |
| v5 | 将 no-BP 降至 `23843` | 综合约 `264810 LUT`，远超器件容量，否决 |
| v6 | banked activation/weights、16-lane BRAM raw FIFO、DW cursor/lookahead、PW operand stage，并补齐 no-BP/random/final-stall/two-epoch 验收 | retained candidate4 no-BP `24039`；资源过门，但 8 ns setup 未闭合 |

因此，本阶段最有价值的成果不是一个未经物理约束的最低周期数字，而是一份完整保存的、功能 exact、资源可放入器件、且失败边界明确的 v6 实现。candidate5/6 的时序收益门失败后停止扩展，恢复 candidate4 作为最后接受的可复现参考。

## 3. candidate1--6 证据表

| 候选 | 功能结果 / standalone cycles | synth setup WNS/TNS (ns) | synth resources | route / power |
|---|---|---:|---|---|
| candidate1 | PASS / 24354 | -2.701 / -1724.647 | LUT 28917、FF 29299、DSP 145、BRAM 28 | 未运行 |
| candidate2 | PASS / 24032 | -2.701 / -1691.249 | LUT 34253、FF 25257、DSP 145、BRAM 28 | 未运行 |
| candidate3 | PASS / 24032 | -2.596 / -1539.966 | LUT 32739、FF 27021、DSP 145、BRAM 28 | 未运行 |
| candidate4 retained | PASS / 24039 | -2.451 / -1105.460 | LUT 33174、FF 25146、DSP 145、BRAM 28 | fresh OOC route/power 有历史证据，见下节 |
| candidate5 | PASS / 24361 | -2.451 / -1377.290 | LUT 33047、FF 32793、DSP 145、BRAM 28 | 未运行 |
| candidate6 | PASS / 24368 | -2.334 / -1544.753 | LUT 33442、FF 29564、DSP 145、BRAM 28 | 未运行；无 route/power |

candidate6 仅有 functional+synth negative result；不得伪造其 route 或 power。candidate1--3/5 的 route、power 也没有被运行或不能支持 closure 结论。

## 4. retained candidate4 manifest 与最终功能回归

四个 owned RTL 的目标 hash 为：scheduler `5A3B346E...A1BFD`、v2 datapath `B77190FE...A21F86A`、elastic RQ pool regin `EC95DDE8...6AE90`、DW tile `C9321538...07EFF`；四项均 MATCH（regin MATCH_UNCHANGED），其余 14 个 manifest source 也全部 MATCH。DW 精确快照为 `build/reports/d4_v6_dwcone_candidate4_start_cursor_prep1_20260910/candidate4_dw16_stream_tile_C9321538.v`。

新日志目录：`build/reports/d4_v6_final_closeout_20260911/`。

| 回归 | 结果 |
|---|---|
| DW request adapter | PASS，requests/responses 26/26，halo K4+K5+K7+K8，interior K0..K8 |
| DW16 tile | PASS，3 cases / 2 real / 1 tail |
| v6 no-BP | PASS，24039 cycles，8192 bytes / 2048 words |
| v6 random BP | PASS，25389 cycles，sink stall 126 |
| v6 final-word stall | PASS，25421 cycles，sink stall 158 |
| v6 two-epoch | PASS，epoch10/11 = 25389/25389 |

每个 epoch 的守恒账本为 PW/DW/RQ `786432/73728/12288`，DW req/resp `4418/4418`，DW cfg/start `288/8`，DW RQ/P RQ `2048/2048`，final bytes `8192`，sink words `2048`，errors=0。

## 5. candidate4 fresh OOC route（历史真实证据）

candidate4 fresh OOC route：fully routed `47860/47860`；post-route WNS/TNS `-1.028/-1461.586 ns`；WHS/THS `+0.071/0`；LUT `18000/33.83%`、FF `25133/23.62%`、DSP `145/65.91%`、BRAM `28/20%`；vectorless OOC power `0.406 W`。当前提交源码与该 candidate4 route/power manifest 的 14/14 source lines 同源且 hash 已复核一致。

在 8 ns 时钟下，standalone no-BP 的 `24039` cycles 对应 `192.312 µs`，但这只是 mb16 standalone block 的延迟上下文。该 OOC 结果仍未闭合 8 ns setup，且 OOC 不是 full-top；不能推出 D4 full-network timing、功耗、单次推理能量或板级结论。

## 6. C0 冻结 control（独立列示）

C0 保持独立 control：`cnn_top` / `model_quant.h` ABI、10,273,792 ops、no-BP `219970` cycles、full-top WNS `-0.880 ns`、DSP 151、power `0.479 W`。C0 也未通过 timing 与 20 GOPS/W，且不替代 D4 的 standalone、OOC 或 full-top 证据。

## 7. 最终目标状态矩阵

| 目标 | 状态 | 证据边界 |
|---|---|---|
| accuracy | 已证 | D4 official test10k INT8 91.46% |
| standalone cycles | 已证 | candidate4 functional regression，见日志 |
| source exact retained hash | 已证 | 四项 owned RTL 与 14-source manifest 全部 MATCH |
| full inference cycles / latency | 未证 | 当前仅 standalone `24039 cycles / 192.312 µs`，不能代替全网 |
| fullnet timing / 8 ns closure | 未证 | OOC setup 为负，OOC 非 full-top |
| full-top power | 未证 | `0.406 W` 只属于 candidate4 OOC vectorless |
| mJ/inference | 未证 | 缺少同一 fullnet/full-top 快照的真实 cycles 与 power |
| GOPS/W | 未证 | 必须用真实 `23290880 ops`、full inference cycles 与 full-top power；当前不能计算 |

## 8. 未达原因、否决候选与未来入口

candidate1--3、5、6 的共同问题是 setup/TNS 仍为负；candidate5/6 的 mandatory WNS/TNS simultaneous-improvement gate 失败，candidate6 虽改善 WNS 至 -2.334 ns，却把 TNS 恶化至 -1544.753 ns。最终能效门等价于 `cycles × power_W ≤ 145568`，但当前没有覆盖完整 D4 推理的同源 cycles/power 组合，所以既不能宣称达标，也不能用 OOC 数字做乐观外推。后续工作应以当前 candidate4 manifest、OOC run 与功能回归入口为同源起点；本收尾不提出新优化方向。

## 9. Git 收尾与证据边界

本报告随 `refactor/streaming-dsblock-bram` 阶段检查点一并提交；提交态保留 D4、冻结 C0 control、DS1/M11A 历史实验及其源码级报告。体积巨大的 `build/`、`.Xil/`、DCP、仿真缓存和原始日志继续由 `.gitignore` 隔离，不作为 GitHub 源码资产。提交前要求全树 `git diff --check`、staged whitespace 检查、敏感信息扫描和 GitHub 文件大小检查通过。

这些 Git 检查只证明工作树完整性和可追踪性，不能把 standalone/OOC 证据提升为 fullnet/full-top acceptance。当前阶段的诚实结论仍是：accuracy 和 standalone exactness 已证，资源门已证，8 ns setup、full-network cycles、full-top power、mJ/inference 与 GOPS/W 均未达成或未验证。
