# 综合验证报告

项目：`rv32i_int8_dsc_cnn_accelerator`

更新日期：2026-07-17

目标：确认 memory-oriented 重构后的完整 RTL 是否具备合理的 FPGA 资源量级，
并记录仍需通过实现阶段确认的问题。

## 1. 验证结论

`cnn_top` 在 Vivado 2021.2、`xck26-sfvc784-2LV-c` 上完成 out-of-context
synthesis：

- 0 errors；
- 0 critical warnings；
- 45830 CLB LUT（39.13%）；
- 18387 CLB registers（7.85%）；
- 42 RAMB36（29.17%）；
- 60 DSP（4.81%）。

因此，本轮重构已经把顶层从中间版本的 446272 LUT（381%）降到器件容量以内。
功能侧 Windows XSim 关键回归同时为 13/13 PASS。

## 2. 验证环境与命令

- Vivado：2021.2
- 路径：`D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Part：`xck26-sfvc784-2LV-c`
- 综合模式：OOC、保留 hierarchy、`RuntimeOptimized`

```powershell
cd D:\Stuff\Project
& D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -mode batch `
  -source scripts\vivado_cnn_top_synth.tcl `
  -tclargs cnn_top xck26-sfvc784-2LV-c
```

功能回归：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1
```

## 3. 完整顶层资源

以下数字来自 `report_utilization`：

| Metric | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 45830 | 117120 | 39.13% |
| LUT as logic | 41946 | 117120 | 35.81% |
| LUT as memory | 3884 | 57600 | 6.74% |
| CLB registers | 18387 | 234240 | 7.85% |
| RAMB36 | 42 | 144 | 29.17% |
| DSP | 60 | 1248 | 4.81% |

资源没有单项接近上限，说明当前并行度与存储规模已具备继续做 implementation 的
基础。LUT 仍是最主要资源，BRAM 次之，DSP 余量很大。

## 4. 层级分析

| Instance | LUT | Logic LUT | LUTRAM | FF | RAMB36 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `cnn_top` | 45830 | 41946 | 3884 | 18387 | 42 | 60 |
| `u_layer_runner` total | 44503 | 40619 | 3884 | 17158 | 26 | 60 |
| runner self | 14812 | 14812 | 0 | 1011 | 0 | 26 |
| `u_ds_block_engine` | 24283 | 23303 | 980 | 15630 | 26 | 14 |
| `u_stem_engine` | 1000 | 836 | 164 | 127 | 0 | 10 |
| `u_gap_unit` | 115 | 19 | 96 | 2 | 0 | 0 |
| `u_fc_unit` | 826 | 742 | 84 | 377 | 0 | 10 |
| `u_out_buffer` | 3398 | 838 | 2560 | 0 | 0 | 0 |
| `u_feature_sram` | 67 | 67 | 0 | 23 | 16 | 0 |

主要判断：

1. `cnn_layer_runner` 自身 logic 从中间版本的 333191 LUT 降到 14812 LUT，
   证明 packed payload 与动态 part-select 写网络已经被移除。
2. Feature SRAM 正确映射为 16 个 RAMB36，而不是旧版本的 LUTRAM。
3. New DSBlock 使用 26 个 RAMB36：input 16、PW weight 8、DW tile 2。
4. 剩余最明确的 memory 优化点是 `cnn_out_buffer`：16 KB 异步读使其占用
   3398 LUT；改同步 BRAM 预计需要约 4 RAMB36，并必须增加 read-prefetch 状态。
5. runner self 的 26 DSP 主要来自地址/维度乘法与综合后的宽运算；DSP 总利用率
   只有 4.81%，暂不构成容量问题。

## 5. 新旧 DSBlock 对比

| Design | CLB LUT | FF | RAMB36 | DSP |
| --- | ---: | ---: | ---: | ---: |
| Legacy `ds_block_tile_engine` | 389253 | 565654 | 0 | 20 |
| New `ds_block_tile_engine_new` | 24281 | 15649 | 26 | 14 |

New DSBlock 把输入、PW weight 和 DW tile 明确放入 BRAM，并保留 16-lane DW、
8x8 PW 计算结构。三个 golden case 共 1792 checks 全部通过。

已记录的 DSBlock 周期：

| Case | Total | DW | PW | PW issue |
| --- | ---: | ---: | ---: | ---: |
| 0 | 2937 | 2240 | 697 | 64 |
| 1 | 1113 | 700 | 413 | 64 |
| 2 | 2985 | 296 | 2689 | 256 |

PW issue 满足 `ceil(pixels/8) * ceil(Cout/8) * Cin`，说明 8x8 阵列在真正
发射 MAC 的阶段没有额外空拍；total 还包括 BRAM 读、DW、requant 和切换开销。

## 6. Timing 证据边界

当前 K26 part 在 timing API 阶段报告：

```text
ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device
```

所以本报告不能给出：

- WNS/TNS；
- Fmax；
- place-and-route 拥塞；
- routed utilization；
- 功耗或板级时序。

应在 timing-capable device support 和真实 XDC 下执行
`opt_design -> place_design -> route_design -> report_timing_summary`。

## 7. 下一步

1. 在 timing-capable 环境跑 implementation，先获取关键路径和拥塞证据。
2. 将 `cnn_out_buffer` 改成同步 BRAM + 显式预取状态，并重跑 13 项回归。
3. 根据逐层 cycle profile 决定 Stem 是否从 1 MAC 扩为 3/9 MAC。
4. 根据 routed timing 比较 DW/PW int8 乘法的 LUT 与 DSP 映射。
5. 将外部 word-per-int8 布局改为 packed NHWC byte 和 burst loader。
6. 增加随机 memory stall、非法 cfg、tile 边界和 backpressure 压力测试。

## 8. 相关产物

- `docs/synthesis_vivado_initial.md`
- `docs/synthesis_vivado_summary.md`
- `docs/synthesis_vivado_ds_block_tile_engine_new.md`
- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `scripts/vivado_cnn_top_synth.tcl`
- `scripts/run_cnn_xsim.ps1`
