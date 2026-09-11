# Experiment report index

本目录按实验日期和 source snapshot 保存报告，不把 C0、D4、standalone、OOC、synth-only 和 full-top 数字混成一个“当前最好结果”。当前总状态日期为 2026-09-11。

## 当前权威证据

| 范围 | 报告 | 当前结论 |
| --- | --- | --- |
| 工程演进与验证报告 | [`../project_evolution_20260911.md`](../project_evolution_20260911.md) | 从 2026-06 初始 C0 闭环到 D4 v6 收尾 |
| C0 frozen control | [`c0_frozen_control_closeout_20260911.md`](c0_frozen_control_closeout_20260911.md) | 完整 logits/full-top control；资源门通过，8 ns setup 与 20 GOPS/W 未通过 |
| D4 软件身份 | [`edgembconv_hwacandidate_d4_promotion_contract_20260909.md`](edgembconv_hwacandidate_d4_promotion_contract_20260909.md) | 204,090 参数、11,645,440 MAC、23,290,880 ops、INT8 91.46% |
| D4 最终 retained 状态 | [`edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`](edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md) | candidate4 standalone exact、24,039 cycles、OOC 资源通过；8 ns setup/fullnet/full-top 未完成 |
| D4 软件源冻结 | [`edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json`](edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json) | 网络、训练、量化、test10k 与 ledger 哈希清单 |
| D4 v6 RTL retained 清单 | [`edgembconv_hwacandidate_d4_v6_retained_source_manifest_20260911.txt`](edgembconv_hwacandidate_d4_v6_retained_source_manifest_20260911.txt) | candidate4 source gate，14-source manifest PASS |

## C0 发展主线

### 软件质量

| 阶段 | 报告 | INT8 official test10k |
| --- | --- | ---: |
| 初始 control | [`c10_hwqa_v1_baseline.md`](c10_hwqa_v1_baseline.md) | 47.31% |
| C0 重新训练 | [`c10_hwqa_c0_full_training_report_fixed.md`](c10_hwqa_c0_full_training_report_fixed.md) | 66.16% |
| BN-fold PTQ | [`c10_hwqa_c0_bnfold_report_20260902.md`](c10_hwqa_c0_bnfold_report_20260902.md) | 79.23% |
| BN-fold QAT | [`c10_hwqa_c0_bnfold_qat_report_20260902.md`](c10_hwqa_c0_bnfold_qat_report_20260902.md) | 77.61%，负结果 |

这些软件 checkpoint 不应自动绑定到任意硬件 run；只有 source manifest/hash 同源时，才能把 accuracy 与 PPA 合并报告。

### 硬件与数据流

| 里程碑 | 报告 | 结论 |
| --- | --- | --- |
| CSA full-top | [`fulltop_csa_baseline_20260828.md`](fulltop_csa_baseline_20260828.md) | 1,003,577 cycles，10/10 logits exact，WNS -0.799 ns |
| shared unified64 fullnet | [`shared_unified64_fullnet_integration_20260831.md`](shared_unified64_fullnet_integration_20260831.md) | 713,086 cycles、exact；仅 synth 资源证据 |
| shared + persistent DS | [`shared_persistent_ds_fullnet_ooc_20260831.md`](shared_persistent_ds_fullnet_ooc_20260831.md) | 695,553 cycles、exact；OOC setup 失败，未晋级 |
| group-published shared64 | [`ds_group_published_shared64_sync_read_equivalence_20260901.md`](ds_group_published_shared64_sync_read_equivalence_20260901.md) | 同步 BRAM 读等价，隔离 DS OOC WNS +0.032 ns |
| shared64 metadata commit | [`ds_group_published_shared64_metadata_commit_20260908.md`](ds_group_published_shared64_metadata_commit_20260908.md) | fullnet/backpressure/resp64 exact，OOC/full-top setup 仍失败 |
| frozen control | [`c0_frozen_control_closeout_20260911.md`](c0_frozen_control_closeout_20260911.md) | no-BP 219,970 cycles，full-top WNS -0.880 ns，151 DSP，0.479 W |

