# DS2 PW consumer activation-BRAM OOC (2026-09-06)

结论：**DONE（固定形态已实现；功能回归通过；真实 XC7Z020 8 ns OOC
综合/放置/phys_opt/布线完成）**。该结果是隔离的 DS2 PW consumer module
证据，不是 full-top、full-network、功耗、能效或硬件闭合结果。

## 变更边界

- RTL：`rtl/cnn/ds12_stream_ds2_pw_consumer.v`
- OOC TCL：`scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl`
- OOC 输出目录：
  `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_activation_bram_20260906/`
- 外部接口、DW handshake/tag/epoch、slot ledger、双 result bank、sink
  payload/address/last 和 64-MAC/token 口径均未改变。
- activation payload 从 32 个 context 的寄存器数组改为 8 个独立
  `64 x 128-bit` 双端口同步 RAM；写行地址为
  `{input_group[4:0], dw_group}`，每个 `dw_fire` 写完整 128-bit slice。
  compute claim 在消费前发出首个读，随后每个 active edge 预取下一 K
  行，下一拍从寄存的 128-bit 行用 `compute_k[3:0]` 选字节。Vivado
  最终映射为每 bank 2 个 RAMB36E1，即总计 **16 RAMB36E1，等价 32
  RAMB18**。

## 功能验证

直接 real packed PW 随机 DW valid 和 sink backpressure：

```text
DS12_DS2_PW_PASS byteexact=1 cfg_reads=704 weight_reads=512 dw_vectors=512
pw_tokens=8192 mac=524288 output_words=4096 partial_context_peak=15
span=8910 active_cycles=8192 compute_segments=32 k_seq_errors=0
dw_input_gaps=16 dw_ready_stalls=0 sink_stalls=631
```

pure two-layer no-BP：

```text
PURE_TWO_LAYER_REAL_PASS start_to_done=23010 cfg=1180 out1=8192 out2=4096
dw=221184 pw=1048576 mismatches=0 errors=0
```

pure two-layer random-BP：

```text
PURE_TWO_LAYER_REAL_PASS start_to_done=33054 cfg=1180 out1=8192 out2=4096
dw=221184 pw=1048576 mismatches=0 errors=0
```

复现命令：

```text
bash scripts/run_ds12_stream_ds2_pw_consumer_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_random_bp.sh
```

直接 PW TB 还检查每段 `compute_step=0..255` 连续性；实测
`compute_segments=32`、`active_cycles=8192`、`k_seq_errors=0`，因此没有
II=2 或 K 序列气泡。sink 停顿期间 payload 保持稳定。

## XC7Z020 8 ns OOC

工具 Vivado 2025.2，part `xc7z020clg400-1`，top
`ds12_stream_ds2_pw_consumer`，时钟 `clk=8.000 ns`，流程为
out-of-context synth / place / phys_opt / route，`general.maxThreads=8`。
route status 为 46,727/46,727 fully routed，0 unrouted，0 partially routed，
0 routing errors。

| 指标 | post-synth | post-route |
| --- | ---: | ---: |
| Slice LUTs | 30,910 (58.10%) | 31,463 (59.14%) |
| LUT as logic | 28,174 | 28,731 |
| LUT as distributed RAM | 2,736 | 2,732 |
| Slice registers | 23,217 (21.82%) | 25,750 (24.20%) |
| RAMB36/FIFO | 16 (11.43%) | 16 (11.43%) |
| RAMB18 | 0 | 0 |
| DSP48E1 | 80 (36.36%) | 80 (36.36%) |
| WNS | -3.241 ns | -6.303 ns |
| TNS | -15,936.221 ns | -139,799.297 ns |
| WNS failing endpoints | 6,317 | 49,403 |
| WHS | +0.256 ns | +0.075 ns |
| THS | 0 ns | 0 ns |

这是隔离 OOC top，clock port 没有 `HD.CLK_SRC`，Vivado 对 OOC clock
skew 给出相应 warning；因此 setup timing 是真实该边界报告值，但不能
外推为系统级 closure。post-route DRC 仅有 OOC/输入管线等 warning，无
DRC error。

## 资源变化与 warning

相对于 2026-09-05 banked-result baseline 的 post-synth
`47,672 LUT / 89,041 FF / 0 BRAM36 / 80 DSP`，本候选为
`30,910 LUT / 23,217 FF / 16 BRAM36 / 80 DSP`：LUT 减少 16,762，FF
减少 65,824，新增 16 个 RAMB36（等价 32 RAMB18）。

Vivado synthesis log 的 activation register warning 已消失；最终
mapping report 明确列出 8 个 `gen_activation_lane_bank[*].activation_mem_reg`
对象，每个 `64 x 128`，`PORT A W` + `PORT B R`，每个使用 2 个 RAMB36E1。
仍保留的是权重寄存器 `weight_reg` 的 16,384-register
`Synth 8-11357` warning，非 activation warning。

## 权威产物

- log：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_activation_bram_20260906/vivado.log`
- synth utilization：`.../utilization_synth.rpt`
- post-route utilization：`.../utilization_post_route.txt`
- synth timing：`.../timing_summary_synth_estimate.rpt`
- post-route timing：`.../timing_summary_post_route.txt`
- route status：`.../route_status_post_route.txt`
- post-synth DCP：`.../ds12_stream_ds2_pw_consumer_ooc_8ns_post_synth.dcp`
- post-route DCP：`.../ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp`
