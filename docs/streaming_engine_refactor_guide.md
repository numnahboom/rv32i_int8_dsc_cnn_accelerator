# Streaming Engine 与 Memory-Oriented 重构指南

> **当前状态（2026-09-01）**：本文主体记录 streaming 重构的历史设计和早期
> 证据。当前权威完整顶层基线、shared unified64 完整网络结果，以及同步读
> shared64 隔离结果，以 [`reports/README.md`](reports/README.md) 和其中链接的
> 报告为准；本文的旧 cycle/resource 数字不代表当前工作树。

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
  3 MAC reuse    input BRAM        load-time       load-time
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

- `conv3x3_stem_engine_new`：保存 300 B input 与 432 B weight，用 3 个复用 int8
  MAC 顺序处理 kernel 项，在面积和 stem 吞吐之间取折中。
- `gap_unit_new`：4096 个输入在加载时直接累计到 256 个 13-bit sum；不再保存
  4 KiB packed feature。
- `fc_unit_new`：保存 256 B input；2560 个 weight 在加载时直接进入 10 个
  accumulator，不再保存整块 FC weight，也不再组合展开 256 个 MAC。
- `feature_sram_bank`：综合时使用 XPM simple-dual-port BRAM；同地址读写语义由
  `read_first` BRAM 加显式 bypass 保持，仿真模型接口不变。

## 3. 当前功能证据

固定 full-network SRAM datapath 已得到 10/10 logits bit-exact 的 fresh 结果：

```text
cycles=944568
status=0x0e69b882
external payload reads=78602
descriptor reads=288
external writes=10
SRAM reads=115808
SRAM writes=102656
throughput=5.438 MAC/cycle
```

这比 1138900-cycle 的冻结旧基线少 194332 cycles（17.06%）。CPU harness 对同一
fixed vector 也得到 `944568` / `0x0e69b882`。三样本 CPU+RTL 联合验证（tracked
vectors 未变）对所有 logits bit-exact，argmax 依次为 3、8、8。

新 bounds TB 逐笔检查 SRAM 地址。tiled 外部读 TB 覆盖单 outstanding、0..3 个
idle-cycle 响应延迟、ready stall、stalled payload 稳定性与写序列 oracle。2026-08-21
fresh XSim 重新编译 27 个 RTL 文件后为 16/16 PASS。独立 WSL Verilator 5.020 定向
回归也 clean PASS：tiled Stem 16384 checks、tiled DSBlock 2256 checks、tile engine
7 cases / 2191 checks。完整 38-test Verilator aggregation 仍是后续归档项，不能把
这些定向结果误称为其替代品。

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

| case | shape 摘要 | total | DW | PW | PW issue theoretical |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | 8x8 output, Cin=8, Cout=8 | 2937 | 2240 | 697 | 64 |
| 1 | 4x4 output, Cin=16, Cout=16 | 1113 | 700 | 413 | 64 |
| 2 | 8x8 output, Cin=32, Cout=32 | 2985 | 296 | 2689 | 256 |

`PW issue theoretical` 是理论阵列工作拍，不是实测的 loader 周期：

```text
ceil(pixels/8) * ceil(Cout/8) * Cin
```

说明 8x8 PW 阵列在真正的 MAC issue 阶段没有额外空拍；总周期还包含 BRAM 读、
DW 流、requant 扫描和 tile/channel 切换。

## 5. 当前综合证据边界

本工作树已经引入同步预取 `cnn_out_buffer`（综合/XPM 为 4 BRAM）、compact/tiled
loader lookahead 和 PW BRAM lookahead。2026-08-18 的 fresh `cnn_top` OOC synthesis
得到 30451 CLB LUT、18558 CLB registers、46 Block RAM tiles 和 65 DSPs；层级中
`u_out_buffer` 为 6 LUT / 4 BRAM，证明输出 buffer 已从先前 LUTRAM 方案收敛为 XPM
BRAM。旧的 45830-LUT report 仅作历史对照，不能再作为本工作树资源口径。

普通 XSim 和 Verilator 走 output buffer 的同步 behavioral model。XPM 分支只由
synthesis 结构验证，普通仿真不会直接执行它。

当前 Vivado 安装对 K26 part 报 `Cannot run timing on a non-timing device`。即使
获得 utilization 或 non-timing implementation 结果，也不能声称 WNS、Fmax 或
place-and-route timing closure。需要 timing-capable part/device database 才能完成
这一口径。

