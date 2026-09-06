# DS2 PW consumer banked-result OOC screen (2026-09-05)

结论：**NEGATIVE RESULT（功能通过；OOC 综合通过，但 XC7Z020 放置在
utilization precondition 失败）**。

本候选只改动 `rtl/cnn/ds12_stream_ds2_pw_consumer.v` 的结果存储和 64 个
MAC 的 DSP 属性，并将 OOC 输出目录改为本报告对应的候选目录。没有改动
DS1、activation/config store、pure top 或外部接口。

## 方案与功能证据

- 每个 compute/drain lifecycle bank 由 64 个独立的 `8 x 32` 分布式 RAM
  组成；lane `p*8+c` 保存 8-pixel tile 的 pixel `p` 和 Cout lane `c`，
  深度地址为 Cout tile `0..7`。两个 lifecycle bank 合计 128 个物理
  shallow memories，保留 `FREE -> COMPUTE -> READY -> DRAIN -> FREE`。
- K=31 时 64 个 lane memories 在同一个时钟边沿各写入一个
  `mac_next`；sink 侧按 tile 地址异步读取连续 4 个 channel。
- 64 个乘法表达式使用最小 `(* use_dsp = "yes" *)` 属性；未串行化或
  删除 MAC，也未改变 K 调度。

直接 DS2 packed 随机 valid/sink-stall TB：

```text
DS12_DS2_PW_PASS byteexact=1 cfg_reads=704 weight_reads=512 dw_vectors=512
pw_tokens=8192 mac=524288 output_words=4096 partial_context_peak=15
span=8910 active_cycles=8192 compute_segments=32 k_seq_errors=0
dw_input_gaps=16 dw_ready_stalls=0 sink_stalls=631
```

pure two-layer（无 BP）和 random-BP 均通过，均 `mismatches=0 errors=0`：

```text
PURE_TWO_LAYER_REAL_PASS start_to_done=23010 cfg=1180 out1=8192 out2=4096
  dw=221184 pw=1048576 mismatches=0 errors=0
PURE_TWO_LAYER_REAL_PASS start_to_done=33054 cfg=1180 out1=8192 out2=4096
  dw=221184 pw=1048576 mismatches=0 errors=0
```

对应命令：

```text
bash scripts/run_ds12_stream_ds2_pw_consumer_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_random_bp.sh
```

## XC7Z020 8 ns OOC

工具为 Vivado 2025.2，part `xc7z020clg400-1`，top
`ds12_stream_ds2_pw_consumer`，时钟 8.000 ns，综合/放置/phys_opt/route
脚本为 `scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl`。
综合生成了正式 post-synth DCP；放置未完成，因此没有 post-route DCP、
post-route utilization 或 post-route timing。

| 指标 | 原 result_psum 综合 | banked 候选综合 | 证据边界 |
| --- | ---: | ---: | --- |
| Slice LUTs | 58,087 (109.19%) | 47,672 (89.61%) | post-synth |
| LUT as Logic | 58,087 | 44,924 | post-synth |
| LUT as Distributed RAM | 0 | 2,748 | post-synth |
| Slice FF | 123,606 (116.17%) | 89,041 (83.69%) | post-synth |
| BRAM36/FIFO | 0 | 0 | post-synth |
| DSP48E1 | 16 | 80 | post-synth |
| WNS | -5.550 ns | -3.543 ns | synthesis estimate only |
| TNS | -207,956.375 ns | -97,908.789 ns | synthesis estimate only |
| WHS | +0.256 ns | +0.256 ns | synthesis estimate only |
| THS | 0 ns | 0 ns | synthesis estimate only |

Vivado 的 distributed-RAM final mapping 明确列出
`gen_result_lifecycle_bank[0/1].gen_result_lane_bank[0..63].result_mem_reg`
为 `8 x 32`、`User Attribute`、`RAM32M`。原来的 `result_psum_reg` warning
消失；仍有 `weight_reg` 16,384 registers 和 `activation_reg` 65,536
registers 的 RAM-structure warning。

放置失败点为：

```text
WARNING: [Place 30-770] High register utilization ... up to 8 registers per slice
ERROR: [Place 30-4] Design utilization is very high
ERROR: [Place 30-99] Placer failed: Placer initialization failed: Design utilization is very high
place_design failed
```

因此上述 WNS/TNS/WHS 是 post-synthesis estimate，不是 routed timing；本
结果不是 full-top、full-network、功耗、能效、硬件或最终 timing closure。

权威产物目录：
`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_banked_20260905/`

- `vivado.log`
- `run_settings.txt`
- `source_manifest.txt`
- `utilization_synth.rpt`
- `timing_summary_synth_estimate.rpt`
- `ds12_stream_ds2_pw_consumer_ooc_8ns_post_synth.dcp`

复现：

```powershell
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source (Resolve-Path 'scripts\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.tcl') `
  -log (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_banked_20260905')\vivado.log `
  -journal (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_banked_20260905')\vivado.jou
```
