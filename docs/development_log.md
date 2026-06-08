# 开发日志

项目：`rv32i_int8_dsc_cnn_accelerator`

本日志用于记录每一轮推进、遇到的问题、验证结果，以及暂不影响当前验证但值得后续优化的事项。当前基线日期：2026-06-04。

## 当前验证基线

- `tb_npc_cnn_custom_bridge`: PASS
- `tb_npc_bridge_cnn_top_fullnet`: PASS, `hw_cycles=1085562`, `status=10907a82`, `checks=10`
- `tb_npc_rv_core_cnn_top_fullnet`: PASS, `cycles=1085562`, `status=10907a82`, `start_count=1`, `stat_count=1`, `argmax=0`
- `SIM_ONLY=tb_npc_rv_core_cnn_top_fullnet ./scripts/run_all_sims.sh`: PASS, summary 写入 `build/reports/sim_logs/summary.csv`
- `scripts/export_model.sh`: PASS, 当前 training smoke golden logits 为 `[-2, -3, -3, -2, -2, -2, -2, -3, -2, -3]`, argmax 为 `0`

说明：`tb_cnn_top_fullnet_sram_datapath` 使用 `python/generate_test_vectors.py` 生成的 fullnet SRAM smoke case，历史报告中 argmax 为 `2`。CPU firmware 联合仿真使用 `sw/model` 和 `tests/vectors/training_smoke` 导出的训练 smoke 模型，当前 argmax 为 `0`。两者是不同 golden 来源，不能直接混用。

## 推进记录

### 1. 项目结构与基础文档

- 建立 `rtl/`, `sim/`, `sw/`, `python/`, `tests/`, `scripts/`, `docs/` 目录。
- 补齐 README、网络结构、量化规格、自定义指令、验证计划等说明。
- 约定 RTL 均使用 `.v` 文件，descriptor 为 32 words / 128B stride。

验证标准：

- 目录结构满足项目规格。
- README 能说明当前已实现模块、运行仿真方式、已知限制。

### 2. Python golden 与测试向量

- 实现 `python/golden_int8.py` 和 `python/generate_test_vectors.py`。
- 覆盖 requant、PW matmul、DW tile、Stem、GAP、FC、`cnn_top` 多层 smoke 和 fullnet SRAM case。
- `quantize_export.py` 和 `export_firmware_headers.py` 生成 firmware 使用的 smoke 参数头文件。

遇到的问题：

- fullnet SRAM case 和 training smoke model 是两套不同 golden，需要在文档与 testbench 中明确区分。

验证标准：

- Python golden 能生成逐模块和 fullnet 所需 hex。
- `compare_outputs.py` 对相同 logits 输出 PASS。

### 3. 基础量化与算术模块

- 实现 `round_shift.v`, `saturate_int8.v`, `requant_activation_unit.v`。
- `requant_activation_unit.v` 当前采用 Q31 multiplier：先做 64-bit product，再 round-shift 31 位，随后按 `shift` 算术右移。
- 负数 rounding 已按 round-half-away-from-zero 修正。

遇到的问题：

- 量化 helper 在多个模块内以内联函数重复实现，和 `rtl/common` 模块存在一定重复。
- 第二次缩放目前只支持右移；若未来导出的量化参数需要负 shift，应补左移语义。

验证标准：

- `tb_requant_activation_unit` 与 Python golden 对齐。

### 4. PW 8x8 systolic array

- 实现 `systolic_pe.v` 和 `pw_systolic_array_8x8.v`。
- 支持 `clear_acc`, `k_valid`, `k_last`, 输出 8x8 int32 psum。

验证标准：

- `tb_pw_systolic_array_8x8` 与 Python 8xK x Kx8 matmul golden 对齐。

### 5. DW tile fusion

- 实现 `dw_line_buffer.v`, `dw_window_generator.v`, `dw_mac_lanes.v`, `dw_tile_buffer.v`, `dw_tile_fusion_engine.v`。
- DW 输出只写入 tile buffer，不写回外部 memory。
- 支持 stride 1、stride 2、padding zero point、多 channel smoke。

遇到的问题：

- DW 子模块目前主要由 engine 控制节拍，内部没有全面 ready/valid 解耦。当前仿真可验证，但后续若要接真实 DMA/stream backpressure，建议补充 ready/valid。

验证标准：

- `tb_dw_tile_fusion_engine` PASS。
- DSBlock tile 集成后保持 DW 中间结果不写回外部 memory。

### 6. Stem、GAP、FC

- 实现 `conv3x3_stem_engine.v`, `gap_unit.v`, `fc_unit.v`。
- Stem 支持 32x32x3 -> 32x32x16 tiled execution。
- GAP 对 4x4x256 求平均，FC 输出 10 个 int8 logits。

