# rv32i_int8_dsc_cnn_accelerator

这是一个面向 RV32I/NPC 教学 CPU 的 int8 深度可分离卷积 CNN 加速器工程。当前版本的目标不是做通用 NPU，而是把一个固定形状的 EdgeDSCNet-C10 网络从 Python golden、量化导出、RTL 数据面、CPU 控制接口到 bare-metal firmware 串成可仿真的端到端闭环。

当前主线是：

```text
Python/PyTorch checkpoint
  -> int8 quant export
  -> firmware headers / RTL vectors
  -> RV32I custom instruction or MMIO
  -> cnn_top descriptor-driven full-network inference
  -> logits / argmax compare
```

## 当前状态

- `cnn_top` 已不是空的 descriptor/status skeleton，已经通过 `cnn_layer_runner` 接入 Stem、DSBlock、GAP、FC 的真实仿真数据面。
- 支持固定 EdgeDSCNet-C10 形状：`Stem -> 6x DSBlock -> GAP -> FC`。
- DSBlock 的 depthwise 中间结果进入 tile buffer，随后 pointwise 直接消费，不再把 DW 中间 feature 写回外部 memory。
- PW1x1 使用 8x8 int8 systolic/MAC array。
- Feature SRAM 使用 A/B ping-pong 方式做层间 feature 传递。
- CPU 控制路径已有三种验证层级：`rv_cnn_custom_if`、`npc_cnn_custom_bridge`、`rv_core -> bridge -> cnn_top`。
- C firmware 已实现裸机 driver/demo：初始化 9 层 descriptor，发出 `cnn.start`，poll done，读取 status/cycle，并对 10 类 logits 做 argmax。
- MMIO fallback 也可用，便于不走 custom instruction 时调试同一套 accelerator 控制寄存器。
- Python 侧已有训练 smoke、量化导出、golden model、test vector、firmware header export、logits compare、资源估算和性能报告脚本。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `rtl/cnn` | CNN accelerator 主数据面、子模块、控制器和状态计数器 |
| `rtl/cpu_if` | RV32I custom instruction 接口、NPC bridge、MMIO 寄存器接口 |
| `rtl/npc` | NPC/RV32I CPU 工程副本和联合仿真所需 ROM/RAM 生成逻辑 |
| `sw/firmware` | 裸机 C firmware、custom instruction wrapper、MMIO fallback、startup/linker |
| `sw/model` | 当前导出的模型 descriptor、量化参数和权重 header |
| `python` | 训练、量化、golden 推理、vector/header 导出、报告生成脚本 |
| `sim` | Verilator/SystemVerilog testbench |
| `tests/vectors` | 单元级和 fullnet 级测试向量 |
| `scripts` | 仿真、模型导出、firmware 构建、报告生成入口 |
| `docs` | 架构、量化、验证计划、已知限制和优化 bring-up 记录 |
| `build` | 已生成的模型、firmware、报告、仿真日志和 Verilator 产物 |

## 网络结构

| Layer | Op | Shape | Stride | Output | Activation |
| --- | --- | --- | --- | --- | --- |
| 0 | Input | 32x32x3 | - | 32x32x3 | - |
| 1 | Conv3x3 Stem | 3 -> 16 | 1 | 32x32x16 | ReLU6 |
| 2 | DSBlock1 DW/PW | 16 -> 32 | 1 | 32x32x32 | ReLU6 |
| 3 | DSBlock2 DW/PW | 32 -> 64 | 2 | 16x16x64 | ReLU6 |
| 4 | DSBlock3 DW/PW | 64 -> 64 | 1 | 16x16x64 | ReLU6 |
| 5 | DSBlock4 DW/PW | 64 -> 128 | 2 | 8x8x128 | ReLU6 |
| 6 | DSBlock5 DW/PW | 128 -> 128 | 1 | 8x8x128 | ReLU6 |
| 7 | DSBlock6 DW/PW | 128 -> 256 | 2 | 4x4x256 | ReLU6 |
| 8 | GAP | 4x4x256 | - | 1x1x256 | none |
| 9 | FC | 256 -> 10 | - | 10 logits | none |

当前 `sw/model` 来自 PyTorch/CUDA 训练 checkpoint 的 int8 导出。最近保存的导出摘要：

```text
checkpoint_eval_acc=0.503700
int8_eval_samples=256
int8_eval_acc=0.464844
sample_logits=-65,-69,13,4,39,17,24,22,-112,-85
sample_argmax=4
```

