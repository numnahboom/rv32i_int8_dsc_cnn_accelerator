# 当前限制与后续验证（2026-10-19）

2026-10-20 主线已按用户授权迁移至 SMIC 180 nm ASIC。下文保留 FPGA P
冻结阶段的结果与限制；ASIC 当前状态见
[开发报告](reports/d4_asic_development_20261020.md)，功耗边界见
[活动与能耗合同](asic_power_contract.md)。FPGA 资源百分比、125 MHz 和功耗证据
不直接转作 ASIC 验收。当前 ASIC 优先完成同源映射的逻辑/门级/完整物理验证，
然后进行同条件 A2/A3 存储结构比较与实际活动功耗分析。

## 当前结论

C0 和 D4 retained v6 继续作为冻结对照。K2完整布线资源通过、0 routing errors，WNS -0.990ns、WHS +0.005ns，125MHz setup失败。L精确RQ部分积流水与完成握手分离已通过84次逐层exact及完整控制/reset门，latency258,813、启动间隔258,815 cycles，尚无PPA结论。L2数据级valid使能已通过同范围完整功能验证，延迟不变；完整综合18,739 LUT/9,653 FF/93 BRAM/64 DSP，WNS -1.051ns，最差已转为外部start_valid到state CE。M寄存启动token已通过完整功能门，外部latency258,814/interval258,816，综合WNS -0.467ns；M post-route WNS -0.287ns、WHS +0.006ns，setup失败。N halo已通过同周期完整功能门；O输入ready门控候选已通过完整功能门及新增ready/reset探针，同源综合资源通过，WNS -1.017ns、内部+.632ns，仅1个setup失败端点，O post-route WNS -0.221ns/WHS +0.049ns，setup仍失败；P静态FC队列/本地CE功能及综合拓扑已通过，综合setup+.106ns/hold-.155ns，完整P&R同步时序已通过（WNS+.128/WHS+.010），复位后数字内存不变量已通过，物理复位warning保留；sample0活动估算0.613W/18.35GOPS/W（Medium），初始20目标未过。E的旧布线失败结果不属于K2/L。详细证据见 [`reports/d4_fullnet_development_20261018.md`](reports/d4_fullnet_development_20261018.md)。

| 项目 | 当前权威结果 | 状态 |
| --- | --- | --- |
| C0 fullnet | 10/10 logits exact；no-BP 219,970 cycles；resp2 268,503；resp64 1,902,452 | 完整 control |
| C0 full-top | WNS/TNS -0.880/-482.059 ns；WHS/THS +0.070/0；151 DSP；0.479 W | fully routed，setup/20 GOPS/W 未通过 |
| D4 software | 204,090 参数；11,645,440 MAC；23,290,880 ops；INT8 91.46% | 已冻结 |
| D4 candidate4 standalone | no-BP 24,039；random BP 25,389；final stall 25,421；two-epoch 25,389/25,389 | exact，全部 ledger 守恒 |
| D4 candidate4 OOC | WNS/TNS -1.028/-1461.586 ns；WHS/THS +0.071/0；18,000 LUT、25,133 FF、145 DSP、28 BRAM、0.406 W | 资源通过，8 ns setup 未通过 |
| K2 D4 完整网络 RTL | 41算子、24,336中间字、10个FC accumulator exact；258,749 cycles | K2 84次回归、2次完整控制探针、3次连续推理及在途reset通过 |
| K2 D4 综合 | 20,377 LUT、11,173 FF、93 BRAM、64 DSP；WNS -0.504ns | 保留synth-only阶段；完整P&R见下一行 |
| K2 D4 full-top P&R | 20,214 LUT、11,155 FF、93 BRAM、64 DSP；WNS -0.990ns、WHS +0.005ns | fully routed、0 route errors；资源/hold通过、125MHz setup失败 |
| L D4 完整功能 | 84 exact、1,000,256乘法检查、控制/连续/reset门；258,813 cycles/间隔258,815 | 147项源/向量hash已冻结；尚无综合/PPA |
| L2 D4 完整功能/综合 | 84 exact及完整协议/reset；258,813 cycles/间隔258,815；18,739 LUT、9,653 FF、93 BRAM、64 DSP；WNS -1.051ns | 资源通过；synth-only负setup，M完整功能门已通过 |
| M D4 完整功能/综合 | 84 exact及新增token/reset门；外部258,814 cycles/间隔258,816；18,741 LUT、9,654 FF、93 BRAM、64 DSP；WNS -0.467ns | 综合负setup，已选定一次完整P&R |
| M D4 full-top P&R | 18,197 LUT、9,620 FF、93 BRAM、64 DSP；WNS -0.287ns、WHS +0.006ns；0 route errors | setup仍失败：halo3、logit_ready输入14、busy输出1；vectorless0.378W Low |
| N D4 完整功能 | 实际RTL33,120几何/1,621halo/FC；84 exact和全部probes，外部258,814/间隔258,816 | 已接受；O合并候选完整功能已接受，未对N单独综合/布线 |
| O D4 完整功能/综合 | 84 exact、所有原probes及新增ready/reset门；258,814/间隔258,816；18,831 LUT、9,898 FF、93 BRAM、64 DSP；WNS -1.017ns/内部+.632ns | 功能接受；综合仅1个setup失败端点，完整P&R负setup见下一行；无活动功耗结论 |
| O D4 full-top P&R | 18,279 LUT、9,863 FF、93 BRAM、64 DSP；WNS -.221/TNS -2.352ns；WHS +.049/THS0；0route errors | 负setup22端点：ready输入18、本地merge_valid合并后控制网4；vectorless.384W Low，非能效结论 |
| P D4 候选 | 静态索引FC队列替换ready驱动移位；保留每lane merge_valid FF | 84exact+所有probes同O周期；综合18,327 LUT/8,900 FF/93 BRAM/64 DSP、setup+.106ns/hold-.155ns；16本地valid FF各64lane本地product CE；完整物理结果见下一行 |
| P D4 full-top P&R | WNS+.128/TNS0；WHS+.010/THS0；17,239 LUT（32.40%）/8,864 FF（8.33%）/93 BRAM（66.43%）/64 DSP（29.09%）；25,587网全部路由、0errors | 同步125MHz资源/路由通过；REQP-1839保留；复位后数字overwrite-before-read通过；vectorless.383W Low不签能效 |
| P D4 sample0活动功耗 | Total0.613W、dynamic0.494W、static0.120W；Medium/IO High；完整2.070696ms窗口1.269337mJ/18.34886GOPS/W | ≤3W通过、初始≥20GOPS/W未过；partial SAIF和单样本估算，不签板级或数据集均值 |
| I2 D4 综合 | 16,121 LUT、5,641 FF、91 BRAM、64 DSP；WNS -1.616ns | 保留synth-only负结果；未运行布线 |
| E D4 full-top P&R | 21,124 LUT、4,134 FF、91 BRAM、64 DSP；WNS -5.590、WHS +0.033ns | 布线完成、资源通过、125MHz setup失败 |
| E D4 power | vectorless 0.559W；native7部分SAIF活动0.546W、Medium confidence（I/O High） | setup失败、内部活动覆盖有限；不能签署运行能效或转用于K2/L |

