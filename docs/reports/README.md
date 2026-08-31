# Experiment report index

本目录的报告按“实验快照”保存，不把不同日期、不同 RTL 快照的数字混成一
个当前结果。报告中的 `OOC`（out-of-context）只代表隔离模块或包装器的
综合/布局布线证据；它不能替代 `cnn_top` 完整顶层 post-route，也不能单独
证明端到端周期、板级功耗或能效。

## 当前权威证据

| 目的 | 报告 | 结论 |
| --- | --- | --- |
| 完整顶层基线 | [`fulltop_csa_baseline_20260828.md`](fulltop_csa_baseline_20260828.md) | CSA Stem 基线；XSim 精确，完整顶层已布线但 setup 未闭合 |
| 当前完整网络最佳功能/周期候选 | [`shared_persistent_ds_fullnet_ooc_20260831.md`](shared_persistent_ds_fullnet_ooc_20260831.md) | 5,136,896 MAC、精确 logits、695,553 cycles；OOC timing 仍失败，未晋级 full-top |
| 共享阵列完整网络对照 | [`shared_unified64_fullnet_integration_20260831.md`](shared_unified64_fullnet_integration_20260831.md) | 精确 logits、713,086 cycles；只有综合资源证据 |
| 当前最佳隔离 DS 数据面 | [`ds_group_published_shared64_sync_read_equivalence_20260901.md`](ds_group_published_shared64_sync_read_equivalence_20260901.md) | 同步 BRAM 读语义等价；87,553 cycles；8 ns OOC WNS +0.032 ns |
| PW requant 局部验证 | [`requant_activation_stream2_slots_20260830.md`](requant_activation_stream2_slots_20260830.md) | 2,048 个 8x8 bundle 随机压力 PASS；8 ns OOC WNS +0.607 ns |

“当前最佳”必须同时查看功能、真实 cycle、时序、资源和功耗。隔离 OOC 的
正 slack 不得写成完整网络闭合。

## 复现入口

```text
scripts/run_cnn_xsim.ps1
scripts/run_cnn_fullnet_shared_persistent_ds_verilator.sh
scripts/run_cnn_fullnet_shared_unified64_verilator.sh
scripts/run_ds_group_published_shared64_sweep_sim.sh
scripts/run_requant_activation_stream2_slots_sim.sh
scripts/run_cnn_impl.ps1
```

完整顶层权威实现目录为：
`build/reports/vivado_cnn_top_impl/runs/20260828T_stem_csa_fulltop_max2/`。
Vivado 入口默认使用 `general.maxThreads=8`；复现实验应记录工具版本、器件、
时钟周期、线程数和具体 run 目录。

## 历史报告保留策略

- 保留有独立脚本、独立 RTL 快照、数值/协议结论或负结果诊断的报告；负结果
  对后续架构选择仍有价值。
- 已被 2026-09-01 同步读等价报告完整替代的 shared64 sweep 初版和 rerun5
  摘要已删除；脚本和最终报告仍保留。
- 早期单模块 Vivado synthesis 快照若只重复 summary 的资源表，删除；真正的
  OOC/post-route 专题报告继续保留。
- 历史日期报告中的周期、资源和 timing 只属于报告标题所示快照，不代表当前
  工作树。新增结果应更新本索引和 README，而不是悄悄改写旧报告。
