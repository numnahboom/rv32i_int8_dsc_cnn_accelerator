# Streaming Engine 与 Memory-Oriented 重构指南

## 1. 这条分支解决什么问题

分支：`refactor/streaming-dsblock-bram`

旧实现为了方便仿真，把 input tile、weight 和量化参数作为超宽 packed
vector 放在 `cnn_layer_runner` 和各算子端口之间。功能正确，但动态
part-select 会综合成大规模寄存器写选择器和多路器：

- 旧 `ds_block_tile_engine` OOC：389253 CLB LUT、565654 FF、0 BRAM、20 DSP；
- 仅替换 DSBlock 后，`cnn_top` 虽能完成综合，但仍有 446272 CLB LUT；
- 其中 `cnn_layer_runner` 自身占 333191 logic LUT 和 64024 FF，说明问题已经
  从 DS 核转移到 packed payload loader。

本分支的原则是：

1. descriptor、firmware 地址和 golden vector 格式保持不变；
2. runner 只传递标量配置写事务，不保存整块 packed payload；
3. 大数据放入 BRAM/LUTRAM，小参数放入可索引数组；
4. 算力按实际复用需求配置，不用“一拍展开整层”换取虚假的低 cycle count；
5. 每次替换都必须先过原有 golden vectors，再看综合结果。

## 2. 重构后的数据流

```text
descriptor / external memory / feature SRAM
                    |
                    | scalar cfg write
                    v
        +---------------------------+
        | cnn_layer_runner          |
        | address + phase control   |
        +-------------+-------------+
                      |
        +-------------+-------------------------------+
        |             |               |               |
        v             v               v               v
  stem_new       ds_block_new      gap_new         fc_new
  1 MAC reuse    input BRAM        load-time       load-time
                 -> DW stream      accumulation    accumulation
                 -> DW BRAM
                 -> PW 8x8
                      |
                      v
               scalar output stream
                      |
                      v
               cnn_out_buffer / SRAM
```

### DSBlock 主路径

```text
scalar input loader
  -> ds_input_tile_buffer_bram       16-channel-wide read
  -> dw_tile_fusion_engine_new       16 DW lanes + streaming requant
  -> dw_tile_buffer_bram             8 pixels x one channel per read
  -> pw_systolic_array_8x8           8 pixels x 8 output channels
  -> requant_activation_unit
  -> scalar pixel/channel write
```

`ds_block_tile_engine_new` 的配置 target 与原 runner phase 对齐：

| target | 内容 | index 布局 |
| ---: | --- | --- |
| 0 | input int8 | `((y*MAX_IN_W+x)*MAX_CIN+c)` |
| 1 | DW weight int8 | `channel*9+k` |
| 2 | DW bias int32 | `channel` |
| 3 | DW multiplier int32 | `channel` |
| 4 | DW shift | `channel` |
| 5 | PW weight int8 | `cout*MAX_CIN+cin` |
| 6 | PW bias int32 | `cout` |
| 7 | PW multiplier int32 | `cout` |
| 8 | PW shift | `cout` |

外部 memory 中的 PW weight 仍是紧凑的 `cout*actual_Cin+cin`。runner 在加载时
转换为以 `MAX_CIN` 为 stride 的内部布局，所以 firmware/model exporter 无需修改。

### Stem、GAP、FC

- `conv3x3_stem_engine_new`：保存 300 B input 与 432 B weight，用一个 int8 MAC
  顺序处理 27 个 kernel 项；面积优先，约每个输出 27 个 MAC 周期。
- `gap_unit_new`：4096 个输入在加载时直接累计到 256 个 13-bit sum；不再保存
  4 KiB packed feature。
- `fc_unit_new`：保存 256 B input；2560 个 weight 在加载时直接进入 10 个
  accumulator，不再保存整块 FC weight，也不再组合展开 256 个 MAC。
- `feature_sram_bank`：综合时使用 XPM simple-dual-port BRAM；同地址读写语义由
  `read_first` BRAM 加显式 bypass 保持，仿真模型接口不变。

## 3. 功能验证结果

Windows/Vivado XSim 统一回归：