## 6. 一键复现

下面的“fresh”指在同一个 `git rev-parse HEAD`、未改动 RTL/TB/vector 输入的
工作树中重新执行命令；不要把不同提交或被测试重写过的 vectors 的结果混在一起。
建议在每轮开始和结束各执行一次：

```powershell
git rev-parse HEAD
git status --short
```

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

### 6.2 Verilator 完整回归（保留已跟踪 vectors）

在 WSL/MSYS2 bash 中：

```bash
cd /mnt/d/Stuff/Project
GENERATE_TEST_VECTORS=0 \
SIM_LOG_DIR=build/reports/verilator_current \
./scripts/run_all_sims.sh
```

`run_sim.sh` 默认会调用 vector generator；`GENERATE_TEST_VECTORS=0` 是复现
已验证 fixed-vector 结果的必要条件，避免回归过程意外重写 `tests/vectors/`。
验收 `build/reports/verilator_current/summary.csv` 的每一行均为 `PASS`，并保存其中
fullnet 的 metrics/CSV。需要刻意重新生成 vectors 时，单独运行 generator 后检查
diff，再进行新一轮回归，而不要把两个证据集混用。

### 6.3 new DSBlock OOC 综合（历史对照）

```powershell
& D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -mode batch `
  -source scripts\vivado_cnn_top_synth.tcl `
  -tclargs ds_block_tile_engine_new xck26-sfvc784-2LV-c
```

这些路径可用于历史对照；当前 loader/output-buffer RTL 已变化，必须重新运行后才可
作为当前资源结论。结果目录为：

- `docs/reports/README.md`（当前完整顶层与 DS 实现证据索引）
- `build/reports/vivado_ds_block_tile_engine_new/utilization.txt`
- `build/reports/vivado_ds_block_tile_engine_new/utilization_hierarchical.txt`

### 6.4 当前 `cnn_top` 综合

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_synthesis_vivado.ps1 `
  -Top cnn_top `
  -Part xck26-sfvc784-2LV-c
```

对当前工作树，验收时先看：

1. `docs/reports/synthesis_vivado_summary.md` 中的历史 synthesis `Status`；
2. `build/reports/vivado_cnn_top/utilization.txt` 的 CLB LUT/FF/BRAM/DSP；
3. hierarchical report 中 `cnn_layer_runner` 不应再出现数十万 logic LUT；
4. `feature_sram_pingpong` 应出现 16 个 RAMB36 左右，而不是 10240 LUTRAM；
5. `u_ds_block_engine` 应保持约 24K LUT、26 BRAM 的数量级。

此前归档结果不能替代这次重跑。`run_synthesis_vivado.ps1` 将当前 run 的日志放在
`build/reports/vivado_cnn_top/`，并更新 `docs/reports/synthesis_vivado_summary.md`。
这一步只接受 utilization/结构结论；K26 non-timing database 产生的 timing 报错不应
被解读为负 slack，也不能据此给出 Fmax。

### 6.5 Implementation 尝试与结论口径

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_impl.ps1 `
  -Top cnn_top `
  -Part xck26-sfvc784-2LV-c
```

该 wrapper 为每次运行创建独立 manifest。只有 manifest 的
`status: PASSED_TIMING_CLOSURE`，并且报告来自带真实时序模型和 XDC 的
timing-capable target，才可报告 WNS/Fmax 或“时序闭合”。本机 K26 database 下预期
不会满足该条件；这仍是有价值的流程健壮性检查，不是实现成功或失败的性能结论。

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
9. 跑当前 XSim/Verilator gate，并逐日志确认 PASS token；
10. 最后为该 exact tree 跑完整 `cnn_top` synthesis，而不是只看子模块。

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
2. 用真实 full-network layer counter 做逐层 cycle profile。

随后优化：

1. 若 DW 的 16 个 int8 multiplier 仍主要映射 LUT，可比较强制 DSP 与 LUT 的取舍；
2. 给 input/PW/DW BRAM 输出增加可选寄存器，改善高频路径；
3. 依据真实模型 layer cycle counter 决定 3-MAC stem 是否需要继续扩到 9 MAC；
4. 把外部 word-per-int8 改成 packed NHWC byte/burst loader；
5. 加入随机 backpressure、跨 tile 边界和非法 cfg 的 assertions；
6. 完成 CPU/NPC 联合回归和 FPGA SoC top/AXI 接入。
