# rv32i_int8_dsc_cnn_accelerator

基于 RV32I 自定义指令控制的 int8 深度可分离卷积 CNN 加速器。当前版本聚焦可仿真的 v1 数据面：`cnn_top` 通过 descriptor 顺序执行 Stem、DSBlock、GAP、FC，支持 SRAM ping-pong 层间传递，并已覆盖 EdgeDSCNet-C10 固定网络形状的 full-network smoke。

## 项目状态

- RTL 顶层不再只是 descriptor/status skeleton，`cnn_layer_runner` 已接入真实 engine。
- 已支持 `OP_CONV3X3_STEM`、`OP_DS_BLOCK`、`OP_GAP`、`OP_FC` 的仿真数据面。
- DSBlock 的 DW 中间结果只进入 `dw_tile_buffer`，不写回外部 memory。
- PW1x1 使用 8x8 int8 systolic array。
- Firmware smoke 可以初始化 9 层 fullnet descriptor，启动 accelerator，poll done，并对 logits 做 argmax。
- 已有 `cnn_mmio_regs -> cnn_top` 联合 fullnet smoke，验证 firmware MMIO fallback 路径。
- 已有 `rv_cnn_custom_if -> cnn_top` 联合 fullnet smoke，验证 custom0 opcode 的 start/poll/stat 与真实数据面闭环。
- 已有 `npc_cnn_custom_bridge -> cnn_top` 联合 fullnet smoke，验证 start/poll/stat 与真实数据面闭环。
- Python 侧提供 golden/vector、轻量训练 smoke、int8 smoke export、firmware header export 和 hex compare。

## 网络结构

| Layer | Op | Shape | Stride | Output | Activation |
| --- | --- | --- | --- | --- | --- |
| 0 | Input | 32x32x3 | - | 32x32x3 | - |
| 1 | Conv3x3 Stem | 3->16 | 1 | 32x32x16 | ReLU6 |
| 2 | DSBlock1 DW/PW | 16->32 | 1 | 32x32x32 | ReLU6 |
| 3 | DSBlock2 DW/PW | 32->64 | 2 | 16x16x64 | ReLU6 |
| 4 | DSBlock3 DW/PW | 64->64 | 1 | 16x16x64 | ReLU6 |
| 5 | DSBlock4 DW/PW | 64->128 | 2 | 8x8x128 | ReLU6 |
| 6 | DSBlock5 DW/PW | 128->128 | 1 | 8x8x128 | ReLU6 |
| 7 | DSBlock6 DW/PW | 128->256 | 2 | 4x4x256 | ReLU6 |
| 8 | GAP | 4x4x256 | - | 1x1x256 | none |
| 9 | FC | 256->10 | - | 10 logits | none |

## 量化格式

Activation 和 weight 使用 signed int8，bias 和 accumulator 使用 signed int32。硬件 v1 使用离线修正后的 bias：

```text
acc = sum(input_int8 * weight_int8) + corrected_bias
```

Requant 与 Python golden 保持一致：

```text
x = acc + bias
x = round_away_from_zero((x * multiplier) / 2^31)
x = arithmetic_right_shift(x, shift)
x = x + output_zero_point
x = saturate_int8(x)
x = clamp(x, activation_min, activation_max)
```

Padding 使用当前 layer 的 `input_zero_point`。ReLU6 通过 `activation_min=quantized(0)` 和 `activation_max=quantized(6)` 表达；FC 使用 `[-128, 127]`。

## 自定义指令

| 指令 | 输入 | 语义 |
| --- | --- | --- |
| `cnn.start rs1, rs2` | `rs1=descriptor base`, `rs2=layer_num` | 启动 accelerator，只等待命令被接收 |
| `cnn.poll rd` | - | 返回 packed status：`{cycle_count[23:0], current_layer[3:0], 1'b0, error, done, busy}` |
| `cnn.stat rd` | - | 返回解码后的 cycle counter：`{8'd0, status[31:8]}` |

软件侧当前提供 custom instruction wrapper 和 MMIO fallback。`npc_cnn_custom_bridge.v` 已适配现有 NPC custom 端口，但尚未直接替换 `rtl/npc` SoC 顶层里的旧加速器连接。

## RTL 结构

```text
rv_core
  |
  v
rv_cnn_custom_if / npc_cnn_custom_bridge
cnn_mmio_regs
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
  |-- dw_tile_fusion_engine -- dw_tile_buffer
  |-- pw_systolic_array_8x8
  |-- gap_unit
  |-- fc_unit
  `-- status_counter
