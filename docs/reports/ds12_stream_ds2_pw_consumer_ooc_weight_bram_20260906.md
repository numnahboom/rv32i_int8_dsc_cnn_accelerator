# DS2 PW consumer synchronous weight-BRAM prefetch (2026-09-06)

结论：**DONE（本 bounded slice 已完成；功能和固定节奏通过；真实
XC7Z020 8 ns 隔离 OOC 综合/放置/phys_opt/布线完成）**。这是
`ds12_stream_ds2_pw_consumer` 的 module-level 证据，不是 full-top、
full-network、功耗、能效或硬件闭合结果；post-route setup 仍为负。

## 变更边界

- RTL：`rtl/cnn/ds12_stream_ds2_pw_consumer.v`
- OOC TCL：`scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl`
- OOC source manifest：`scripts/ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f`
- OOC 输出：
  `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_weight_bram_20260906/`
- 只把原 64×32 signed weight 语义改为 8 个独立 `64 x 32` 同步
  weight RAM。packed config 的每个 32-bit word 仍按原顺序写入：
  原 Cout 是 `cfg_index[8:3]`，其中 `cfg_index[5:3]` 选 lane，
  `{cfg_index[8:6],cfg_index[2:0]}` 选 `{Cout-tile,K-byte-group}` 深度。
- compute claim 先读 tile 0/K-group 0；每个 active edge 预取下一
  `{Cout-tile,K-group}` word，下一拍用 `compute_k[1:0]` 选择 word 内的
  INT8 byte。K=31 边沿预取下一 Cout tile，因此 256-token segment
  保持连续，不降低 II 或 64 MAC/token。
- activation BRAM、result LUTRAM、64-lane local accumulation、valid/ready、
  tag/epoch、last/output ABI、DS1 及无关文件未改。

## 功能验证

直接 real packed DS2 随机 cfg response/DW valid/sink backpressure：

```text
DS12_DS2_PW_PASS byteexact=1 weight_map=512/512 weight_prefetch=65536/65536 cfg_reads=704 weight_reads=512 dw_vectors=512
pw_tokens=8192 mac=524288 output_words=4096 partial_context_peak=15
span=8910 active_cycles=8192 compute_segments=32 k_sequence_errors=0
dw_input_gaps=16 dw_ready_stalls=0 sink_stalls=631
```

TB 还检查了 sink 停顿时全 payload 稳定，以及每个 compute segment 的
`compute_step=0..255` 连续性；实测 32 段、8192 active cycles、无 K 序列
错误。额外的 512/512 weight-map 检查逐字比对了 packed bank 的原始
32-bit word 与 `{Cout-tile,K-group}`/Cout-lane BRAM 地址；在 8192 个
compute token 上逐拍检查了 8 个同步预取 word（65,536/65,536）。

pure two-layer real packed no-backpressure：

```text
PURE_TWO_LAYER_REAL_PASS start_to_done=23010 cfg=1180 out1=8192 out2=4096
dw=221184 pw=1048576 mismatches=0 errors=0
```

pure two-layer real packed random-backpressure：

```text
PURE_TWO_LAYER_REAL_PASS start_to_done=33054 cfg=1180 out1=8192 out2=4096
dw=221184 pw=1048576 mismatches=0 errors=0
```

复现：

```text
bash scripts/run_ds12_stream_ds2_pw_consumer_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_random_bp.sh
```

## XC7Z020 8 ns isolated OOC

Vivado 2025.2，part `xc7z020clg400-1`，top
`ds12_stream_ds2_pw_consumer`，`clk=8.000 ns`，
out-of-context synth/place/phys_opt/route，`general.maxThreads=8`。
最终 route status 为 24,002/24,002 routable nets fully routed，0 routing
errors。

| 指标 | post-synth | post-route |
| --- | ---: | ---: |
| Slice LUTs | 10,771 | 11,530 |
| LUT as logic | 8,035 | 8,798 |
| LUT as distributed RAM | 2,736 | 2,732 |
| Slice registers | 6,715 | 8,556 |
| RAMB36/FIFO | 16 | 16 |
| RAMB18 | 8 | 8 |
| DSP48E1 | 80 | 80 |
| WNS | synthesis estimate not used | -4.176 ns |
| TNS | synthesis estimate not used | -27,571.949 ns |
| WHS | synthesis estimate not used | +0.124 ns |
| THS | synthesis estimate not used | 0 ns |

Post-route timing 有 14,204 个 setup failing endpoints；hold 无失败。
OOC clock 没有 `HD.CLK_SRC`，因此该 timing 结果只代表此隔离边界，不能
外推为系统级 closure。

## Weight mapping / warning 状态

Vivado final mapping report 明确列出
`gen_weight_lane_bank[0..7].weight_mem_reg`，每项均为 `64 x 32`，每项
使用 1 个 RAMB18（共 8 个 RAMB18）。activation 仍为 8 个 `64 x 128`
双口 RAM，每项 2 个 RAMB36（共 16 个 RAMB36）。

旧的 16,384-bit `weight_reg` register-structure warning
`Synth 8-11357` 在本次最终 log 中为 **0 次**；替代的是每个 weight BRAM
的 `Synth 8-7052` informational timing message（没有可合并的可选 BRAM
输出寄存器），以及 OOC setup 未满足时的 route critical warning。没有
multi-driven weight-prefetch warning。post-route DRC 没有 error，只有
OOC/input-pipeline 等 warning。

权威文件：

- `vivado.log`
- `utilization_synth.rpt`
- `utilization_post_route.txt`
- `timing_summary_post_route.txt`
- `route_status_post_route.txt`
- `drc_post_route.txt`
- `ds12_stream_ds2_pw_consumer_ooc_8ns_post_synth.dcp`
- `ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp`
