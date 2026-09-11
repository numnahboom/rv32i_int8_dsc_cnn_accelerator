# 当前限制与恢复条件（2026-09-11）

## 当前结论

项目已停止继续优化。C0 冻结为完整系统 control；D4 是唯一网络主线，但当前只完成软件冻结和 retained v6 candidate4 standalone/OOC，尚未完成 D4 full-network/full-top。

| 项目 | 当前权威结果 | 状态 |
| --- | --- | --- |
| C0 fullnet | 10/10 logits exact；no-BP 219,970 cycles；resp2 268,503；resp64 1,902,452 | 完整 control |
| C0 full-top | WNS/TNS -0.880/-482.059 ns；WHS/THS +0.070/0；151 DSP；0.479 W | fully routed，setup/20 GOPS/W 未通过 |
| D4 software | 204,090 参数；11,645,440 MAC；23,290,880 ops；INT8 91.46% | 已冻结 |
| D4 candidate4 standalone | no-BP 24,039；random BP 25,389；final stall 25,421；two-epoch 25,389/25,389 | exact，全部 ledger 守恒 |
| D4 candidate4 OOC | WNS/TNS -1.028/-1461.586 ns；WHS/THS +0.071/0；18,000 LUT、25,133 FF、145 DSP、28 BRAM、0.406 W | 资源通过，8 ns setup 未通过 |
| D4 full-network/full-top | 无同源完整 logits/cycles/P&R/power | 未建立 |

## 证据边界

- C0 与 D4 是不同网络、账本和部署 ABI。C0 的 `model_quant.h`、accuracy、MAC、cycles 或 PPA 不能重标为 D4。
- D4 candidate4 的 24,039 cycles 是 mb16 standalone，不是完整十类推理。
- OOC route/power 只属于隔离 wrapper；不能计算 D4 full inference energy 或 GOPS/W。
- Vivado power 是 vectorless on-chip estimate，不是板级测量。
- 历史报告的数字只属于其日期、source manifest、器件、约束和 run。

## 接口与存储限制

- C0 外部读协议最多一个 outstanding；响应最早在 accepted request 的下一拍到达。
- 外部写无响应；`valid && !ready` 时 write/address/data 必须稳定。
- C0 仿真外存仍大量使用一 INT8 element 对应一个 32-bit word 的布局；packed NHWC/burst adapter 尚未成为生产路径。
- D4 当前没有独立 full-network top、firmware header 或与 C0 互斥且通过 P&R 的 generate 路径。
- D4 shape sweep 尚未覆盖 mb32/mb16/mb8/mb4、stride 1/2 和全部 channel groups。
- 板级 I/O/clock、bitstream、CDC/formal、活动率驱动 power 和实测功耗均未建立。

## 最终目标缺口

最终 D4 报告要求同一 source snapshot 同时具备：

- official test10k INT8 accuracy；
- exact full-network logits；
- no-BP、random BP/resp2 和 resp64 的完整推理周期；
- 8 ns full-top WNS/WHS `>=0`、TNS/THS `=0`；
- LUT/FF/DSP/BRAM 各严格低于 70%，DSP `<=153`；
- post-route estimated power `<=3 W`；
- 完整推理 `<=2,000,000 cycles`；
- `cycles × power_W <=145,568`，即按 23,290,880 ops 计算 `>=20 GOPS/W`。

当前缺少 D4 full-network/full-top 同源证据，因此 full inference latency、mJ/inference 和 GOPS/W 必须标为“未验证”。

## 如果未来恢复

只有用户重新授权后才继续。恢复入口是：

1. 以 `docs/reports/edgembconv_hwacandidate_d4_v6_retained_source_manifest_20260911.txt` 核对 candidate4。
2. 先重跑 DW adapter/tile、no-BP、random BP、final stall、two-epoch 和全部 ledger。
3. 再进行 D4 shape sweep。
4. 集成独立 D4 top 或与 C0 互斥的 generate 路径，验证完整 logits 和三种响应模式。
5. 最后运行 XC7Z020 8 ns full-top P&R/power，并只用同源 cycles/power 计算能效。

这是一条恢复条件，不是当前待执行计划。当前接受状态详见 `reports/c0_frozen_control_closeout_20260911.md` 和 `reports/edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`。
