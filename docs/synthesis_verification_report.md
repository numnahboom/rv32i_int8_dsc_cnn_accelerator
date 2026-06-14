# 综合验证报告

项目：`rv32i_int8_dsc_cnn_accelerator`  
日期：2026-06-14  
目标：对当前 RTL 进行初步 FPGA 综合验证，确认资源量级、综合阻塞点，以及后续优化优先级。

## 1. 验证范围

本次综合验证覆盖两类目标：

1. `cnn_top` 顶层综合尝试  
   用于判断当前完整加速器 RTL 是否已经具备可综合落地条件。

2. 代表性子模块 out-of-context 综合  
   用于获得真实 Vivado 资源量级，避免只依赖静态估算。

已尝试/完成的模块：

| 类型 | Top | 状态 |
| --- | --- | --- |
| Full top | `cnn_top` | 已尝试，卡在 `dw_tile_buffer` RAM 推断 |
| Arithmetic | `requant_activation_unit` | 综合通过 |
| PW compute | `pw_systolic_array_8x8` | 综合通过 |
| DW compute | `dw_mac_lanes` | 综合通过 |
| SRAM wrapper | `feature_sram_bank` | 综合通过，但未推断 BRAM |

## 2. 工具环境

### Vivado

- Tool: Vivado 2021.2
- Path: `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Installed parts:
  - `xck26-sfvc784-2LV-c`
  - `xck26-sfvc784-2LVI-i`
- 本次使用 part: `xck26-sfvc784-2LV-c`
- 综合模式: out-of-context synthesis

### Yosys

Yosys 在当前 Windows PATH 和 WSL PATH 中均未找到，因此没有得到 Yosys 资源结果。

已提供可复现脚本：

```bash
cd /mnt/d/Stuff/Project
./scripts/run_synthesis_yosys.sh
```

## 3. 可复现命令

Vivado 综合脚本：

```powershell
cd D:\Stuff\Project
powershell -ExecutionPolicy Bypass -File scripts\run_synthesis_vivado.ps1 `
  -Vivado D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -Part xck26-sfvc784-2LV-c `
  -Top requant_activation_unit
