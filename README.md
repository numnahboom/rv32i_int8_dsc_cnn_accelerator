# rv32i_int8_dsc_cnn_accelerator

这是一个从 RV32I/NPC 教学 CPU 和 Xilinx XC7Z020 起步的 INT8 深度可分离卷积 CNN 加速器工程，目前继续向 SMIC 180 nm ASIC 迁移。项目研究固定网络从 Python/PyTorch、量化导出、RTL 数据面、完整推理到物理实现的闭环，并记录 accuracy、integer semantics、cycles、timing、area/resources、power 和 energy efficiency。

系统链路是：

```text
Python/PyTorch checkpoint
  -> int8 quant export
  -> firmware headers / RTL vectors
  -> RV32I custom instruction or MMIO
  -> cnn_top descriptor-driven full-network inference
  -> logits / argmax compare
```

## 当前方向（2026-10-20，ASIC 迁移中）

FPGA P 原型已冻结并 push（`bfb60e5`）；ASIC 工作位于 `codex/d4-asic-smic180`，
在实验室服务器使用实际 SMIC 标准单元库和 SRAM 编译器推进。
两种 RQ 算术实现各通过84次完整网络精确验证；等条件 TT 单路综合中，
完整 signed32 乘法器比继承的部分积结构减少18.70%标准单元面积。
真实编译 SRAM 下的 [2048,1024,2048] 激活 bank 通过84次完整验证，
实际激活宏布局面积比等容量三 bank 减少14.27%。选定 A3 使用3块 SRAM、
8块权重 ROM 和8块残差 ROM，全表、完整网络和复位/协议探针均通过。
同步复位策略下，完整核心 A2/A3 的 TT 10ns 综合面积分别为9.148/9.968 mm²。
A2/A3 新映射各通过8次完整门级精确推理，周期与逐层结果一致，使用真实存储模型与标准单元默认传播延迟，
未标注 SDF、关闭 timing checks，因此不代表频率验收。新形式证明已通过全部13,758点，
零失败、零未匹配、无原生解析错误；存储内容与协议由独立真实模型测试覆盖。
首轮100MHz布线 setup WNS +0.009ns、hold -0.001ns，供电布线 DRC 未闭合。
修正后的预 CTS 供电构建组件已通过19宏/38引脚的零 DRC、零连通错误检查，
新映射的完整物理实现与逻辑证明继续推进；组件结果不替代完整布线验收。
这些结果仍不构成完整 ASIC 验收，当前未声明 ASIC 能效。
迁移合同、复现方法和证据边界见 [ASIC 开发记录](docs/asic_migration.md)。

## FPGA 基线（2026-10-19）

独立 `d4_fullnet_top` 已建立完整 D4 执行链：保持冻结网络与 INT8/INT32 语义，
十个真实类别样本和四种边界输入 × 三种流停顿模式 × 两次启动，共 84 次推理逐层 exact；
每次检查 24,336 个中间 128-bit 字、十个 FC accumulator 和完整 MAC 账本。
K2历史里程碑采用连续双bank与四lane无损残差流水，通过完整回归及在途reset探针，
实际32-bit物理接口下为 **258,749 cycles**，包含start后的全部4,096拍图像传输；
连续启动间隔为 **258,751 cycles**。时钟结构也通过真实UNISIM测试。
E 已完成 XC7Z020 布线：WNS -5.590 ns、
WHS +0.033 ns，资源均低于 70%；该失败物理结果只属于 E。
K2完整布线为20,214 LUT、11,155 FF、93 BRAM、64 DSP，0 routing errors；
WNS -0.990 ns、WHS +0.005 ns，125MHz setup仍失败。L的精确RQ部分积流水与完成握手分离
已通过完整功能门，latency/interval为258,813/258,815 cycles；L2数据级valid使能也通过完整功能门；同源综合18,739 LUT、9,653 FF、93 BRAM、64 DSP，WNS -1.051ns，最差路径转为外部start_valid到state CE。M寄存启动token已通过完整功能门，外部258,814 cycles/间隔258,816；完整综合18,741 LUT/9,654 FF/93 BRAM/64 DSP，WNS -0.467ns，M post-route为18,197 LUT/9,620 FF/93 BRAM/64 DSP、WNS -0.287ns、WHS +0.006ns，0 route errors，setup仍失败。N halo边界化已通过完整功能门且周期不变；O已通过84次完整exact、全部原probes及新增ready跨reset/unlock探针；454项hash已核对，同源综合18,831 LUT/9,898 FF/93 BRAM/64 DSP，WNS -1.017ns（仅1个setup失败端点）、内部+.632ns；O post-route为18,279 LUT/9,863 FF/93 BRAM/64 DSP、WNS -0.221ns、WHS +0.049ns、0 route errors，setup仍失败。P静态索引FC队列与lane本地merge_valid已通过完整功能门，周期不变；综合18,327 LUT/8,900 FF/93 BRAM/64 DSP，WNS +.106ns、WHS -.155ns；P post-route WNS +.128ns/WHS +.010ns、0route errors；17,239 LUT/8,864 FF/93 BRAM/64 DSP，全部<70%。复位后overwrite-before-read数字不变量已验收，物理BRAM异步控制warning保留；同源sample0活动估算功耗0.613W（Medium），完整窗口能效18.35GOPS/W，初始20目标未过。
P已通过125 MHz同步post-route时序门；同源sample0活动估算为0.613W/18.35GOPS/W（Medium），20GOPS/W初始目标未通过。
它采用 resident weights 和图像流接口，尚未接入 CPU 或外存 response adapter。
FC 输出是带逐通道尺度 ABI 的 INT32 accumulator，不能直接按 raw 值求 argmax。

