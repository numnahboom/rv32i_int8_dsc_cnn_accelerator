# EdgeDSCNet-C10 D4 v6 closeout — 2026-09-10

## 当前判决

D4 继续作为开发主线，C0 保持冻结 control。v6 已把 `mb16_down` 的 standalone
功能、no-backpressure 周期和 synth 资源同时推进到通过，但 8 ns setup timing
失败；没有 D4 full-network RTL、完整推理实测周期、full-top post-route、功耗或
能效签署，因此不能替换生产 `cnn_top`。

## 已接受证据

- 软件/网络冻结：204,090 参数、11,645,440 MAC、23,290,880 ops、official
  CIFAR-10 test10k INT8 91.46%。权威文件与 SHA256 见
  `docs/reports/edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json`。
- v6 `mb16_down`：8,192 output bytes、2,048 aligned 32-bit sink fires；PW/DW/RQ
  ledger `786432/73728/12288`，DW request/response `4418/4418`，errors=0。
- 当前功能周期：no-BP `24,030`；random-BP `25,374`；final-word stall
  `25,406`；two-epoch + done backpressure `25,374/25,375`，全部 exact。
- pool 事务守恒、fetch-pair、banked activation、16-lane raw FIFO 和 DW request
  adapter 的独立 contract TB 均通过。
- 当前 source manifest 的 synth 资源：31,832 LUT（59.83%）、24,635 FF
  （23.15%）、144 DSP（65.45%）、56 RAMB18 / 28 BRAM tile（20.00%）。
  block 资源门通过，且 input/scratch/weight/raw FIFO 均有真实 XPM RAMB 映射。

当前功能日志：

- `build/v6_nobp_latest.log`
- `build/v6_random_bp_latest.log`
- `build/v6_finalstall_latest.log`
- `build/v6_two_epoch_latest.log`

当前 synth 证据：
`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727`。
其 `source_manifest.txt` 锁定 13 个 RTL 源、XDC、Vivado 2025.2、
`xc7z020clg400-1`、8.000 ns 和 `general.maxThreads=8`。

## 未接受/负结果

- 当前 v6 synth setup 为 WNS `-4.533 ns`、TNS `-5,767.454 ns`、4,805 个
  failing endpoints；hold 为 `+0.210 ns/0`。这是 synth estimate，不是
  post-route timing。
- 没有执行 place/route，故没有 route complete、unrouted nets、post-route
  WNS/TNS/WHS/THS、congestion 或 power 证据。
- 最新 DW request adapter 把原始 top path 从 scratch0 BRAM enable 移到
  adapter `next_addr_q_reg/R`，逻辑从 16 增到 17 levels，synth WNS 从前一
  `...092800_independent` 快照的 `-3.748 ns` 恶化为 `-4.533 ns`，同时 no-BP
  从 23,535 增到 24,030。它的协议/功能 contract 可保留，但当前集成不能称为
  timing repair。
- v5 校准的完整网络乐观 projection 约 311,690 cycles，仍是 derived/assumed，
  不是 v6 fullnet 实测；对应 20 GOPS/W 的功耗上限约 0.467 W。当前没有 D4
  full-top power，不能宣称能效通过。
- C0 control 保持 219,970 no-BP cycles、10,273,792 ops、full-top WNS
  `-0.880 ns`、DSP 151、power 0.479 W；它仍未过 timing/20 GOPS/W，
  且不能重标为 D4 证据。

## 继续入口

1. 以当前 v6 报告
   `docs/reports/edgembconv_hwacandidate_d4_vstream_v6_mb16_optimization_experiment_20260910.md`
   和两个 synth manifests（`...092800_independent`、`...104727`）做 A/B，避免
   在失败 adapter 上继续堆寄存器。
2. 下一高信息增益方向是改 DW 请求的**生成端**：用窄的 row/column/tap
   递增 cursor 或预计算 descriptor，在深 bounds/address arithmetic 之前建立
   registered lookahead；保持 request II=1，而不是在已形成的组合请求之后再包
   一层 adapter。
3. 每个候选先重跑 v6 四模式、pool/ledger 和 `≤25,000` 门，再做 fresh
   synth。只有 synth 路径结构合理且资源保持通过，才运行完整 OOC route/power。
4. OOC 8 ns closure 后才进入 D4 shape sweep（mb32/mb16/mb8/mb4、stride 1/2、
   channel groups），随后才做完整 D4 top、三模式 logits exact 和 full-top P&R。

本次收尾未提交、reset、checkout 或 clean；工作树中 C0、D4 与历史实验的既有
dirty paths 全部保留，相关 Vivado/XSim/Verilator 进程已停止。