```

## DW Tile Fusion

DW3x3 按 spatial tile 读取带 halo 的 input tile，越界点填 `input_zero_point`。DW MAC lanes 完成 depthwise convolution 和 requant 后，只把 tile 输出写入 `dw_tile_buffer[pixel][channel]`。DW 中间结果不写回外部 memory；随后 PW1x1 直接从 tile buffer 读取 activation。

## PW Systolic Array

PW1x1 映射为：

```text
A[8 pixels][Cin] * W[Cin][8 output channels] = O[8 pixels][8 output channels]
```

每 cycle 输入同一个 `cin` 上的 8 个 pixel activation 和 8 个 output-channel weight。8x8 PE 阵列内部保持 int32 psum，`k_last` 后输出完整 psum，再经 bias、requant、activation 写回 output feature。

## cnn_top v1 数据面

- Descriptor 为 32 words / 128B stride。
- `cnn_top_ctrl` 等待真实 `layer_done/layer_error`，不再使用固定 latency 模拟执行。
- `cnn_layer_runner` 负责 payload load、engine start/wait、output store。
- Stem 和 DSBlock 均支持 tiled full-feature-map execution。
- Feature SRAM A/B 支持 ping-pong，descriptor flags 控制 input/output 是否走 SRAM。
- 外部 memory v1 仿真格式为“一 int8 element 一 32-bit word”，低 8 位有效。
- 已有 full-network smoke：`Stem -> 6x DSBlock -> GAP -> FC`，最终 logits 与 Python golden 对齐。

## 训练模型

轻量训练 smoke 使用 PyTorch 实现 EdgeDSCNet-C10。脚本会优先使用 `PYTHON`，其次使用 `python3`，若没有 NumPy 会回退到本机已有的 `/mnt/d/Stuff/Documented/Model/.venv/python.exe`。

```bash
cd /mnt/d/Stuff/Project
MAX_SAMPLES=128 EVAL_SAMPLES=64 ./scripts/export_model.sh
```

`scripts/export_model.sh` 会顺序执行：

```bash
python/train_edgedscnet_c10.py
python/quantize_export.py
python/export_firmware_headers.py
python/compare_outputs.py
```

默认输出：

- `build/model/edgedscnet_c10_smoke.npz`
- `build/model_export/edgedscnet_c10_int8_smoke.npz`
- `tests/vectors/training_smoke/input_image.hex`
- `tests/vectors/training_smoke/expected_logits.hex`
- `tests/vectors/training_smoke/expected_fullnet_logits.hex`
- `tests/vectors/training_smoke/expected_argmax.hex`
- `sw/model/model_weights.h`
- `sw/model/model_quant.h`

当前导出是 smoke 级验证：训练一个很小 batch 的 fp32 模型，保存 CIFAR-10 样本，再生成确定性 int8 参数并用 Python golden 产出 logits。它用于证明训练/导出/向量生成链路可跑通，不等同于正式 PTQ/QAT 精度验收。

Firmware header export 使用 compact 方案：ROM 中保存 packed int8 权重和输入样本，启动时展开到当前 accelerator v1 需要的 word-per-int8 buffer。这样能接入 smoke 参数，同时避免把 300KB 以上的初始化 word payload 放进 ROM。

## 运行仿真

在 WSL 中进入工程根目录：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_sim.sh tb_requant_activation_unit
./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath
./scripts/run_all_sims.sh
```

Long regressions can be chunked or resumed:

```bash
SIM_LIST=1 ./scripts/run_all_sims.sh
SIM_FROM=tb_cnn_top_tiled_stem_datapath ./scripts/run_all_sims.sh
SIM_TO=tb_cnn_top_fullnet_sram_datapath ./scripts/run_all_sims.sh
SIM_ONLY="tb_npc_cnn_custom_bridge tb_npc_bridge_cnn_top_fullnet" ./scripts/run_all_sims.sh
SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
SIM_LOG_DIR=build/reports/my_sim_logs SIM_ONLY=tb_requant_activation_unit ./scripts/run_all_sims.sh
```

Each selected regression writes a per-test log and CSV summary. By default:

```text
build/reports/sim_logs/<test>.log
build/reports/sim_logs/summary.csv
```

## 推理精度与周期报告

