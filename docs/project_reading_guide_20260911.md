# 项目分阶段阅读与 AI 导读指南（2026-09-11）

## 阅读原则

不要从 v6 scheduler 或最新 commit 直接开始。按照“为什么立项 -> 软件真值 -> C0 完整系统 -> C0 物理优化 -> D4 候选选择 -> D4 vstream -> 当前证据边界”的顺序阅读。每个阶段只回答五个问题：当时的阻塞、提出的方案、修改的接口、验证证据、接受或否决原因。

## 第一阶段：项目和 C0 完整闭环

阅读 `README.md`、`docs/architecture_diagrams.md`、`docs/quantization.md`、`docs/verification_plan.md` 和最早的 Git 提交。目标是画出 Python、firmware、RV32I、`cnn_top`、`cnn_layer_runner`、feature SRAM、Stem、DW、PW、GAP、FC 和 logits 的连接。

## 第二阶段：C0 软件和量化

依次阅读：

1. `docs/reports/c10_hwqa_v1_baseline.md`
2. `docs/reports/c10_hwqa_c0_full_training_report_fixed.md`
3. `docs/reports/c10_hwqa_c0_bnfold_report_20260902.md`
4. `docs/reports/c10_hwqa_c0_bnfold_qat_report_20260902.md`
5. `docs/reports/c0_frozen_control_closeout_20260911.md`

理解 official test10k、FP32 与 exported INT8、BN folding、requant 和 source manifest。不要把十个硬件 logits 与 10,000 张图片的 accuracy 混为一谈。

## 第三阶段：C0 timing 和地址流水

沿 2026-08-23/24 的 Git 提交与日期化报告学习 Stem、FC、requant、tiled load/store、SRAM span 和 address cursor。重点阅读所有 `rejected` 报告，理解为什么功能正确的候选仍会因 WNS/TNS、fanout、placement 或资源被否决。

## 第四阶段：C0 DW/PW/shared64

按照以下数据流阅读 2026-08-26 至 2026-09-09 的报告和 RTL：

```text
feature SRAM banking
  -> DW window/tile reuse
  -> PW partial-K/output-stationary
  -> local/shared requant
  -> persistent DS producer
  -> unified64/shared64
  -> layer runner/fullnet/full-top
```

用 `fulltop_csa_baseline_20260828.md`、`shared_unified64_fullnet_integration_20260831.md`、`ds_group_published_shared64_metadata_commit_20260908.md` 和 C0 收尾报告建立里程碑表。

## 第五阶段：D4 软件晋级

阅读 EdgeMBConv A/B/C/D4/D8 HWQA 报告、static ablation、D4 HWQA 和 promotion contract。理解 D4 为什么在 accuracy、参数和 MAC 之间被选中，以及改变网络后为何必须重新训练、导出、test10k 和 integer-semantics audit。

## 第六阶段：D4 primitive、composite 与 vstream

先读 block shell、DW16、dense128 PW、DSP pool 和 composite 报告，再读 vstream v1/v2/v3。理解 output token/word、pool transaction、PW/DW/RQ ledger 和 valid/ready。

## 第七阶段：D4 v4--v6 与收尾

按 v4、v5、v6 报告顺序阅读，再看 retained v6：controller、scheduler、v2 datapath、banked storage、fetch pair、DW adapter/tile、RQ/pool 和 raw FIFO。最后阅读 `edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`，区分 standalone、OOC、fullnet 和 full-top。

## 可复制给 AI 的提示词

> 你是 EdgeDSCNet-C10 XC7Z020 FPGA 项目的技术导师。请按照“立项目标、C0 软件与完整系统、C0 timing/DW/PW/shared64 演进、D4 软件候选、D4 vstream v1--v6、当前停止点”的顺序，用中文逐课带我学习。每次只讲一个阶段：先解释问题和术语，再画最小数据流，指定要打开的文档/commit/RTL/testbench，给出功能、周期、时序、资源和功耗证据，说明候选为什么接受或否决，并以五个理解检查题结束。没有同源证据时不要组合软件 accuracy 与硬件 PPA；不得把 C0 改名为 D4，不得把 standalone/OOC 改写为 fullnet/full-top。等我说“继续”后再进入下一课。

## 推荐起点

先阅读 `docs/project_evolution_20260911.md`，再开始第一阶段。Git commit 提供变更事实，日期化报告提供实验结论，会话记录只应用于补充当时的决策理由。