## 证据边界

- C0 与 D4 是不同网络、账本和部署 ABI。C0 的 `model_quant.h`、accuracy、MAC、cycles 或 PPA 不能重标为 D4。
- D4 candidate4 的 24,039 cycles 是 mb16 standalone，不是完整十类推理。
- OOC route/power 只属于隔离 wrapper；不能计算 D4 full inference energy 或 GOPS/W。
- P为单sample0、部分SAIF标注的post-route估算（Medium/IO High）；历史vectorless仅作筛选。两者均未做板级功耗测量。
- 历史报告的数字只属于其日期、source manifest、器件、约束和 run。

## 接口与存储限制

- C0 外部读协议最多一个 outstanding；响应最早在 accepted request 的下一拍到达。
- 外部写无响应；`valid && !ready` 时 write/address/data 必须稳定。
- C0 仿真外存仍大量使用一 INT8 element 对应一个 32-bit word 的布局；packed NHWC/burst adapter 尚未成为生产路径。
- 新 D4 top 为 resident-weight ROM + 32-bit 物理图像流接口（内部 128-bit），尚无 CPU firmware 接入或外存 response adapter；流输入停顿测试不能重标为 response-2/64。
- 新 top 的完整网络测试覆盖冻结图内所有 shapes；retained v6 自身的 shape sweep 仍未建立，不能把新 top 的结果回填到 v6。
- FC 提供 raw INT32 accumulator 和冻结逐通道 scale ABI，必须按尺度重建 logits，不能按 raw accumulator 排名。
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
- 在 125 MHz 下，`start_interval_cycles × total_power_W <=145,568`，即按 23,290,880 ops 计算 `>=20 GOPS/W`；其他已闭合频率使用实际频率重新计算。

完整 D4 cycles 已有流接口证据；实际工作频率 latency、mJ/inference 和 GOPS/W 仍缺少同源 post-route timing/power，必须标为“未验证”。

## 后续验证路线

当前开发继续从新 top 的功能快照出发：

1. `python/export_d4_fullnet_vectors.py` 和 `scripts/run_d4_fullnet_verilator.sh` 复现完整网络及逐层对比。
2. 核对新候选的物理报告、真实波形活动率功耗，保留失败候选和源码快照。
3. 依照实际 critical paths、资源映射和逐层周期选择下一改动；继续保留原目标口径与 accuracy/energy/latency 的取舍。

以下为 retained v6 的原始恢复路线，保留供局部对照：

1. 以 `docs/reports/edgembconv_hwacandidate_d4_v6_retained_source_manifest_20260911.txt` 核对 candidate4。
2. 先重跑 DW adapter/tile、no-BP、random BP、final stall、two-epoch 和全部 ledger。
3. 再进行 D4 shape sweep。
4. 集成独立 D4 top 或与 C0 互斥的 generate 路径，验证完整 logits 和三种响应模式。
5. 最后运行 XC7Z020 8 ns full-top P&R/power，并只用同源 cycles/power 计算能效。

2026-09-11 冻结发布不包含此后的新 top 实验，其已接受状态仍详见 `reports/c0_frozen_control_closeout_20260911.md` 和 `reports/edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md`。