运行完整 `cnn_top` SRAM fullnet RTL 推理，并与 Python/software golden logits 做逐元素比较：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_inference_report.sh
```

报告输出到：

- `build/reports/inference_accuracy_perf.md`
- `build/reports/fullnet_expected_logits.hex`
- `build/reports/fullnet_hw_logits.hex`
- `build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt`
- `build/reports/fullnet_layer_metrics.csv`

当前 smoke 结果：

```text
Hardware cycles: 1085562
Software golden logits: -5 -3 8 -3 2 -11 -2 -2 4 -11
Hardware RTL logits:    -5 -3 8 -3 2 -11 -2 -2 4 -11
Exact element accuracy: 100.00%
Argmax: 2
RV32I-only theoretical estimate: 341390112 cycles
Estimated RV32I / RTL speedup: 314.48x
External memory reads: 78890
External memory writes: 10
Descriptor reads: 288
```

RV32I-only 理论估算默认假设：无 RV32M，`cycles_per_mac=64`，`cycles_per_requant=80`，`cycles_per_gap_add=3`，单周期 memory 且无 pipeline stall。该估算用于硬件/软件量级对比，不等同于真实 CPU 联合仿真计数。

报告还包含每层 HW cycles、外部 memory read/write 计数，以及 PW systolic array 的端到端 utilization 估算。

## 资源估算报告

当前还没有接入 FPGA 综合工具，先提供静态 RTL 参数估算：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_resource_report.sh
```

报告输出到：

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

该报告不是 Vivado/Yosys post-synthesis 结果；它用于跟踪资源量级，并指出当前 packed-reg staging、wide requant multiplier 等综合风险。

## 运行 Firmware Demo

```bash
./scripts/build_firmware.sh
EXTRA_CFLAGS="-DCNN_ACCEL_USE_CUSTOM=0" ./scripts/build_firmware.sh
```

当前 firmware demo 会运行时展开 `sw/model` 中的 exported smoke payload，初始化 9 层 fullnet descriptor，发出 `cnn.start`，poll done，并从 10 个 word-stride logits 中做 argmax。

默认 firmware 使用 custom instruction；编译时设置 `CNN_ACCEL_USE_CUSTOM=0` 可切换到 MMIO fallback。RTL 侧的 `cnn_mmio_regs.v` 已覆盖同一组寄存器：`DESC_BASE +0x00`、`LAYER_NUM +0x04`、`CMD +0x08`、`STATUS +0x0c`、`STAT +0x10`。其中 `STATUS` 返回 packed status，`STAT` 返回解码后的 cycle counter，与 `cnn.poll`/`cnn.stat` 保持一致。

## 已实现

- Python: `golden_int8.py`, `generate_test_vectors.py`, `train_edgedscnet_c10.py`, `quantize_export.py`, `export_firmware_headers.py`, `compare_outputs.py`, `inference_accuracy_perf_report.py`, `resource_estimate.py`
- Common arithmetic: `round_shift.v`, `saturate_int8.v`, `requant_activation_unit.v`, `requant_activation_pipeline.v`
- PW: `systolic_pe.v`, `pw_systolic_array_8x8.v`
- DW: `dw_line_buffer.v`, `dw_window_generator.v`, `dw_mac_lanes.v`, `dw_tile_buffer.v`, `dw_tile_buffer_bram.v`, `dw_tile_fusion_engine.v`, `dw_tile_fusion_engine_new.v`
- DSBlock integration: `ds_block_tile_engine.v`
- Stem/GAP/FC: `conv3x3_stem_engine.v`, `gap_unit.v`, `fc_unit.v`
- Scheduler/SRAM/status: `tile_scheduler.v`, `feature_sram_bank.v`, `feature_sram_pingpong.v`, `status_counter.v`
- Top datapath: `descriptor_fetch.v`, `cnn_layer_runner.v`, `cnn_top_ctrl.v`, `cnn_top.v`
- CPU IF: `rv_cnn_custom_if.v`, `npc_cnn_custom_bridge.v`, `cnn_mmio_regs.v`
- Firmware: `cnn_accel.h`, `cnn_accel.c`, `main.c`, `startup.S`, `linker.ld`

## 关键仿真

- `tb_requant_activation_unit`
- `tb_requant_activation_pipeline`
- `tb_pw_systolic_array_8x8`
- `tb_dw_tile_fusion_engine`
- `tb_dw_tile_fusion_engine_new`
- `tb_dw_tile_buffer_bram`
- `tb_ds_block_tile_engine`
- `tb_conv3x3_stem_engine`
- `tb_gap_unit`
- `tb_fc_unit`
- `tb_tile_scheduler`
- `tb_feature_sram_bank`
- `tb_feature_sram_pingpong`
- `tb_cnn_top`
- `tb_cnn_top_dsblock_datapath`
- `tb_cnn_top_tiled_stem_datapath`
- `tb_cnn_top_tiled_dsblock_datapath`
- `tb_cnn_top_sram_tiled_dsblock_datapath`
- `tb_cnn_top_ops_datapath`
- `tb_cnn_top_multilayer_datapath`
- `tb_cnn_top_sram_gap_fc_datapath`
- `tb_cnn_top_sram_stem_dsblock_datapath`
- `tb_cnn_top_tail_sram_datapath`
- `tb_cnn_top_e2e_sram_datapath`
- `tb_cnn_top_fullnet_sram_datapath`
- `tb_cnn_mmio_regs`
- `tb_mmio_cnn_top_fullnet`
- `tb_rv_cnn_custom_if`
- `tb_rv_custom_if_cnn_top_fullnet`
- `tb_npc_cnn_custom_bridge`
- `tb_npc_bridge_cnn_top_fullnet`

