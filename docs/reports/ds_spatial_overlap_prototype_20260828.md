# DS DW/PW tile-overlap prototype (2026-08-28)

## 结论

这是一个可综合、功能正确的 A/B 原型，但不是可保留的优化候选。
它验证了独立 DW/PW 控制器、DW channel-tile commit/fence 和 PW partial-K
累加的接口形状；它仍然是 channel-tile-major，并未实现最终目标要求的
spatial-block-major 双 bank 数据流。PW 对每个 channel tile 重放一次完整
8x4 阵列，因此多数工作负载的重复计算开销超过了 DW/PW 重叠收益。

## 实现边界

新增 `rtl/cnn/ds_block_tile_engine_overlap.v`，不替换生产
`ds_block_tile_engine_new`，也没有修改 runner、Stem 或 FC。DW 控制器在每
个 16-channel tile 的 `dw_done` 后发布递增 commit count；PW 控制器只能
消费 `commit_count > pw_tile_idx` 的 tile。DW 写入下一 channel tile 时，PW
读取已提交 tile 的不同 channel 地址。每个 PW pixel/output-channel group
的中间 2048-bit partial sum 保存在 64 个 32-bit XPM BRAM 中，最终 tile
按 64 个 lane 独立相加后才进入既有 requant。

这保证了 Cin=1/7/17/127 的 tail、stride、padding、输出顺序和精度，但
commit token 仍代表 channel tile，不是完整 spatial block；因此不能把本
原型的重叠宣传成空间块交错完成。

## 功能与周期证据

通过 Verilator 编译、lint/elaboration 和直接 DS 回归：

```text
PASS tb_ds_block_tile_engine_new cases=7 checks=2191
```

用 `DS_ENGINE_MODULE=ds_block_tile_engine_overlap` 运行的 7 个 case 覆盖
stride 1/2、Cin=1/7/17/127、空间及输出 channel tail；所有 logits 与参考
完全一致。周期（candidate / 原保留 baseline）为：

| case | candidate cycles | baseline cycles | candidate pw issues |
|---:|---:|---:|---:|
| 0 | 2124 | 2108 | 64 |
| 1 | 848 | 840 | 64 |
| 2 | 1252 | 1188 | 256 |
| 3 | 459 | 457 | 2 |
| 4 | 405 | 401 | 14 |
| 5 | 910 | 1049 | 68 |
| 6 | 14160 | 13851 | 4064 |

只有小的双 tile case 5 获得净收益；最大、PW 密集的 case 6 反而增加
309 cycles。故“有 DW/PW 同时活动”并不等于端到端吞吐提升。

## 8 ns OOC 实现门槛

脚本：`scripts/vivado_ds_block_tile_engine_overlap_ooc_20260828.tcl`。
Vivado 2025.2、XC7Z020、8.000 ns、RuntimeOptimized，route 完成且
81,825 nets 中 52,178 routable nets 全部 routed、0 routing errors。

| 指标 | post-route |
|---|---:|
| WNS / TNS | -1.257 ns / -1164.395 ns |
| WHS / THS | +0.077 ns / 0 ns |
| setup failing endpoints | 3038 / 78361 |
| LUT / FF | 22767 (42.80%) / 31257 (29.38%) |
| BRAM | 60 / 140 (42.86%) |
| DSP | 32 / 220 (14.55%) |
| total on-chip power | 0.299 W |

最差路径为 `u_pw_requant_vector4/fifo_cout_reg[1][30][1]/C` 到
`fifo_rd_ptr_reg[1][0]/CE`，data delay 8.968 ns，其中 logic 1.902 ns、
route 7.066 ns；源 clock net fanout 为 32832。路径经过
`rq_cout_vec`、`out_wr_en`、lane-ready/fifo control，属于宽输出/ready
控制集的路由问题，而不是单个算术乘法器深度。

综合初始尝试使用单个 256x2048 reg-array，曾触发 Vivado
`EXCEPTION_ACCESS_VIOLATION` 并出现 524288-register RAM warning。改为
64 个 256x32 XPM BRAM 后可以完成 synth 和 route；这修复了工具质量问题，
但没有修复控制路径或重复 PW replay 的架构问题。

## 诊断与下一步边界

本候选的 negative result 不是由功能错误、X/latch、未驱动信号或 BRAM
同地址冲突造成：仿真 exact、Verilator 无 error、OOC route clean，且仿真
断言在 DW 写与 PW 读 channel 地址重合时会报错（实际未触发）。根因分为：

1. **架构层**：现有 group-major DW 顺序和 PW 的 `k_last` replay ABI 不
   能直接形成 spatial commit；本原型用 partial store 绕过 ABI，却把完整
   PW replay 重复了每个 channel tile。
2. **实现层**：2048-bit partial vector 的寄存器/加法/ready 选择暴露出
   高扇出和宽控制路由；post-route worst path 在 requant FIFO ready cone，
   不是 DW MAC。即使资源低于单项 70%，8 ns WNS 仍为负，不能进入 full-top。

要继续向目标推进，应先确定真正的 spatial-major producer（或为 PW 提供
不重复 replay 的 partial-K accumulate/resume 状态接口），并在该契约下
重新做双 bank ownership/fence；不能把本候选直接接入 production runner。