2026-08-23 至 2026-09-07 的 Stem、FC、requant、DW/PW、banking、window、partial-K、DS1/DS12 和 M1.1-A 专题报告均作为历史实验保留。文件名中的日期定义其证据时点。

## D4 发展主线

| 阶段 | 报告 | 结论 |
| --- | --- | --- |
| A/B/C/D4/D8 候选选择 | `edgembconv_hwacandidate_*_hwqa_report_20260902.md` | D4 通过 accuracy/quantization 质量门 |
| 初始 block/composite | `edgembconv_hwacandidate_d4_*_20260902.md` | 建立 DW16、PW、RQ/pool 和 mb16 controller |
| v3 | [`edgembconv_hwacandidate_d4_vstream_v3_mb16_optimization_experiment_20260909.md`](edgembconv_hwacandidate_d4_vstream_v3_mb16_optimization_experiment_20260909.md) | exact，43,688/44,965 cycles |
| v4 | [`edgembconv_hwacandidate_d4_vstream_v4_mb16_optimization_experiment_20260910.md`](edgembconv_hwacandidate_d4_vstream_v4_mb16_optimization_experiment_20260910.md) | exact，36,401/37,927 cycles |
| v5 | [`edgembconv_hwacandidate_d4_vstream_v5_mb16_optimization_experiment_20260910.md`](edgembconv_hwacandidate_d4_vstream_v5_mb16_optimization_experiment_20260910.md) | 23,843 cycles，但约 264,810 LUT，物理不可行 |
| v6 数据流 | [`edgembconv_hwacandidate_d4_vstream_v6_mb16_optimization_experiment_20260910.md`](edgembconv_hwacandidate_d4_vstream_v6_mb16_optimization_experiment_20260910.md) | banked storage/fetch/FIFO/DW/PW 流水与事务门禁 |
| v6 PW operand stage | [`edgembconv_hwacandidate_d4_vstream_v6_pw_operand_stage_20260910.md`](edgembconv_hwacandidate_d4_vstream_v6_pw_operand_stage_20260910.md) | 资源可放入；post-route setup 未闭合 |
| candidate1--6 收尾 | [`edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`](edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md) | candidate4 retained；candidate5/6 mandatory timing gate 失败 |

## 证据边界

- official test10k evaluator 只证明对应软件/导出模型的 accuracy。
- standalone regression 只证明指定 shape、接口和 ledger，不证明完整网络。
- OOC synth/post-route 只证明隔离 wrapper，不证明 `cnn_top` 或 D4 full-top。
- fullnet simulation 可以证明对应 vectors 的 logits/cycles，但不能证明 XC7Z020 timing/power。
- full-top post-route 仍不等于 bitstream、板级 I/O 或实测功耗。
- Vivado vectorless power 必须标注 activity/confidence，不能伪装成板级实测。
- C0 与 D4 的软件和硬件指标必须分别列示。

## 当前复现入口

### C0 control

```text
scripts/run_cnn_top_fullnet_group_shared64_verilator.sh
scripts/run_cnn_top_fullnet_group_shared64_backpressure_verilator.sh
scripts/run_cnn_top_fullnet_group_shared64_resp64_20260909.sh
scripts/run_cnn_top_group_shared64_full_impl.ps1
```

### D4 retained candidate4

```text
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter_sim.sh
scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_sim.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_sim.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_finalstall.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_two_epoch.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_ooc_20260910.ps1
```

当前发布版本冻结为阶段性研究检查点；这些入口用于结果复核和后续同源迭代。

## 历史报告保留策略

- 保留具有独立脚本、source snapshot、数值/协议结论或负结果诊断的报告。
- 日期化报告保持原始结论，不用后来结果覆盖历史。
- `README.md`、本索引、`known_limits_next_steps.md` 和两个 2026-09-11 收尾报告描述当前状态。
- 体积大的原始 reports、DCP、WDB 和日志留在 ignored `build/`；Git 只保存人工维护的摘要、源码、测试和清单。