当前验收表见 [完整网络结果](docs/reports/d4_fullnet_result_20261019.md)（含能效负结果与部署边界）。

开发证据与设计取舍见 [D4 完整网络开发记录](docs/reports/d4_fullnet_development_20261018.md)。
网络条件、数据流、精确值证明与时钟边界见 [D4 硬件结构](docs/d4_fullnet_architecture.md)。

以下为 2026-09-11 冻结检查点，保留为历史对照：

项目以两条严格分离的证据线收尾：

- **C0 frozen control**：当前生产 `cnn_top`/`sw/model` ABI。完整十类推理 10/10 logits exact；no-BP `219,970` cycles、BP+response-2 `268,503`、response-64 `1,902,452`。XC7Z020 8 ns full-top fully routed，WNS/TNS `-0.880/-482.059 ns`、WHS/THS `+0.070/0`；32,295 LUT、45,704 FF、64.5 BRAM tile、151 DSP、vectorless power `0.479 W`。资源门通过，但 setup 和约 `12.19 GOPS/W` 未达目标。
- **D4 mainline**：软件网络冻结为 204,090 参数、11,645,440 semantic MAC、23,290,880 ops；official CIFAR-10 test10k FP32/INT8 top-1 为 `91.63%/91.46%`。retained v6 candidate4 standalone 六项回归 exact，no-BP `24,039` cycles；OOC post-route 为 18,000 LUT、25,133 FF、28 BRAM、145 DSP、`0.406 W`，但 WNS/TNS `-1.028/-1461.586 ns`。D4 尚未完成 full-network logits、真实完整推理周期或 full-top P&R/power。

2026-09-11 的检查点没有达到最终 FPGA 部署目标；新完整 D4 RTL 的功能进展见上文。C0 的 accuracy/MAC/cycles/PPA 不得重标为 D4；standalone/OOC 也不得写成 full-network/full-top。

完整目标仍为 8 ns、WNS/WHS `>=0`、TNS/THS `=0`、完整推理 `<=2,000,000 cycles`、LUT/FF/DSP/BRAM 各严格 `<70%`、DSP `<=153`、post-route estimated power `<=3 W`，以及按真实 D4 ops 计算 `>=20 GOPS/W`。

核心文档：