验证标准：

- `tb_conv3x3_stem_engine`, `tb_gap_unit`, `tb_fc_unit` PASS。

### 7. Tile scheduler、Feature SRAM 与状态计数

- 实现 `tile_scheduler.v`，支持 fixed 8x8 tile、stride 1/2 same-padding 输出 tile 调度。
- 实现 `feature_sram_bank.v` 和 `feature_sram_pingpong.v`，用于层间 A/B SRAM ping-pong。
- 实现 `status_counter.v`，`status[31:8]` 保存 cycle count，`status[7:4]` 保存 current layer。

验证标准：

- `tb_tile_scheduler`, `tb_feature_sram_bank`, `tb_feature_sram_pingpong` PASS。

### 8. cnn_top v1 数据面

- 新增 `cnn_layer_runner.v`。
- `cnn_top_ctrl.v` 从固定 latency skeleton 改成等待真实 `layer_runner_done`。
- `cnn_top.v` 支持 descriptor fetch、payload load、engine start/wait、output store。
- 支持 `OP_CONV3X3_STEM`, `OP_DS_BLOCK`, `OP_GAP`, `OP_FC`。
- v1 外部 memory 格式为 word-per-int8：每个 int8 element 写入 32-bit word 的低 8 位。

遇到的问题：

- 最初 `cnn_top` 只是一层 descriptor/status skeleton，无法验证真实计算。通过 `cnn_layer_runner` 将 engine 接入顶层后才形成可闭环数据面。
- fullnet smoke 的输出写回与 packed NHWC byte layout 不同，当前为了仿真可读性使用 word-per-int8。

验证标准：

- `tb_cnn_top_*_datapath` 系列 PASS。
- `tb_cnn_top_fullnet_sram_datapath` PASS，并输出 inference/perf report。

### 9. Firmware 与模型导出

- `sw/firmware/cnn_accel.h/.c` 支持 custom instruction wrapper 和 MMIO fallback。
- `main.c` 初始化 exported smoke payload，构造 9 层 descriptor，执行 `cnn.start`，poll done，读取 logits 并 argmax。
- `scripts/build_firmware.sh` 构建 RV32I firmware。
- `scripts/build_firmware_rom.sh` 将 firmware binary 转为 little-endian word `rom.hex`，供 CPU 联合仿真加载。

遇到的问题：

- Firmware 中 packed int8 常量在 ROM，运行时展开到 RAM 中的 word-per-int8 buffer。联合仿真 memory model 必须同时支持 ROM 和 RAM 读。

验证标准：

- `scripts/build_firmware_rom.sh` 能生成 `build/firmware/rom.hex`。

### 10. Custom IF、MMIO 与 NPC bridge

- `rv_cnn_custom_if.v` 支持 `cnn.start`, `cnn.poll`, `cnn.stat`。
- `cnn_mmio_regs.v` 支持 DESC_BASE、LAYER_NUM、CMD、STATUS、STAT。
- `npc_cnn_custom_bridge.v` 适配 NPC `rv_core` 现有 custom port。
- `cnn.stat` / MMIO `STAT` 返回 `{8'd0, acc_status[31:8]}`，与硬件 status 中 cycle counter 保持一致。

验证标准：

- `tb_rv_cnn_custom_if`, `tb_rv_custom_if_cnn_top_fullnet`, `tb_cnn_mmio_regs`, `tb_mmio_cnn_top_fullnet`, `tb_npc_cnn_custom_bridge`, `tb_npc_bridge_cnn_top_fullnet` PASS。

### 11. 复制 NPC 源码到 Project 并接入 rv_core 联合仿真

- 将 `D:\Stuff\npc` 中必要源码复制到 `Project/rtl/npc`。
- 保留 `rtl/npc/vsrc/soc_top.v` 作为参考，不修改原工程 `D:\Stuff\npc`。
- `sim/filelist.f` 加入 Project 内 NPC `rv_core` 依赖模块，避免引入 legacy NPC CNN 模块以免命名冲突。
- `scripts/run_sim.sh` 加入 NPC include path。
- 新增 `sim/tb_npc_rv_core_cnn_top_fullnet.v`：
  - 实例化 `rtl/npc/vsrc/rv_core.v`
  - 连接 `npc_cnn_custom_bridge -> cnn_top`
  - 使用统一 testbench RAM/ROM model
  - CPU 从 ROM 取指，CPU data bus 可读 ROM/RAM
  - `cnn_top` memory bus 低地址读 ROM，高地址读 RAM，写回 RAM
  - 验证 CPU 发出 custom start、`cnn_top` done、CPU 发出 `cnn.stat`、logits 与 training smoke golden 一致

