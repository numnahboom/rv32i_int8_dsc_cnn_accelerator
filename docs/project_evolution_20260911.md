# EdgeDSCNet-C10 工程演进与验证报告（截至 2026-09-11）

## 1. 立项问题

项目面向 `xc7z020clg400-1`，试图把固定 INT8 EdgeDSCNet-C10 从 Python/PyTorch checkpoint、量化导出、RV32I/NPC 控制和 bare-metal firmware 一直连接到 RTL full-network inference。最终约束同时包含：正确 logits、8 ns、完整推理不超过 2,000,000 cycles、各类资源严格低于 70%、DSP 不超过 153、post-route estimated power 不超过 3 W，以及按真实 ops 计算不低于 20 GOPS/W。

项目的核心并非单独降低周期，而是让软件精度、整数语义、RTL exactness、真实周期、post-route timing/resources 和同源 power 同时成立。

## 2. 端到端 C0 基线（2026-06-08 至 2026-07-17）

最初提交建立了 CNN accelerator baseline，随后补齐 DW tile 写入与 banking、CPU bridge、多样本 CPU/RTL 推理、Vivado synthesis、可综合 RTL、line buffer、streaming DW 和 BRAM tile buffer。到 7 月，工程形成如下闭环：

```text
Python checkpoint
  -> INT8 export / firmware headers / vectors
  -> RV32I custom instruction or MMIO
  -> descriptor-driven cnn_top / cnn_layer_runner
  -> Stem / DW / PW / GAP / FC
  -> logits / argmax comparison
```

C0 因而不仅是一个精度较低的网络，也是此后全部 memory protocol、feature SRAM、CPU interface、fullnet 和 full-top 验证的基础设施来源。

## 3. C0 流式 BRAM 与 timing-driven 优化（2026-07-17 至 2026-08-25）

工程移除 runner 中大型 packed payload，改为 memory-oriented loader、XPM/BRAM buffer 和同步预取。8 月 23 日后围绕 Stem/FC requant、tiled input/store address、SRAM span、DW row reduction、descriptor-local requant、地址 cursor 和 bias pipeline 反复进行 functional + P&R 验证。

PW requant pipeline、FC bias preadd/fold、Stem prefetch、tiled store pipeline/word cursor 等负结果被明确保留。它们建立了项目后续的质量门：局部 RTL 逻辑看似更短，不代表 post-route WNS/TNS、拥塞和资源会更好；功能 exact 也不能替代物理实现。

## 4. C0 数据流和 shared compute 演进（2026-08-26 至 2026-09-09）

C0 先后发展出 four-bank/vector4 DW storage、window/tile reuse、ping-pong、partial-K、tagless stream4、scratch pipeline、persistent DS producer、unified64/shared64 arithmetic 和本地 requant。完整 `cnn_top` 始终维持 descriptor、feature SRAM ping-pong、可延迟 read response、write backpressure 和十 logits 接口。

2026-08-28 CSA full-top 达到 10/10 logits exact、1,003,577 cycles，post-route WNS `-0.799 ns`，资源可放入但约 5.47 GOPS/W。shared unified64/persistent DS 将 fullnet 周期降至约 713k/695k，但当时只有 synth/OOC 证据且 setup 失败。

shared64 后续补齐六个 DS layer、真实 producer、runner adapter、metadata commit、epoch fence、output skid、random backpressure 和 response-delay 64。最终 frozen C0 control 达到 no-BP 219,970 cycles、BP+resp2 268,503、resp64 1,902,452；完整 route 的 WNS/TNS 为 `-0.880/-482.059 ns`，DSP 151，power 0.479 W，约 12.19 GOPS/W。它是完整系统 control，但没有闭合 8 ns 或 20 GOPS/W。

C0 软件也经历了独立质量路线：初始 INT8 47.31%，重新训练 66.16%，BN-fold PTQ 79.23%，30-epoch QAT 77.61% 且低于 PTQ。不同软件 checkpoint 不应自动绑定到任意硬件 run；详见 `reports/c0_frozen_control_closeout_20260911.md`。

## 5. 高精度网络候选与 D4 晋级（2026-09-02 至 2026-09-09）

软件侧比较 ResNet20 和 EdgeMBConv A/B/C/D4/D8。D4 获得 FP32 91.63%、deployment INT8 91.46%，量化损失 0.17 percentage point；冻结账本为 204,090 参数、11,645,440 semantic MAC、23,290,880 ops。

D4 不是 C0 的参数替换：它具有不同拓扑、shape、权重、量化 manifest 和 ABI。`sw/model/model_quant.h` 仍属于 C0，不能作为 D4 deployment header；C0 的 accuracy、MAC、cycles 和 PPA 不能重标为 D4。

## 6. D4 composite 与 vstream v1--v3

D4 先建立 block shell、DW16 tile、dense128 PW tile、DSP/RQ pool 和 composite controller，再转向独立 vstream。其主要挑战是在 DSP 预算内复用 PW/RQ，同时维持 output word alignment、pool transaction conservation、同步 BRAM 读取和任意 backpressure 下 exactly-once。

v3 达到 43,688/44,965 cycles 并 exact，形成后续优化基线。2026-09-09 promotion contract 固化 D4 网络身份、整数语义和 G0--G4 门禁。

## 7. D4 v4--v6

| 版本 | 进展 | 结论 |
| --- | --- | --- |
| v4 | 36,401/37,927 cycles，exact | 调度与流水重叠改善 |
| v5 | no-BP 23,843 cycles | 约 264,810 LUT，物理不可行，否决 |
| v6 | banked activation/weights、fetch pair、BRAM raw FIFO、DW cursor/lookahead、PW operand stage | 资源恢复可行，setup 仍失败 |

v6 candidate1--6 继续优化 RQ/DW 控制锥。candidate5/6 没有同时改善 mandatory WNS/TNS gate，最终恢复 candidate4。retained candidate4 六项功能回归全部 PASS：no-BP 24,039 cycles、random BP 25,389、final stall 25,421、two-epoch 25,389/25,389；8,192 bytes、2,048 words 以及 PW/DW/RQ、request/response ledger 全部守恒。

candidate4 fresh OOC fully routed：LUT 18,000、FF 25,133、DSP 145、BRAM 28、power 0.406 W；WNS/TNS `-1.028/-1461.586 ns`，WHS/THS `+0.071/0`。它证明 standalone 功能、周期和局部资源可行性，但没有闭合 8 ns，且 OOC 不是 full-top。

## 8. 当前发布状态

已经证明：D4 official test10k INT8 91.46%、固定整数语义和运算账本；candidate4 standalone exact、真实局部周期、source manifest 和 OOC 资源门。

尚未证明：D4 完整十类 logits、full inference cycles/latency、shape sweep、XC7Z020 full-top timing/power、mJ/inference 和 GOPS/W。

项目因此以一个可复现、功能精确、资源可实现、失败边界明确的 v6 检查点收尾，而不是以“完整 FPGA 部署达标”收尾。C0 保留为完整系统 control，D4 保留为唯一网络主线。

## 9. 技术资料索引

- 当前总状态：`README.md`
- 报告索引：`docs/reports/README.md`
- C0 收尾：`docs/reports/c0_frozen_control_closeout_20260911.md`
- D4 软件契约：`docs/reports/edgembconv_hwacandidate_d4_promotion_contract_20260909.md`
- D4 最终收尾：`docs/reports/edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`