- [D4 完整网络开发记录](docs/reports/d4_fullnet_development_20261018.md)
- [工程演进与验证报告](docs/project_evolution_20260911.md)
- [权威报告索引](docs/reports/README.md)
- [C0 frozen control 收尾](docs/reports/c0_frozen_control_closeout_20260911.md)
- [D4 最终阶段收尾](docs/reports/edgembconv_hwacandidate_d4_final_stage_closeout_20260911.md)

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `rtl/cnn` | CNN accelerator 主数据面、子模块、控制器和状态计数器 |
| `rtl/cpu_if` | RV32I custom instruction 接口、NPC bridge、MMIO 寄存器接口 |
| `rtl/npc` | NPC/RV32I CPU 工程副本和联合仿真所需 ROM/RAM 生成逻辑 |
| `sw/firmware` | 裸机 C firmware、custom instruction wrapper、MMIO fallback、startup/linker |
| `sw/model` | 当前 C0 production ABI 的 descriptor、量化参数和权重 header |
| `python` | 训练、量化、golden 推理、vector/header 导出、报告生成脚本 |
| `sim` | Verilator/SystemVerilog testbench |
| `tests/vectors` | 单元级和 fullnet 级测试向量 |
| `scripts` | 仿真、模型导出、firmware 构建、报告生成入口 |
| `docs` | 架构、量化、验证计划、已知限制和优化 bring-up 记录 |
| `build` | 已生成的模型、firmware、报告、仿真日志和 Verilator 产物 |

## C0 生产拓扑与 D4 边界

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

上表是当前 C0 `cnn_top` 的 9-layer 生产拓扑。C0 软件质量曾从初始 INT8 47.31% 演进到重新训练 66.16%、BN-fold PTQ 79.23%；QAT INT8 77.61% 是负结果。不同软件 checkpoint 与硬件 run 只有 manifest/hash 同源时才能组合。

D4 是独立 EdgeMBConv 主线，不能通过替换 C0 header 获得。D4 网络图、权重、量化和账本由 [`edgembconv_hwacandidate_d4_promotion_contract_20260909.md`](docs/reports/edgembconv_hwacandidate_d4_promotion_contract_20260909.md) 与 source manifest 固定；`sw/model/model_quant.h` 仍是 C0 ABI。

## 量化格式

两条网络都使用 signed INT8 activation/weight 和 INT32 accumulator/bias。C0 使用其既有 asymmetric activation/zero-point ABI；D4 使用逐输出通道对称权重、nearest-away-from-zero requant 和 signed INT8 saturation。硬件与 Python golden 必须使用同一 manifest。C0 现行公式为：

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

`cnn_top` 是 C0 完整生产/control 路径，由 descriptor 驱动；每层 descriptor 为 32 words / 128B stride。控制器顺序 fetch descriptor，启动对应 engine，等待真实 `layer_done/layer_error`，并通过 status counter 暴露 cycle、当前层、busy/done/error。Stem 使用 3 个复用 INT8 MAC；DS 路径使用 BRAM buffer、DW stream 和 PW 阵列。

D4 retained v6 block/OOC 路径由 controller、scheduler、banked storage/fetch pair、共享 datapath、DW adapter/tile、RQ/pool 和 raw FIFO 组成。新独立 `d4_fullnet_top` 采用共享 16×4 数据面、权重 ROM、三个激活槽和完整算子 descriptor 调度，保持与 retained v6 的对照边界；新 full-top 的物理实现尚未签署。

当前外部 memory 仿真格式仍是“一 int8 element 一 32-bit word，低 8 位有效”。这是为了简化仿真和调试，后续需要改为 packed NHWC byte layout。读端最多一个 outstanding：请求在 ready/valid 握手后，响应可任意延迟但最早下一拍、不能同拍返回；写端没有响应。适配 AXI 或组合 RAM 时必须寄存读响应以保持这一契约。

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
除非命令名或报告明确标注 D4，本节的 legacy export、fullnet 和 firmware
流程均针对当前 C0 production ABI；它们不会生成或验证 D4 deployment。

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

## 当前验证快照

软件、完整网络、standalone 和 OOC 证据必须分开阅读：

```text
C0 frozen fullnet no-BP:  cycles=219970  MACs=5136896  logits=exact
C0 BP + response-2:       cycles=268503  logits=exact
C0 response-64:           cycles=1902452 logits=exact
D4 software:              INT8=91.46%  MACs=11645440  ops=23290880
D4 v6 candidate4 no-BP:  cycles=24039  bytes=8192  words=2048  exact
```

C0 是完整 fullnet/full-top control；D4 candidate4 只是 mb16 standalone/OOC。
D4 功能回归同时覆盖 DW adapter/tile、no-BP、random backpressure、final-word
stall 和 two-epoch，并检查 PW/DW/RQ、request/response 和输出事务守恒。
这些结果不能推出 D4 完整推理周期或能效。