遇到的问题：

- 首次 CPU 联合仿真能启动并完成，但 logits 为 `[-2, -2, -2, -2, -2, -2, -2, -2, -2, -2]`，和 training smoke golden 有 4 个通道相差 1。
- 定位后发现 testbench 中 `cnn_top` memory read 只连到了 RAM；而 firmware descriptor 中 FC bias/mul/shift 等常量地址位于 ROM 低地址。加速器读 ROM 常量时读到了 0，导致输出退化为 FC output zero point。
- 修复方式：`tb_npc_rv_core_cnn_top_fullnet.v` 中 `cnn_top` read path 改为 `mem_req_addr[31] ? ram[...] : rom[...]`。

验证标准：

- `./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet` PASS：
  - `cycles=1085562`
  - `status=10907a82`
  - `start_count=1`
  - `stat_count=1`
  - `argmax=0`
- `SIM_ONLY=tb_npc_rv_core_cnn_top_fullnet ./scripts/run_all_sims.sh` PASS。

## 当前不影响验证的待优化项

这些事项不阻塞当前 smoke 验证，可以作为后续手动优化入口。

1. Requant 乘法器资源
   - `requant_activation_unit.v` 和部分 engine 内部使用 64-bit product。
   - 可考虑按 engine 共享 multiplier，或将 requant 改成多周期流水。
   - 若 FPGA DSP 紧张，优先评估 Q31 multiplier 的复用策略。

2. Requant 第二次缩放
   - 当前 `shift` 只实现算术右移。
   - 若后续 PTQ/QAT 导出负 shift，需要支持左移，并同步 Python golden。

3. Requant/Clamp 代码复用
   - `round_shift` 和 `saturate/clamp` 逻辑在多个模块中以内联函数重复实现。
   - 可统一成 common 模块或 include 风格 helper，但需要确保 Verilator 与综合工具都容易接受。

4. DW ready/valid
   - 当前 DW 子模块由 top engine 固定节拍驱动。
   - 若接真实 DMA、异步 SRAM 或上游 backpressure，需要补 ready/valid。

5. Storage 与 SRAM inference
   - 当前不少 staging buffer 是 packed reg 或大数组。
   - 后续可重构为明确 SRAM/BRAM 推断结构，减少 FF 风险。

6. 外部 memory layout
   - v1 为仿真友好，采用 word-per-int8。
   - 后续 full-network memory pass 应改为 packed NHWC byte layout，减少 bandwidth。

7. Verilator warning
   - `tb_npc_rv_core_cnn_top_fullnet.v:178` 有 `BLKSEQ` warning，来自 testbench task 中的 blocking assignment。
   - 不影响当前 PASS，可后续清理 warning 或添加局部 lint pragma。

8. SoC 顶层接线
   - 当前 CPU 联合仿真直接实例化 `rv_core`，未替换 `rtl/npc/vsrc/soc_top.v` 中 legacy accelerator。
   - 后续可在 Project 内 NPC 副本上做 SoC-level integration。

9. 模型精度
   - 当前 training smoke 只证明训练/导出/firmware/header/golden/RTL 链路可跑通。
   - 后续若要做 CIFAR-10 精度验收，需要正式 PTQ/QAT、更多样本和 accuracy report。

10. 综合资源
    - 当前资源报告是静态估算，不是 Vivado/Yosys post-synthesis。
    - 后续可加入 FPGA 综合脚本，记录 LUT/FF/BRAM/DSP。

## Git 管理约定

- Project 使用独立 git 仓库：`D:\Stuff\Project`。
- 生成物不纳入 git：`build/`, `obj_dir/`, `logs/`, `*.elf`, `*.bin`, `*.fst`, `*.vcd`。
- 建议每完成一个可验证阶段提交一次：

```bash
git status
git add .
git commit -m "描述本阶段可验证改动"
```

- 提交前至少跑本阶段相关 smoke；涉及公共接口时跑 `scripts/run_all_sims.sh` 的 `SIM_ONLY` 或 `SIM_FROM/SIM_TO` 切片。

## 2026-06-08：DW tile buffer 多 lane 写入优化

目标：

- 回应 DW/PW 吞吐分析中的一个实际瓶颈：`dw_mac_lanes` 每 3 cycle 产出最多 16 个 channel 的 DW 结果，但旧版 `dw_tile_buffer` 每 cycle 只能写 1 个 int8，导致 DW 阶段额外花 `pixel_count * Cin` 个周期把结果逐字节搬进 tile buffer。

实现：