```

更换 `-Top` 可综合其它模块：

```powershell
-Top pw_systolic_array_8x8
-Top dw_mac_lanes
-Top feature_sram_bank
-Top cnn_top
```

## 4. Vivado 代表模块结果

以下数字来自 Vivado `report_utilization` 的 Site Type 表，而不是手写估算。

| Module | CLB LUTs | CLB Registers | BRAM Tiles | DSPs | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| `requant_activation_unit` | 494 | 294 | 0 | 10 | Q31 乘法映射到 DSP48E2 cascade |
| `pw_systolic_array_8x8` | 5957 | 4098 | 0 | 0 | int8 PE 乘法映射到 LUT/CARRY |
| `dw_mac_lanes` | 9759 | 3367 | 0 | 0 | 16 lane DW MAC 映射到 LUT/CARRY |
| `feature_sram_bank` | 6791 | 9 | 0 | 0 | 32KB bank 被映射为 distributed RAM |

### 4.1 Requant

`requant_activation_unit` 的真实结果说明：

- 单个 requant 单元约使用 10 个 DSP48E2。
- 这是由当前 64-bit signed product / Q31 multiply 表达式导致的。
- 该结果支持之前的架构判断：如果多个 requant 单元并行复制，DSP 压力会明显上升。

后续优化方向：

- 限制 multiplier/accumulator 位宽。
- 将 Q31 multiply 拆成多级流水。
- 在吞吐允许时复用 requant 单元。
- 必要时改为 vendor DSP primitive 或固定格式乘法器。

### 4.2 PW 8x8 Array

`pw_systolic_array_8x8` 的真实结果说明：

- 8x8 阵列没有消耗 DSP。
- Vivado 将 int8 乘法和 int32 累加映射到 LUT/CARRY。
- LUT/FF 量级较高，但保留了 DSP 给 requant 或其它模块使用。

后续优化方向：

- 如果 LUT 紧张，可尝试 `(* use_dsp = "yes" *)` 或 DSP-based PE。
- 如果频率紧张，可优先给 `valid/clear_acc` 和 row/column 数据加寄存复制。
- 目前 8x8 广播式 fanout 在功能上合理，但 timing closure 需要真实 timing-capable part 再确认。

### 4.3 DW MAC Lanes

`dw_mac_lanes` 的真实结果说明：

- 16 lanes × 3 multipliers 的实现没有消耗 DSP。
- LUT 使用量比 PW array 更高，说明 DW lanes 的并行组合逻辑和控制展开仍有优化空间。

后续优化方向：

- 若 DW 吞吐富余，可减少 lanes 或减少每 lane 并行乘法器。
- 若 LUT 紧张，可评估 DSP 映射或 lane 复用。
- 若 timing 紧张，可把 3-cycle row MAC 进一步流水化。

### 4.4 Feature SRAM Bank

`feature_sram_bank` 的真实结果非常关键：

- 32KB bank 没有推断成 BRAM。
- Vivado 报告显示 `5120 LUT as Distributed RAM`。
- BRAM Tiles = 0。

这意味着当前 SRAM wrapper 虽然功能仿真正确，但不是理想 FPGA memory mapping。

后续优化方向：

- 如果目标是 BRAM，应改为显式 BRAM wrapper 或加入更严格的 RAM inference pattern。
- 避免在同一个 always block 中写出工具不易识别的 bypass/读写模式。
- 可针对 Xilinx 使用 `(* ram_style = "block" *)`，但前提是访问模式先满足 BRAM 推断要求。

## 5. cnn_top 综合尝试

`cnn_top` 已用 Vivado 2021.2 启动真实综合。综合流程进入以下模块：

- `cnn_top`
- `cnn_top_ctrl`
- `descriptor_fetch`
- `cnn_layer_runner`
- `conv3x3_stem_engine`
- `ds_block_tile_engine`
- `dw_tile_fusion_engine`
- `dw_mac_lanes`
- `dw_tile_buffer`

在 `dw_tile_buffer` 处 Vivado 输出关键 warning：

```text
WARNING: [Synth 8-5856] 3D RAM bank_mem_reg for this pattern/configuration is not supported. This will most likely be implemented in registers
```

随后综合长时间无进一步日志进展，最终手动停止。

结论：

当前 `cnn_top` 不是“完全不可综合”，而是被 `dw_tile_buffer` 的 3D RAM 写法阻塞。若继续让 Vivado 展开，很可能得到极大的寄存器网络，资源数字也没有参考价值。

## 6. Timing 限制

当前安装的 K26 part 在 timing report 阶段报：

```text
ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device
```

因此本报告只包含 synthesis utilization，不包含：

- WNS/TNS
- Fmax
- post-place-and-route timing
- routed utilization

若要获得最终 timing，需要：

1. 安装 timing-capable device support / board part。
2. 加入真实 XDC 约束。
3. 运行 `synth_design -> opt_design -> place_design -> route_design -> report_timing_summary`。

## 7. 与静态估算的对照

静态估算报告曾指出：

| 风险项 | 静态判断 | Vivado 验证结果 |
| --- | --- | --- |
| Wide requant multiplier | 可能消耗较多 DSP | 单个 requant = 10 DSP |
| Feature SRAM A/B | 期望 BRAM | 当前 bank 映射为 LUTRAM |
| DW tile buffer | banked BRAM/LUTRAM intended | 3D RAM pattern 不支持 |
| PW/DW int8 MAC | conservative DSP risk | 当前映射为 LUT/CARRY，DSP=0 |

因此静态估算方向基本成立，但 Vivado 给出了更明确的优化优先级：

1. 先修 memory inference。
2. 再处理 requant DSP 压力。
3. 最后根据 timing 决定 PW/DW 是否 DSP 化或流水化。

## 8. 结论

当前 RTL 功能验证已经形成闭环，但综合验证表明还需要一次“FPGA memory pass”。

已确认：

- Vivado 2021.2 可以读取并综合代表性 RTL 模块。
- `requant_activation_unit`、`pw_systolic_array_8x8`、`dw_mac_lanes`、`feature_sram_bank` 均可 OOC synthesis。
- `requant` 的 DSP 成本真实存在。
- PW/DW MAC 当前主要消耗 LUT/FF。
- 当前 SRAM/tile buffer 写法不适合直接作为最终 FPGA memory 实现。

未完成：

- `cnn_top` full synthesis 完整资源报告。
- timing closure。
- BRAM inference / vendor RAM wrapper。
- post-route utilization。

## 9. 下一步计划

优先级从高到低：

1. 重写 `dw_tile_buffer`
   - 避免 3D RAM。
   - 改成显式 16 bank module。
   - 每个 bank 使用 1D memory。
   - 保持当前 testbench 全部通过。

2. 重写或包装 `feature_sram_bank`
   - 明确目标是 BRAM 还是 LUTRAM。
   - 若目标 BRAM，使用 Xilinx-friendly 1RW RAM pattern 或 `xpm_memory`。

3. 重新跑 `cnn_top` Vivado synthesis
   - 确认不再卡在 memory inference。
   - 记录 full top LUT/FF/BRAM/DSP。

4. 获取 timing-capable part 或完整器件库
   - 跑 timing summary。
   - 再决定是否需要异步时钟、requant 深流水、PW 控制复制。

5. 更新 PPT 和 README
   - 将 full top synthesis 数字替换当前 representative module 数字。

## 10. 相关文件

- `docs/synthesis_vivado_summary.md`
- `docs/synthesis_vivado_initial.md`
- `docs/synthesis_vivado_requant_activation_unit.md`
- `docs/synthesis_vivado_pw_systolic_array_8x8.md`
- `docs/synthesis_vivado_dw_mac_lanes.md`
- `docs/synthesis_vivado_feature_sram_bank.md`
- `docs/synthesis_initial.md`
- `build/reports/resource_estimate.md`
- `scripts/run_synthesis_vivado.ps1`
- `scripts/vivado_cnn_top_synth.tcl`
- `scripts/run_synthesis_yosys.sh`