这些数值用于功能验证，不代表最终 CIFAR-10 模型质量目标。

## 量化格式

Activation 和 weight 使用 signed int8，bias 和 accumulator 使用 signed int32。硬件 v1 使用离线修正后的 bias，并与 Python golden 对齐：

```text
acc = sum(input_int8 * weight_int8) + corrected_bias
x = round_away_from_zero((acc * multiplier) / 2^31)
x = arithmetic_right_shift(x, shift)
x = x + output_zero_point
x = saturate_int8(x)
x = clamp(x, activation_min, activation_max)
```

Padding 使用当前 layer 的 `input_zero_point`。ReLU6 通过量化后的 `activation_min`/`activation_max` 表达；FC 输出使用完整 int8 范围 `[-128, 127]`。

## 硬件架构

```text
rv_core
  |
  | custom0 instruction
  v
npc_cnn_custom_bridge / rv_cnn_custom_if
  |
  v
cnn_top
  |-- descriptor_fetch
  |-- cnn_top_ctrl
  |-- cnn_layer_runner
  |-- tile_scheduler
  |-- feature_sram_pingpong
  |     `-- feature_sram_bank A/B
  |-- conv3x3_stem_engine
  |-- dw_tile_fusion_engine
  |-- dw_tile_buffer / dw_tile_buffer_bram
  |-- pw_systolic_array_8x8
  |-- gap_unit
  |-- fc_unit
  `-- status_counter

Optional debug/control path:

MMIO bus -> cnn_mmio_regs -> cnn_top
```

`cnn_top` 由 descriptor 驱动，每层 descriptor 为 32 words / 128B stride。控制器顺序 fetch descriptor，启动对应 engine，等待真实 `layer_done/layer_error`，并通过 status counter 暴露 cycle、当前层、busy/done/error。

当前外部 memory 仿真格式仍是“一 int8 element 一 32-bit word，低 8 位有效”。这是为了简化仿真和调试，后续需要改为 packed NHWC byte layout。

## CPU 和 Firmware 接口

### Custom instruction

当前使用 RV32I `custom0` opcode，软件侧通过 `.insn` 封装：

| 指令 | 输入/输出 | 语义 |
| --- | --- | --- |
| `cnn.start rs1, rs2` | `rs1=descriptor base`, `rs2=layer_num` | 启动 accelerator，等待命令被接收 |
| `cnn.poll rd` | `rd=status` | 返回 packed status：`{cycle_count[23:0], current_layer[3:0], 1'b0, error, done, busy}` |
| `cnn.stat rd` | `rd=cycle_count` | 返回解码后的 cycle counter：`{8'd0, status[31:8]}` |

### MMIO fallback

编译 firmware 时设置 `CNN_ACCEL_USE_CUSTOM=0` 可切到 MMIO fallback。寄存器由 `rtl/cpu_if/cnn_mmio_regs.v` 提供：

| Offset | Register | 作用 |
| --- | --- | --- |
| `0x00` | `DESC_BASE` | descriptor base address |
| `0x04` | `LAYER_NUM` | layer count |
| `0x08` | `CMD` | 写 `CNN_CMD_START` 启动 |
| `0x0c` | `STATUS` | packed status |
| `0x10` | `STAT` | 解码后的 cycle counter |

### Firmware demo

`sw/firmware/main.c` 当前流程：

1. 调用 `edgedscnet_c10_init_desc()` 展开模型 payload 并初始化 9 层 descriptor。
2. 调用 `cnn_accel_start((uint32_t)g_model_desc, EDGE_DSC_NET_C10_LAYER_NUM)`。
3. 轮询 `cnn_accel_wait_done()`。
4. 读取 `cnn_demo_status` 和 `cnn_demo_cycle_count`。
5. 从 `g_model_logits_words[10]` 做 argmax，写入 `cnn_demo_prediction`。

## 快速开始

以下脚本主要按 WSL/Linux shell 组织。Windows 下工程路径对应为 `D:\Stuff\Project`，WSL 下通常是 `/mnt/d/Stuff/Project`。

### 1. 导出模型和 firmware headers

```bash
cd /mnt/d/Stuff/Project
MAX_SAMPLES=128 EVAL_SAMPLES=64 ./scripts/export_model.sh
```

该脚本顺序执行：

```text
python/train_edgedscnet_c10.py
python/quantize_export.py
python/export_firmware_headers.py
python/compare_outputs.py
```