```text
PASS tb_ds_block_tile_engine_new cases=3 checks=1792
PASS tb_feature_sram_bank ops=160 checks=96
PASS tb_cnn_top_dsblock_datapath cases=2 checks=768
PASS tb_cnn_top_tiled_stem_datapath cases=1 checks=16384
PASS tb_cnn_top_tiled_dsblock_datapath cases=2 checks=2256
PASS tb_cnn_top_sram_tiled_dsblock_datapath cases=1 checks=480
PASS tb_cnn_top_ops_datapath cases=3 checks=1290
PASS tb_cnn_top_multilayer_datapath cases=2 checks=1866
PASS tb_cnn_top_sram_gap_fc_datapath cases=1 checks=10
PASS tb_cnn_top_sram_stem_dsblock_datapath cases=1 checks=576
PASS tb_cnn_top_tail_sram_datapath cases=1 checks=10
PASS tb_cnn_top_e2e_sram_datapath cases=1 checks=10
PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10
PASS cnn_xsim_regression tests=13
```

这些测试覆盖：

- 普通和 tiled DSBlock；
- stride/padding、非 16 倍数 channel；
- external memory 和 feature SRAM 输入；
- stem、GAP、FC 独立 top-level 路径；
- stem→DS、GAP→FC、多层和 full-network 链。

接入时还修复了一个旧的仿真器可移植性问题：`output_byte_for()` 通过函数隐式读取
全局 signal，XSim 会让输出数据相对地址滞后一拍。现在输出选择使用显式连续赋值，
组合依赖对仿真和综合工具都清楚可见。

## 4. DSBlock 资源与计算效率

目标器件：`xck26-sfvc784-2LV-c`，Vivado 2021.2，OOC synthesis。

| 实现 | CLB LUT | FF | BRAM36 tile | DSP |
| --- | ---: | ---: | ---: | ---: |
| 旧 `ds_block_tile_engine` | 389253 | 565654 | 0 | 20 |
| 新 `ds_block_tile_engine_new` | 24281 | 15649 | 26 | 14 |

变化：

- LUT 下降约 93.8%；
- FF 下降约 97.2%；
- 以 26 个 BRAM36 换掉 packed storage；
- DSP 从 20 降到 14；
- 新 DSBlock 可以装入 K26，旧实现单模块已经超过器件 LUT/FF 容量。

模块级 cycle counter：

| case | shape 摘要 | total | DW | PW | PW issue |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | 8x8 output, Cin=8, Cout=8 | 2937 | 2240 | 697 | 64 |
| 1 | 4x4 output, Cin=16, Cout=16 | 1113 | 700 | 413 | 64 |
| 2 | 8x8 output, Cin=32, Cout=32 | 2985 | 296 | 2689 | 256 |

`PW issue` 等于理论阵列工作拍：

```text
ceil(pixels/8) * ceil(Cout/8) * Cin
```

说明 8x8 PW 阵列在真正的 MAC issue 阶段没有额外空拍；总周期还包含 BRAM 读、
DW 流、requant 扫描和 tile/channel 切换。

## 5. 当前综合证据边界

已经确认：

- `ds_block_tile_engine_new` OOC synthesis PASS；
- 26 个 BRAM36 分别来自 input buffer 16、PW weight 8、DW tile 2；
- 仅接入 new DS 的 `cnn_top` 能完成 synthesis，但因旧 stem/GAP/FC packed loader
  仍使用 446272 LUT，不能装入 K26；
- 后续已移除 runner 中这些 packed payload，并把 feature SRAM 改成 XPM BRAM；
- post-refactor 13 项功能回归全部 PASS；
- post-refactor `cnn_top` OOC synthesis PASS，0 error、0 critical warning；
- 顶层使用 45830 CLB LUT（39.13%）、18387 FF（7.85%）、
  42 BRAM36（29.17%）、60 DSP（4.81%）；
- `feature_sram_pingpong` 使用 16 RAMB36 和 67 LUT；
- `u_ds_block_engine` 使用 24283 LUT、15630 FF、26 RAMB36、14 DSP；
- `cnn_layer_runner` 自身非子模块部分降至 14812 LUT，已消除原 333191 logic LUT
  的 packed loader 资源爆炸。

仍未确认的是 place-and-route、WNS/Fmax、拥塞、功耗和板级时序。旧的
446272-LUT 报告只对应“替换 DS、尚未替换 stem/GAP/FC”的中间版本，不能用来评价
当前 RTL。

当前 Vivado 安装还会对 K26 part 报
`Cannot run timing on a non-timing device`，所以即使 synthesis utilization 成功，也
不能把它写成 timing closure。

## 6. 一键复现

### 6.1 Windows XSim 回归

