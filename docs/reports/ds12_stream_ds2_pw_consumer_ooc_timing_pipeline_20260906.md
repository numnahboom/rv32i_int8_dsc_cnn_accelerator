# DS2 PW consumer timing-pipeline OOC（2026-09-06）

结论：**NEGATIVE_RESULT**。本 bounded slice 的 RTL、随机握手功能和完整
XC7Z020 隔离 OOC 流程均完成；候选相对用户 baseline 明显改善了 setup，
但 post-route WNS 仍为 `-0.880 ns`，因此没有达到 125 MHz setup closure。
这份结果是 `ds12_stream_ds2_pw_consumer` 的 module-level/OOC 证据，不是
full-top、full-network、功耗、能效、板级或硬件闭合证据。

## 变更边界

- RTL：`rtl/cnn/ds12_stream_ds2_pw_consumer.v`
  - DW 输入使用 one-entry ingress/commit pipeline；提交旧条目的同时捕获
    新条目，外部 DW 接口保持连续 II=1。
  - 最后一个 DW 只有在 BRAM commit fence 后才将 slot 置为
    `SLOT_READY`，避免计算看到尚未写入的最后一片 activation。
  - 64 个 MAC lane 使用显式 DSP48E1 的内部 `P` feedback 和 `PREG=1`，
    A/B 输入寄存器保持在 DSP 内；K=31 之后用 `last_pending` →
    `result_pending` 两个受控边沿完成最终 drain，再写 result BRAM。
- TB：`sim/tb_ds12_stream_ds2_pw_consumer.v`
  - 增加 DW accept/commit 一致性、BRAM weight map、同步 weight prefetch、
    K 序列、DSP 输出宽度、final drain 和 sink backpressure 检查。
- OOC：
  - Tcl：`scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_timing_pipeline_20260906.tcl`
  - source manifest：`scripts/ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f`
  - 输出：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_timing_pipeline_20260906/`
- 中间尝试过的 PCIN cascade 版本因 DSP cascade route 不可布线而停止；本报告
  只引用最终采用内部 P feedback、完整 route 的版本。

## 功能与节奏验证

直接 real packed DS2 随机 DW valid 和 sink backpressure 通过：

```text
DS12_DS2_PW_PASS byteexact=1 weight_map=512/512 weight_prefetch=65536/65536
cfg_reads=704 weight_reads=512 dw_vectors=512 dw_commits=512
pw_tokens=8192 mac=524288 output_words=4096 partial_context_peak=15
span=8987 active_cycles=8192 compute_segments=32 last_pending=32 result_pending=32
dsp_width_errors=0 k_seq_errors=0 dw_input_gaps=16 dw_ready_stalls=0 sink_stalls=625
```

这覆盖 512 个 DW vector、512 个 commit、8192 个 PW token、524288 个 MAC
和 4096 个输出 word；32 个 compute segment 的 `compute_step=0..255`
连续，无 K 序列错误。sink 停顿期间 payload 保持稳定，weight map 和 8 路
同步预取逐项检查通过。

pure two-layer real packed 回归也通过，两个变体均为 `mismatches=0`、
`errors=0`：

```text
no backpressure : start_to_done=23075 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576
random backpressure : start_to_done=33109 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576
```

复现命令：

```text
bash scripts/run_ds12_stream_ds2_pw_consumer_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_random_bp.sh
```

## 与用户 baseline 的 post-route 对比

baseline 取同一 module 的用户提供结果：WNS `-4.176 ns`、WHS `+0.124 ns`、
`11,530 LUT / 8,556 FF / 16 RAMB36 / 8 RAMB18 / 80 DSP`，TNS
`-27,571.949 ns`、14,204 个 setup failing endpoints。候选和 baseline 都是
Vivado 2025.2、`xc7z020clg400-1`、8 ns OOC 边界。

| 指标 | 用户 baseline | timing-pipeline 候选 | 变化 |
| --- | ---: | ---: | ---: |
| WNS | -4.176 ns | -0.880 ns | +3.296 ns |
| TNS | -27,571.949 ns | -803.573 ns | +26,768.376 ns |
| setup failing endpoints | 14,204 | 1,927 | -12,277 |
| WHS | +0.124 ns | +0.095 ns | -0.029 ns |
| THS | 0 ns | 0 ns | unchanged |
| Slice LUTs | 11,530 | 9,212 | -2,318 |
| Slice registers | 8,556 | 6,933 | -1,623 |
| RAMB36/FIFO | 16 | 16 | unchanged |
| RAMB18 | 8 | 8 | unchanged |
| DSP48E1 | 80 | 80 | unchanged |

因此这是 setup 方向的实质改善，但不是 closure：8 ns clock 对应 125 MHz，
最终 WNS 仍为负。候选没有采集 power，也没有足够证据计算 GOPS/W。

## 最终 XC7Z020 8 ns OOC

Vivado 2025.2，part `xc7z020clg400-1`，top
`ds12_stream_ds2_pw_consumer`，clock `8.000 ns`，流程为 out-of-context
synth / place / phys_opt / route，`general.maxThreads=8`。

| 项目 | post-route 结果 |
| --- | ---: |
| routable nets | 19,523 / 19,523 fully routed |
| routing errors | 0 |
| WNS / TNS | -0.880 ns / -803.573 ns |
| setup failing endpoints | 1,927 / 39,271 |
| WHS / THS | +0.095 ns / 0 ns |
| Slice LUTs / registers | 9,212 / 6,933 |
| RAMB36 / RAMB18 | 16 / 8 |
| DSP48E1 | 80 |

DSP audit 为 `DSP48E1_COUNT=80`、`PREG_ONE_COUNT=64`。拥塞报告没有找到
level 5 以上的 congestion window；post-route DRC 有 148 个 warning/advisory
检查，但无 DRC error。

## 负结果诊断与后续边界

post-route 最差路径为：

```text
slot_epoch_reg[2][30]/C -> slot_seen_reg[10][12]/D
slack=-0.880 ns, data path=8.825 ns
logic=2.240 ns (25.381%), route=6.585 ns (74.619%), logic levels=9
```

同一 `slot_epoch` 到 slot ledger 的控制锥占据 top paths；报告中的高扇出
网络还包括 `cfg_bank_r_i_1_n_0`（6106）、result-bank 写控制（2733）和
`compute_step` 复制网络（最高 1372）。这说明当前残余瓶颈是 route-dominated
的 ledger/control fanout，而不是 activation BRAM 或 64-lane DSP P feedback
本身。进一步闭合可能需要增加 tag/ledger control stage 或重构 fanout，
这会改变 ready/latency 行为，留待父级架构决策；本 slice 不擅自引入该协议
变化。

权威产物：

- `build/ds12_stream_harness/run_timing_pipeline_20260906.log`
- `build/ds12_stream_pure_two_layer_top/run_timing_pipeline_20260906.log`
- `build/ds12_stream_pure_two_layer_top_random_bp/run_timing_pipeline_20260906.log`
- `timing_summary_post_route.txt`
- `utilization_post_route.txt`
- `route_status_post_route.txt`
- `dsp_preg_audit_synth.txt`
- `reg_to_reg_maxpaths.txt`
- `high_fanout_post_route.txt`
- `congestion_post_route.txt`
- `drc_post_route.txt`
- `ds12_stream_ds2_pw_consumer_ooc_8ns_timing_pipeline_post_synth.dcp`
- `ds12_stream_ds2_pw_consumer_ooc_8ns_timing_pipeline_post_route.dcp`