主要输出：

- `build/model/edgedscnet_c10_smoke.npz`
- `build/model_export/edgedscnet_c10_int8_smoke.npz`
- `tests/vectors/training_smoke/input_image.hex`
- `tests/vectors/training_smoke/expected_logits.hex`
- `tests/vectors/training_smoke/expected_fullnet_logits.hex`
- `tests/vectors/training_smoke/expected_argmax.hex`
- `sw/model/model_desc.h`
- `sw/model/model_quant.h`
- `sw/model/model_weights.h`

### 2. 运行单项仿真

```bash
cd /mnt/d/Stuff/Project
./scripts/run_sim.sh tb_requant_activation_unit
./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath
./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet
```

### 3. 运行回归

```bash
cd /mnt/d/Stuff/Project
./scripts/run_all_sims.sh
```

可用环境变量筛选或恢复：

```bash
SIM_LIST=1 ./scripts/run_all_sims.sh
SIM_ONLY="tb_npc_cnn_custom_bridge tb_npc_bridge_cnn_top_fullnet" ./scripts/run_all_sims.sh
SIM_FROM=tb_cnn_top_tiled_stem_datapath ./scripts/run_all_sims.sh
SIM_TO=tb_cnn_top_fullnet_sram_datapath ./scripts/run_all_sims.sh
SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
SIM_LOG_DIR=build/reports/my_sim_logs SIM_ONLY=tb_requant_activation_unit ./scripts/run_all_sims.sh
```

默认日志位置：

```text
build/reports/sim_logs/<test>.log
build/reports/sim_logs/summary.csv
```

### 4. 生成推理精度和周期报告

```bash
cd /mnt/d/Stuff/Project
./scripts/run_inference_report.sh
```

输出：

- `build/reports/inference_accuracy_perf.md`
- `build/reports/fullnet_expected_logits.hex`
- `build/reports/fullnet_hw_logits.hex`
- `build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt`
- `build/reports/fullnet_layer_metrics.csv`

### 5. 构建 firmware 和 ROM

需要 `riscv64-unknown-elf-gcc`、`objcopy` 等 RISC-V bare-metal 工具链。

```bash
cd /mnt/d/Stuff/Project
./scripts/build_firmware.sh
./scripts/build_firmware_rom.sh
```

MMIO fallback 版本：

```bash
EXTRA_CFLAGS="-DCNN_ACCEL_USE_CUSTOM=0" ./scripts/build_firmware.sh
```

当前已生成的 firmware 产物位于：

```text
build/firmware/cnn_demo.elf
build/firmware/cnn_demo.bin
build/firmware/rom.hex
```

### 6. 多样本 RTL/CPU 联合验证

```bash
cd /mnt/d/Stuff/Project
SAMPLES=3 START_INDEX=0 ./scripts/run_multi_sample_rtl.sh
```

该脚本会为每个样本重新导出 headers/vectors，并复用 `tb_npc_rv_core_cnn_top_fullnet` 检查 RTL logits 和 Python int8 golden 是否逐元素一致。

## 最近验证快照

最近保存的完整回归目录为 `build/reports/sim_logs_full_20260621`，包含 35 个 testbench，全部 PASS。

| 用例 | 状态 | 关键结果 |
| --- | --- | --- |
| `tb_cnn_top_fullnet_sram_datapath` | PASS | `hw_cycles=3501306`, `checks=10`, `errors=0`, `status=356cfa82` |
| `tb_mmio_cnn_top_fullnet` | PASS | `polls=1750654`, `status=356cfa82`, `hw_cycles=3501306`, `checks=10` |
| `tb_rv_custom_if_cnn_top_fullnet` | PASS | custom instruction -> `cnn_top` fullnet 闭环 |
| `tb_npc_bridge_cnn_top_fullnet` | PASS | `polls=3501308`, `status=356cfa82`, `hw_cycles=3501306`, `checks=10` |
| `tb_npc_rv_core_cnn_top_fullnet` | PASS | `cycles=3501306`, `status=356cfa82`, `start_count=1`, `stat_count=1`, `argmax=4` |

当前 fullnet logits compare：

```text
expected: fb fd 08 fd 02 f5 fe fe 04 f5
hardware: fb fd 08 fd 02 f5 fe fe 04 f5
```

按 int8 解释为：

```text
-5 -3 8 -3 2 -11 -2 -2 4 -11
```