在 `D:\Stuff\Project`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1
```

只跑指定测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1 `
  -Tests tb_ds_block_tile_engine_new,tb_cnn_top_fullnet_sram_datapath
```

如果 Vivado 不在默认路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1 `
  -VivadoBin C:\Xilinx\Vivado\2021.2\bin
```

脚本有意排除 `rtl/npc/`，因为它是 CNN datapath 回归；NPC/CPU 联合仿真仍使用原
Verilator flow。XSim 编译整个 NPC 时，旧 `rv_core.v` 的 implicit-net 声明顺序会
触发独立的 XSim 错误，与本次 CNN 重构无关。

### 6.2 new DSBlock OOC 综合

```powershell
& D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -mode batch `
  -source scripts\vivado_cnn_top_synth.tcl `
  -tclargs ds_block_tile_engine_new xck26-sfvc784-2LV-c
```

结果：

- `docs/synthesis_vivado_ds_block_tile_engine_new.md`
- `build/reports/vivado_ds_block_tile_engine_new/utilization.txt`
- `build/reports/vivado_ds_block_tile_engine_new/utilization_hierarchical.txt`

### 6.3 最终 `cnn_top` 综合

```powershell
& D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -mode batch `
  -source scripts\vivado_cnn_top_synth.tcl `
  -tclargs cnn_top xck26-sfvc784-2LV-c
```

验收时先看：

1. `docs/synthesis_vivado_initial.md` 中 `Status`；
2. `build/reports/vivado_cnn_top/utilization.txt` 的 CLB LUT/FF/BRAM/DSP；
3. hierarchical report 中 `cnn_layer_runner` 不应再出现数十万 logic LUT；
4. `feature_sram_pingpong` 应出现 16 个 RAMB36 左右，而不是 10240 LUTRAM；
5. `u_ds_block_engine` 应保持约 24K LUT、26 BRAM 的数量级。

本分支的 2026-07-17 实测结果满足以上五项。顶层报告在
`docs/synthesis_vivado_initial.md`，详细层级在
`build/reports/vivado_cnn_top/utilization_hierarchical.txt`。

## 7. 如何从 main 复现这条分支的思路

```powershell
git switch main
git switch -c refactor/streaming-dsblock-bram
```

按以下顺序实现，每一步都跑对应 golden：

1. 写 `ds_input_tile_buffer_bram.v` 和 `pw_weight_buffer_bram.v`；
2. 用 scalar cfg port 组装 `ds_block_tile_engine_new.v`；
3. 复用 `tests/vectors/dsblock_cases.hex` 写新 testbench；
4. OOC 综合 new DS，先证明资源数量级正确；
5. 在 runner 中把 compact external index 转为内部 MAX-stride index；
6. 跑普通/tiled/SRAM DS top-level tests；
7. 将 stem/GAP/FC packed loader 改为顺序式 new engine；
8. 把 feature SRAM 改为 XPM BRAM，并用 bypass 保持同地址读写契约；
9. 跑 13 项 XSim 回归；
10. 最后跑完整 `cnn_top` synthesis，而不是只看子模块。

理解代码时建议按这个顺序阅读：

```text
tb_ds_block_tile_engine_new.v
  -> ds_block_tile_engine_new.v state machine
  -> ds_input_tile_buffer_bram.v
  -> dw_tile_fusion_engine_new.v
  -> dw_tile_buffer_bram.v
  -> pw_systolic_array_8x8.v
  -> cnn_layer_runner.v loader mapping
  -> conv3x3_stem_engine_new.v / gap_unit_new.v / fc_unit_new.v
```

## 8. 下一步

必须先完成：

1. 换可做 timing 的目标 part/完整 Vivado device support，跑 place-and-route；
2. 将 `cnn_out_buffer` 改为同步 BRAM，并给 store 通路增加显式预取状态；
3. 用真实 full-network layer counter 做逐层 cycle profile。

随后优化：

1. 若 DW 的 16 个 int8 multiplier 仍主要映射 LUT，可比较强制 DSP 与 LUT 的取舍；
2. 给 input/PW/DW BRAM 输出增加可选寄存器，改善高频路径；
3. 依据真实模型 layer cycle counter 决定是否把 stem 从单 MAC 扩到 3 或 9 MAC；
4. 把外部 word-per-int8 改成 packed NHWC byte/burst loader；
5. 加入随机 backpressure、跨 tile 边界和非法 cfg 的 assertions；
6. 完成 CPU/NPC 联合回归和 FPGA SoC top/AXI 接入。
