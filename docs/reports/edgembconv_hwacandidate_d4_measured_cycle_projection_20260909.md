# D4 measured-service full-network projection (v5 calibration) — 2026-09-10

## 结论与边界

v5 `mb16_down` 已实测 no-BP **23,843 cycles**，random-BP 24,466，final-word
stall 24,498；均 exact、semantic ledger 正确，故通过该 block 的 25,000-cycle
门。但 v5 只验证一个 `16x16x32, stride=2` block，不是 full-network measurement。

按 v5 状态 occupancy 对 operator service 做分项校准，并用 D4 graph 的真实
shape/MAC 数量分别外推，得到乐观 construction **311,690 cycles**（derived/assumed，
不是实测）。风险包络暂保留 **312k–736,648 cycles**；后者沿用旧 serial model
仅作风险上界。当前值得进入 D4 shape sweep，不足以宣称 full-top integration 或
GOPS/W 通过。

## 实测证据

来源：

- `docs/reports/edgembconv_hwacandidate_d4_vstream_v5_mb16_optimization_experiment_20260910.md`
- `build/d4_v5_stage4b_nobp_release_20260910.log`
- `build/d4_v5_stage4b_bp_20260910.log`
- `build/d4_v5_stage4b_finalstall_20260910.log`

v5 no-BP ledger：`pw_mac=786432`、`dw_mac=73728`、`rq=12288`、
`dw_cfg=288`、`dw_start=8`、`dw_req=dw_resp=4418`、`final=8192`、
`word_sink=2048`。诊断为 `pool_busy=14336`、`pool_idle=9032`、
`pool_turn=630`、`mode_switch=129`、`child_overlap=10806`，状态 occupancy
`0/288/16/21/10752/255/6275/102/32/11/6027/64/0`。这些均是 v5
`mb16_down` measured；不能假设其他 stride/channel/shape 相同。

## 分项校准与 D4 graph 外推

冻结 graph：`build/edgembconv_hwacandidate_d4_cycle_model/edgembconv_hwacandidate_d4_cycle_schedule.json`。
ledger 为 11,645,440 MAC / 23,290,880 ops；D4 operator totals 为 PW expand
5,242,880 MAC、PW project 4,980,736 MAC、DW 976,896 MAC、DW command 224。

occupancy 中的 `10752/6275/6027` 分别按 expand/DW/project service 解释；总计
23,054，实测 23,843 的余数为 789 = cfg 288 + 其余 boundary/tail 501。
这 501 已包含 output state=64 cycles 及其他 boundary states，不能再加 8192-byte
drain。D4 graph 共 13 个 blocks，故将 501×13 作为保守 boundary assumption。

| item | v5 measured basis | derived rate | D4 projection |
|---|---:|---:|---:|
| expand PW | 10,752 / 524,288 MAC | 0.0205078 cyc/MAC | 107,520 |
| DW | 6,275 / 73,728 MAC | 0.0850694 cyc/MAC | 83,144 |
| project PW | 6,027 / 262,144 MAC | 0.0229767 cyc/MAC | 114,513 |
| boundary/context + v5 bank tail | 501 cycles | 13× D4 block-count assumption | 6,513 |
| **optimistic construction** |  |  | **311,690** |

公式：`C = 107520 + 83144 + 114513 + 501×13 = 311690`。
它不是总 MAC 单点比例；PW expand/project、DW 分开建模。v5 已实现 banked
32-bit word sink，output state 64 已包含在 501 中；本报告不再另加 8192-byte
drain，也不再给出 2048-cycle word-drain 情景。v3/v4 的该情景只保留在历史报告中。

可外推的只是同一 datapath service 的 PW/DW MAC 率；v5 banked word sink 的 64-cycle
output state 只能随 501 boundary 一起按 block 数作假设，不能再按 bytes 外推。
shared-pool turnaround、129 mode switches、source fill、fence、cross-layer overlap、
backpressure、weight refill、dense stem、GAP/FC、其他 stride/channel 均不可由一个
block 线性继承。v5 的 `pool_busy/idle/turn` 说明 shared pool 有显著边界成本，
`child_overlap` 不等于隐藏了全部 latency。

保守风险范围为当前 311,690 construction 至旧 `736,648` serial projection；后者依赖旧 4x8 DW service/
hidden-fill 假设，不能作为 v5 service 数字，也不能与 v5 分项相加。旧 `577,585`
selected 同样仅历史筛选参考。v3/v4 的 460,155/394,685 optimistic numbers 已由
v5 的 311,690 construction 替代，但历史报告保持可追踪。

## 能效筛选（8 ns）

`GOPS/W >= 20` 等价于 `cycles × power_W <= 145568`；
`latency_ms=cycles×8e-6`，`GOPS=2911360/cycles`。

| power | max cycles | v5 projection judgement |
|---:|---:|---|
| 0.283 W | 514,375 | 312k 下界通过；风险上界不保证 |
| 0.506 W | 287,684 | 全部 projection 不通过 |
| 1 W | 145,568 | 不通过 |
| 2 W | 72,784 | 不通过 |
| 3 W | 48,523 | 不通过 |

311,690-cycle construction：latency **2.4935 ms**、GOPS **9.341**、最大功耗
**0.4670 W**。历史风险点 577,585 / 736,648 分别为 4.6207 / 5.8932 ms、
5.041 / 3.953 GOPS、最大功耗 0.2520 / 0.1976 W。

## 下一步判决

判定：**值得进入 D4 shape sweep；不值得直接 top integration 作为通过证据**。
最高信息增益是用真实 D4 shapes 覆盖 `mb32/mb16/mb8/mb4`、stride 1/2、不同
channel groups，逐项记录 PW dedicated/pool busy、DW capture/issue、RQ outputs、
turnaround/mode switches、source fill 和 overlap。各 shape 先通过 exact
no-BP/random-BP，再决定 full D4 top；不要把 v5 的 23,843 直接升级为 fullnet cycles。

## 验证

本次仅做文档算术与 diff 校验；未运行训练、Vivado、fullnet 仿真，未修改 C0。
