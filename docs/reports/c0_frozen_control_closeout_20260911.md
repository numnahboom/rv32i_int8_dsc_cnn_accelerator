# C0 冻结 control：软件与硬件演进收尾（2026-09-11）

## 摘要

C0 是本项目最早贯通 Python golden、INT8 导出、RV32I/NPC、descriptor-driven `cnn_top`、完整十类 logits、真实 memory backpressure 和 XC7Z020 full-top implementation 的网络。它经历了长期的 Stem/FC/requant 流水化、SRAM/BRAM 化、DW banking、PW/DS 数据流和 shared64 集成，最终冻结为 D4 的 control；C0 不再作为网络优化主线，也不得替代 D4 的 accuracy、MAC、cycles 或 PPA 证据。

## 1. 软件质量演进

| 软件快照 | FP32 official test10k | INT8 official test10k | 结论 |
| --- | ---: | ---: | --- |
| 初始 control checkpoint | 50.38% | 47.31% | 建立部署整数 evaluator，质量较低 |
| C0 重新训练 | 70.05% | 66.16% | 72,010 参数、5,136,896 MAC |
| C0 BN-fold PTQ | 88.43% | 79.23% | BN fold 等价，但 INT8 质量门失败 |
| C0 BN-fold QAT | 87.70% fake-QAT | 77.61% exported INT8 | 比 PTQ 低 1.62 pp，负结果 |

权威来源分别为 `c10_hwqa_v1_baseline.md`、`c10_hwqa_c0_full_training_report_fixed.md`、`c10_hwqa_c0_bnfold_report_20260902.md` 和 `c10_hwqa_c0_bnfold_qat_report_20260902.md`。这些是不同软件快照；除非 source manifest/hash 明确同源，不应自动绑定到任意硬件 run。

## 2. 硬件演进

| 阶段 | 关键变化 | 代表证据 |
| --- | --- | --- |
| 端到端基线 | Python/firmware/RV32I/RTL/fullnet logits 闭环 | 2026-06 初始提交与 `README.md` |
| Streaming BRAM | 移除大型 packed payload，feature SRAM、DW tile 和 output buffer BRAM 化 | `streaming_engine_refactor_guide.md`、`development_log.md` |
| Timing-driven pipeline | Stem、FC、requant、tiled load/store、地址 cursor 和 span validation | 2026-08-23/24 日期化报告 |
| DW/PW 数据流 | four-bank/vector4、window reuse、partial-K、persistent producer | 2026-08-26 至 2026-08-31 DS/PW 报告 |
| CSA full-top | 10/10 logits exact，1,003,577 cycles，完整 route | `fulltop_csa_baseline_20260828.md` |
| unified64/shared64 | 共享计算阵列、六个 DS layer、metadata/fence/output skid、response-delay 压力 | shared64 系列报告与最终 run |

v5 式“低周期但物理不可行”的教训并非到 D4 才出现：C0 的长期演进已经显示，局部并行度、共享 mux、配置 fanout、bank 控制和 full-top routing 之间必须联合权衡。

## 3. 最终冻结 control

权威物理目录：`build/reports/vivado_cnn_top_group_shared64_full_impl/runs/20260909Tsideband`。

| 项目 | C0 frozen control |
| --- | ---: |
| semantic MAC / ops | 5,136,896 / 10,273,792 |
| no-backpressure | 219,970 cycles |
| random backpressure + response delay 2 | 268,503 cycles |
| response delay 64 | 1,902,452 cycles |
| 8 ns no-BP latency | 1.75976 ms |
| post-route WNS / TNS | -0.880 ns / -482.059 ns |
| post-route WHS / THS | +0.070 ns / 0 ns |
| route | 73,327 / 73,327 routable nets fully routed，0 routing errors |
| LUT | 32,295 / 60.70% |
| FF | 45,704 / 42.95% |
| BRAM tile | 64.5 / 46.07% |
| DSP | 151 / 68.64% |
| vectorless on-chip power | 0.479 W |
| no-BP energy | 0.8429 mJ/inference（同一 8 ns/power 投影口径） |
| no-BP energy efficiency | 约 12.19 GOPS/W |

功能证据为 10/10 logits exact。资源均低于 70%，DSP 为 151，满足额外的 `<=153`；但 setup timing 未闭合，12.19 GOPS/W 低于 20 GOPS/W。因此 C0 是完整 control，不是达标实现。

## 4. 证据边界

- “10/10 logits exact”证明指定硬件 run 与对应部署向量一致，不等于 official test10k accuracy。
- C0 软件质量实验与最终硬件 run 只有在 manifest/hash 同源时才能组成完整部署结论。
- Vivado power 是 vectorless estimated on-chip power，不是板级实测。
- C0 的网络、ABI、5,136,896 MAC 和 full-top PPA 不得改名为 D4。
- D4 进入主线后，C0 只用于接口、存储、测试方法和完整系统对照。

## 5. 冻结结论

C0 的主要研究价值是建立了完整系统和严谨验证方法，并通过多代数据流实验揭示了周期、资源、时序和能效的耦合。它没有达到最终 timing/energy 目标，但为 D4 提供了可信 control；后续不得在 C0 上继续扩展网络优化，也不得用 C0 full-top 填补 D4 尚未完成的 full-network/full-top 证据。