## 最近验证

```text
python3 -m py_compile python/generate_test_vectors.py
./scripts/run_sim.sh tb_cnn_top_tiled_stem_datapath
./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath
./scripts/build_firmware.sh
riscv64-unknown-elf-size build/firmware/cnn_demo.elf
MAX_SAMPLES=128 EVAL_SAMPLES=64 ./scripts/export_model.sh
./scripts/run_inference_report.sh
./scripts/run_resource_report.sh
./scripts/run_sim.sh tb_rv_cnn_custom_if
./scripts/run_sim.sh tb_npc_cnn_custom_bridge
./scripts/run_sim.sh tb_cnn_mmio_regs
./scripts/run_sim.sh tb_mmio_cnn_top_fullnet
./scripts/run_sim.sh tb_rv_custom_if_cnn_top_fullnet
./scripts/run_sim.sh tb_npc_bridge_cnn_top_fullnet
SIM_LIST=1 ./scripts/run_all_sims.sh
SIM_ONLY=tb_npc_cnn_custom_bridge ./scripts/run_all_sims.sh
SIM_ONLY=tb_requant_activation_unit ./scripts/run_all_sims.sh
EXTRA_CFLAGS="-DCNN_ACCEL_USE_CUSTOM=0" ./scripts/build_firmware.sh
```

Firmware size after exported smoke model:

```text
custom instruction: text=91736 data=0 bss=297008
MMIO fallback:      text=91764 data=0 bss=297008
```

## 待实现

- 将 smoke 级随机 int8 参数替换为正式 PTQ/QAT 导出的训练权重。
- 将 v1 外部 memory 格式从 word-per-int8 切换到 packed NHWC byte layout。
- 直接接入 `rtl/npc` CPU/SOC 顶层并跑 CPU+accelerator 联合仿真。
- 接入真实 FPGA 综合流程，输出 post-synthesis LUT/FF/BRAM/DSP。
- 跑真实 RV32I CPU 软件推理或 CPU+accelerator 联合系统仿真，替代当前理论 RV32I-only cycle 估算。

## 已知限制

- 当前 full-network RTL smoke 和 firmware smoke 都使用确定性 smoke 参数；它们不是正式训练后的 CIFAR-10 精度模型。
- 训练/export 路径是 smoke 级验证，不是正式 PTQ/QAT 或 CIFAR-10 精度目标。
- v1 使用 64-bit 中间乘法实现 requant，优先保证行为清晰和 Python golden 对齐。
- 仅支持固定 EdgeDSCNet-C10 shape，不支持动态网络、任意 kernel、Winograd、稀疏、residual、SE 或 hard-swish。

## 开发日志

详细推进记录、已定位问题和不影响当前验证的优化项见 `docs/development_log.md`。

当前 Project 内已经有 `rtl/npc` 源码副本和 `rv_core -> npc_cnn_custom_bridge -> cnn_top` 联合仿真 harness：

```bash
SIM_ONLY=tb_npc_rv_core_cnn_top_fullnet ./scripts/run_all_sims.sh
```

当前该用例 PASS，记录结果为 `cycles=1085562`、`status=10907a82`、`start_count=1`、`stat_count=1`、`argmax=0`。原始 `D:\Stuff\npc` 工程未被修改，后续 CPU/SoC 接线应以 `Project/rtl/npc` 副本为修改对象。

## 当前训练 checkpoint 验证

当前 `sw/model` 已更新为 PyTorch/CUDA 训练 10 epoch 后导出的 int8 checkpoint：

- float CIFAR-10 eval accuracy：`0.503700`
- int8 golden 抽样 accuracy：`0.484375`，`64` samples
- sample golden logits：`[-65, -69, 13, 4, 39, 17, 24, 22, -112, -85]`
- sample argmax：`4`
- CPU 联合仿真：`./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet` PASS
- 联合仿真结果：`cycles=1033722`、`status=0fc5fa82`、`start_count=1`、`stat_count=1`、`argmax=4`
- 验收重点：RTL logits 与 Python int8 golden 逐元素完全一致。

多样本 RTL 功能仿真可运行：

```bash
SAMPLES=3 START_INDEX=0 ./scripts/run_multi_sample_rtl.sh
```

当前 sample `0,1,2` 均 PASS，`expected_argmax == rtl_argmax`，每个样本的 RTL logits 与对应 Python int8 golden 逐元素完全一致。
