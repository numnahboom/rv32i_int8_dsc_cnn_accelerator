# EdgeDSCNet-C10 D4 promotion contract

## 决策状态

D4 是后续实现主线；C0 冻结为只读 control 和协议/存储基础设施来源。D4 尚未替换生产 `cnn_top`：当前只接受了软件网络冻结证据，完整 D4 RTL、真实全网周期和 XC7Z020 full-top post-route 仍未完成。

权威软件冻结清单：
`docs/reports/edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json`。
该清单按内容哈希锁定网络图、权重、量化、test10k 与 ledger；工作树本身不是 clean release baseline。

## G0：网络、精度与运算账本

默认 D4 身份必须同时满足：

| 项目 | 冻结值 |
|---|---:|
| 参数 | 204,090 |
| semantic MAC | 11,645,440 |
| ops | 23,290,880，定义为 `2 × semantic MAC` |
| dense 3×3 MAC | 442,368 |
| PW 1×1 MAC | 10,223,616 |
| DW 3×3 MAC | 976,896 |
| CIFAR-10 official test10k INT8 top-1 | 91.46%（9,146/10,000） |
| FP32 top-1 | 91.63%（9,163/10,000） |

部署量化必须保持 signed INT8 activation/weight、per-output-channel symmetric weight、INT32 accumulator/bias、nearest-away-from-zero requant 和 signed INT8 saturation。部署 manifest 内的 source-name 归一化映射也是接口契约的一部分，不允许仅按相似层名猜测 RTL/权重对应关系。

任何改变网络图、层 shape/stride/groups、参数、权重、BN folding、量化或类别输出的修改都会使 G0 失效。失效后必须重新训练或按修改范围恢复 checkpoint，重新导出 INT8，重跑 official test10k，并重新证明软件 fake-quant 与 exported integer evaluator 的语义关系、INT32 overflow audit、参数/MAC/ops 账本和全部哈希；不能沿用 91.46%。

当前 `sw/model/model_quant.h` 是 C0 ABI，不属于 D4 冻结源。后续 D4 firmware/header 必须从冻结 deployment manifest/NPZ 明确生成并单独验收。

## G1：D4 block promotion

第一道硬件门是 `mb16_down`：

- 真实 8,192 输出字节、2,048 个 32-bit sink fire；不得以少提交、重复提交或丢弃 tail 降低周期。
- 与冻结 exported INT8 语义 byte-exact；非零向量必须覆盖 DW、PW、bias、requant 和 saturation。
- no-backpressure 与随机 backpressure 均需 exactly-once，`valid/data/tag/byte-enable` 在 stall 时稳定，错误计数为 0。
- no-backpressure 从 accepted start 到 final accepted output/done 的实测周期目标为 `≤25,000`。
- 物理组织维持最多 146 DSP 的 D4 block 预算；任何 DSP/LUT 替换必须在后续 OOC 和 full-top 中重新核算，不能只按 RTL 实例名推断资源。

每个候选必须与其 baseline 使用相同向量、testbench、计数口径和工具版本，并保存 run-scoped SHA256 manifest。静态 cycle floor、旧报告或仿真时间不算实测 start-to-done 周期。

## G2：完整 D4 RTL functional promotion

优先使用独立 D4 top，或在 `cnn_top` 中使用与 C0 互斥的 generate 路径。D4 与 C0 不得同时实例化后再用不可达分支掩盖资源，也不得把 C0 的权重、header、MAC、accuracy、cycles 或 PPA 重标为 D4。

完整 D4 网络必须证明：

- 10 类 logits 对冻结 exported integer reference exact；最终类别和所有被纳入比较的 logits 均检查，不接受仅 top-1 相同。
- no-backpressure、随机 backpressure/response-2、长响应/response-64 三模式均 exact，协议错误为 0。
- 周期只按一次完整推理的 accepted start 到 final done 统计，包含权重/激活 SRAM 交通、所有 refill、fence、tail、stall、GAP、FC 与输出提交。
- semantic ledger 仍为 11,645,440 MAC / 23,290,880 ops；同时记录物理 padded/masked issue，二者不得混用。
- 完整推理 `≤2,000,000 cycles`。该门只约束 latency，不能替代更严格的能效门。

## G3：XC7Z020 8 ns full-top physical promotion

只有完整 D4 top 在 `xc7z020clg400-1`、Vivado 2025.2、8.000 ns 约束下的同源 post-route 结果可以签署：

- route complete，unrouted nets/errors 为 0；
- WNS `≥0`、TNS `=0`、WHS `≥0`、THS `=0`，并保存 setup/hold failing endpoint 与 congestion 摘要；
- LUT、FF、DSP、BRAM 各自严格 `<70%`，DSP 额外要求 `≤153`；
- Vivado post-route estimated power `≤3 W`，同时记录 activity source、confidence 和静态/动态分项；
- 不允许用 OOC、synth-only、其他器件、放宽时钟、multicycle/false-path 掩盖逐周期数据通路，或 vectorless 低可信估计替代最终 full-top 结论。

## G4：能效与最终替换判据

8 ns 下统一使用真实 D4 ops：

- `latency_ms = cycles × 8e-6`
- `energy_mJ = power_W × latency_ms`
- `throughput_GOPS = 2,911,360 / cycles`
- `GOPS_per_W = 2,911,360 / (cycles × power_W)`
- `GOPS_per_W ≥20` 等价于 `cycles × power_W ≤145,568`

最终报告必须把 accuracy、cycles、latency、power、mJ/inference、GOPS、GOPS/W、LUT/FF/DSP/BRAM、setup/hold 与 route 状态放在同一张 D4 表中，并用相同口径列出冻结 C0 control。较大 D4 运算量不能单独用于美化 GOPS/W；只有 G0–G4 全部通过后，才可决定正式替换生产 `cnn_top`。

## 证据层级与当前结论

| 证据 | 可支持的结论 | 当前状态 |
|---|---|---|
| G0 哈希冻结 + test10k JSON | D4 软件网络身份、91.46% INT8、真实 ledger | 已建立；本轮未重跑训练/test10k |
| block exact + true cycles | 单个 D4 block 功能与局部服务率 | v6 8,192-byte exact；24,030/25,374/25,406 cycles，no-BP `≤25,000` 已通过；two-epoch 25,374/25,375 亦 exact |
| full-network RTL 三模式 | 完整 D4 功能与真实周期 | 未建立 |
| D4 OOC post-route | 局部物理可行性 | v6 fresh synth 资源通过：31,832 LUT、24,635 FF、144 DSP、28 BRAM tile；setup WNS/TNS `-4.533/-5,767.454 ns`，未 route，时序门失败 |
| D4 full-top post-route | 8 ns、资源、功耗、能效签署 | 未建立 |

旧 cycle model 的 577,585 cycles、局部 146-DSP composite OOC 和 C0 full-top 都只能用于筛选或对照，不能升级为 D4 promotion 证据。