## 资源估算

静态资源估算脚本：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_resource_report.sh
```

输出：

- `build/reports/resource_estimate.md`

历史静态估算摘要：

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

这只是 RTL 参数级历史估算，不能替代实现报告。当前权威物理数据为：

| 快照 | LUT | FF | BRAM | DSP | Power | Timing |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| C0 frozen full-top | 32,295 | 45,704 | 64.5 tile | 151 | 0.479 W | WNS -0.880 ns，WHS +0.070 ns |
| D4 v6 candidate4 OOC | 18,000 | 25,133 | 28 tile | 145 | 0.406 W | WNS -1.028 ns，WHS +0.071 ns |

两者均 fully routed，但 setup 都未闭合；D4 OOC 不能替代 D4 full-top，Vivado vectorless power 也不是板级实测。

## 关键已实现模块

- Python/model: `train_edgedscnet_c10.py`, `quantize_export.py`, `golden_int8.py`, `export_firmware_headers.py`, `generate_test_vectors.py`, `compare_outputs.py`
- Arithmetic: `round_shift.v`, `saturate_int8.v`, `requant_activation_unit.v`, `requant_activation_pipeline.v`
- Stem/DW/PW: `conv3x3_stem_engine_new.v`, `dw_mac_lanes.v`, `dw_tile_fusion_engine_new.v`, `ds_block_tile_engine_new.v`, `pw_systolic_array_8x8.v`
- Tail: `gap_unit_new.v`, `fc_unit_new.v`
- Buffer/SRAM: `feature_sram_bank.v`, `feature_sram_pingpong.v`, `ds_input_tile_buffer_bram.v`, `pw_weight_buffer_bram.v`, `dw_tile_buffer_bram.v`
- Top control: `descriptor_fetch.v`, `cnn_top_ctrl.v`, `cnn_layer_runner.v`, `cnn_top.v`, `status_counter.v`
- CPU IF: `rv_cnn_custom_if.v`, `npc_cnn_custom_bridge.v`, `cnn_mmio_regs.v`
- Firmware: `cnn_accel.h`, `cnn_accel.c`, `main.c`, `startup.S`, `linker.ld`

## Windows XSim 关键回归

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1
```

当前脚本会以 `sim/filelist_cnn_current.f` 编译 CNN RTL，并逐 TB 增量编译。
报告中的具体日期和快照必须以对应报告/日志为准；可复现实验命令和证据边界
见 [`docs/reports/README.md`](docs/reports/README.md) 与
[`docs/verification_plan.md`](docs/verification_plan.md)。

## 已知限制

- 当前是固定网络研究型加速器，不是通用 CNN/NPU。
- C0 完整系统和 D4 高精度主线是两套不同网络身份；当前 production `cnn_top`/header 仍属于 C0。
- 新 D4 独立 top 已有逐层 exact 与完整周期证据；同源 full-top timing/power 尚待验证。
- 外部 memory 仍大量使用 word-per-int8 仿真布局，尚未改成 packed NHWC byte layout。
- C0 full-top 与 D4 OOC 都有 timing-capable XC7Z020 post-route 证据，但 setup 未闭合。
- 板级 I/O、bitstream、CDC/formal、活动率驱动 power 和实测功耗仍未验证。
- 已有 NPC/RV32I 联合仿真 harness，但还不是面向 FPGA 上板的生产级 SoC top。
- 历史报告属于各自日期和 source snapshot；不得用旧数字描述当前源码。

## 当前发布状态与后续工作

2026-09-11 retained 检查点保留为对照；当前开发从新完整 D4 top 的同源快照继续，
保持所有功能/ledger 门，取得 8 ns full-top timing/resources/activity power。
流接口停顿回归不能替代尚未集成的外存 response adapter 验证。
工作频率、每次推理能量与 GOPS/W 均须使用同源物理结果和连续启动间隔。

更多细节见：

- `docs/quantization.md`
- `docs/verification_plan.md`
- `docs/known_limits_next_steps.md`
- `docs/project_evolution_20260911.md`
- `docs/streaming_engine_refactor_guide.md`
- `docs/reports/README.md`