- `dw_tile_fusion_engine.v` 将原来的单点写接口改为 lane vector 写接口：
  - `buf_wr_en_vec[15:0]`
  - `buf_wr_pixel_idx`
  - `buf_wr_channel_base`
  - `buf_wr_data_vec[16*8-1:0]`
- `dw_tile_buffer.v` 增加 `WRITE_LANES` 参数，默认 16，并在同一 cycle 写入 `channel_base + lane` 对应的多个 channel。
- `ds_block_tile_engine.v` 与 `tb_dw_tile_fusion_engine.v` 同步接入新接口。

验证：

- `./scripts/run_sim.sh tb_dw_tile_fusion_engine` PASS：
  - `cases=3`
  - `checks=832`
- `./scripts/run_sim.sh tb_ds_block_tile_engine` PASS：
  - `cases=3`
  - `checks=1792`
- `./scripts/run_sim.sh tb_cnn_top_sram_tiled_dsblock_datapath` PASS：
  - `cases=1`
  - `checks=480`
- `./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath` PASS：
  - `hw_cycles=1033722`
  - `checks=10`
  - `errors=0`
- `./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet` PASS：
  - `cycles=1033722`
  - `status=0fc5fa82`
  - `start_count=1`
  - `stat_count=1`
  - `argmax=0`

效果：

- 旧 fullnet SRAM datapath smoke 记录约为 `1085562` cycles。
- 本次优化后同类 fullnet SRAM datapath smoke 为 `1033722` cycles。
- smoke case 下降约 `51840` cycles，约 `4.8%`，符合“去掉 DW tile buffer 单字节写入等待”的预期。

保留问题：

- 当前 `dw_tile_buffer` 的多 lane 写是行为级 RTL，适合验证吞吐与功能，但直接综合可能推导出多写口寄存器堆，资源不经济。
- 后续真正 FPGA 化时建议把 DW tile buffer 改成 channel-banked SRAM/BRAM：例如 16 个 bank，每个 lane 写对应 bank，PW 读取时再按 channel/pixel 组织读口。
- `ProjectRecreat/rtl/cnn/requant_activation_unit.v` 中的 16x16 partial product/pipeline 思路有参考价值，但接口、握手和现有 Project requant 不一致，本轮未迁移。

## 2026-06-08：DW tile buffer 改为 channel-banked 结构

目标：

- 收掉上一阶段留下的综合风险：16-lane 写接口如果仍落在单个大 `mem[0:8191]` 行为数组上，综合工具可能无法推导经济的 SRAM/BRAM 结构。
- 保持外部接口与已验证调度完全不变，只调整 `dw_tile_buffer.v` 内部存储组织。

实现：

- `dw_tile_buffer.v` 内部从单数组改为 16 个 bank：
  - `BANKS = 16`
  - `BANK_DEPTH = 512`
  - 总容量仍为 `16 * 512 = 8192` bytes
- 写地址映射：
  - `bank = channel[3:0]`
  - `addr = {pixel_idx, channel[6:4]}`
  - 对连续 16 channel 的 lane vector 写入，每个 lane 正好落入不同 bank。
- 读地址映射：
  - PW 每次读取同一 channel 的 8 个 pixel。
  - `bank = rd_channel_idx[3:0]`
  - 每个 pixel 读同一 bank 中的 `{pixel, rd_channel_idx[6:4]}`。
- SRAM 内容不再在 reset 中逐项清零；只复位 `rd_data_vector`。仿真初值保留在 `ifndef SYNTHESIS` initial block 中，降低综合时被 reset loop 推成 FF 的风险。
- `python/resource_estimate.py` 同步更新 DW tile buffer 说明为 `banked BRAM/LUTRAM intended`。

验证：

- `./scripts/run_sim.sh tb_dw_tile_fusion_engine` PASS：
  - `cases=3`
  - `checks=832`
- `./scripts/run_sim.sh tb_ds_block_tile_engine` PASS：
  - `cases=3`
  - `checks=1792`
- `./scripts/run_sim.sh tb_cnn_top_sram_tiled_dsblock_datapath` PASS：
  - `cases=1`
  - `checks=480`
- `./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath` PASS：
  - `hw_cycles=1033722`
  - `checks=10`
  - `errors=0`
- `./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet` PASS：
  - `cycles=1033722`
  - `status=0fc5fa82`
  - `start_count=1`
  - `stat_count=1`
  - `argmax=0`

保留问题：

- 该结构已经比单大数组多写口更接近硬件实现，但是否映射为目标 FPGA 的最佳 BRAM/LUTRAM 仍需 Vivado/Yosys 综合确认。
- 后续可按目标器件添加局部 memory style pragma，或把每个 bank 拆成显式小 SRAM wrapper。