当前保存的 fullnet metrics：

```text
hw_cycles=3501306
mem_reads=78890
mem_writes=10
desc_reads=288
checks=10
errors=0
```

最近保存的多样本联合仿真工作目录 `build/multi_sample_rtl` 显示 sample `0,1,2` 均 PASS，且 `expected_argmax == rtl_argmax`。

## 资源估算

静态资源估算脚本：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_resource_report.sh
```

输出：

- `build/reports/resource_estimate.md`

当前静态估算摘要：

```text
Total modeled local storage: 168.3 KiB
BRAM36 lower bound if perfectly packed: 38
BRAM36 estimate if each buffer is separate: 49
Intended SRAM/BRAM buffers only: 18 BRAM36
Packed-reg storage risk: 789040 FF bits if not memory-inferred
Logical int8 multipliers: 114
Wide requant multipliers: 4
Conservative DSP risk estimate: 178 DSPs
```

这不是 Vivado/Yosys post-synthesis 结果，只是 RTL 参数级估算。当前最大综合风险不是 feature SRAM 本身，而是 `cnn_layer_runner.v` 中为了仿真便利保留的大型 packed staging 向量。

## 关键已实现模块

- Python/model: `train_edgedscnet_c10.py`, `quantize_export.py`, `golden_int8.py`, `export_firmware_headers.py`, `generate_test_vectors.py`, `compare_outputs.py`
- Arithmetic: `round_shift.v`, `saturate_int8.v`, `requant_activation_unit.v`, `requant_activation_pipeline.v`
- Stem/DW/PW: `conv3x3_stem_engine.v`, `dw_mac_lanes.v`, `dw_tile_fusion_engine.v`, `dw_tile_fusion_engine_new.v`, `pw_systolic_array_8x8.v`
- Buffer/SRAM: `feature_sram_bank.v`, `feature_sram_pingpong.v`, `dw_tile_buffer.v`, `dw_tile_buffer_bram.v`
- Top control: `descriptor_fetch.v`, `cnn_top_ctrl.v`, `cnn_layer_runner.v`, `cnn_top.v`, `status_counter.v`
- CPU IF: `rv_cnn_custom_if.v`, `npc_cnn_custom_bridge.v`, `cnn_mmio_regs.v`
- Firmware: `cnn_accel.h`, `cnn_accel.c`, `main.c`, `startup.S`, `linker.ld`

## 已知限制

- 当前是固定 EdgeDSCNet-C10 shape 的功能型 v1，不是通用 CNN/NPU。
- 当前模型精度足够做硬件功能验证，但不是最终 ML 质量目标。
- 外部 memory 仍大量使用 word-per-int8 仿真布局，尚未改成 packed NHWC byte layout。
- `dw_tile_buffer_bram` 已有独立验证，但 BRAM-oriented buffer 还没有完全替换当前 DSBlock 主路径。
- `cnn_layer_runner` 仍有大型 packed payload/staging 向量，导致 full `cnn_top` OOC 综合难以在本地 1 小时限制内完成。
- Requant 当前优先 bit-exact 对齐 Python golden，后续仍需要根据 DSP/时序压力做位宽收敛、共享或流水化。
- 已有 NPC/RV32I 联合仿真 harness，但还不是面向 FPGA 上板的生产级 SoC top。
- 缺少形式验证和更强的 constrained-random/backpressure 压力测试。

## 下一步

1. 把 `cnn_layer_runner` 中的大型 packed payload 向量替换为真实 SRAM/loader 接口。
2. 将已验证的 BRAM tile buffer 接入 DSBlock 主路径，并为 feature/weight storage 增加 BRAM-oriented wrapper。
3. 将 word-per-int8 外部 memory 布局改成 packed NHWC byte addressing 和 burst-friendly loader。
4. 对 requant multiplier、PW array fanout、valid/control 信号做综合后的时序优化。
5. 用更强的 PTQ/QAT checkpoint 重新导出 firmware headers，并扩大多样本 RTL 回归。
6. 建立更接近真实 SoC 的顶层、memory arbitration、UART/GPIO debug 和 FPGA synthesis/implementation 流程。

更多细节见：

- `docs/quantization.md`
- `docs/network_spec.md`
- `docs/module_design_contracts.md`
- `docs/verification_plan.md`
- `docs/known_limits_next_steps.md`
- `docs/project_next_optimization_bringup_guide.md`
