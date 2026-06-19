# 项目后续优化、上板验证与说服力补强指南

日期：2026-06-16

本文档用于回答三个核心问题：

1. 当前项目综合成本为什么昂贵，面积、能耗、效率方面应该如何改进。
2. 项目还缺哪些能显著增强说服力的材料、实验和报告，并按“含金量/时间”排序。
3. 从当前代码到 FPGA 上板验证还缺哪些步骤，以及你应该如何着手实现。

本文不把“马上优化到最优”作为目标，而是给出一条从当前 synthesis-proof RTL 逐步走向 FPGA-friendly RTL 的路线。

## 1. 当前状态快照

当前项目已经具备较完整的功能验证闭环：

- Python int8 golden model 已能输出逐层/最终 logits。
- Verilator 曾完成多类模块级与 CPU 联合仿真。
- RV32I custom instruction 到 `cnn_top` 的控制路径已经打通。
- Vivado 2021.2 已能对多个代表模块做 OOC synthesis。

当前综合侧的最新状态：

| 模块 | 状态 | 主要观察 |
| --- | --- | --- |
| `requant_activation_unit` | OOC PASS | Q31 乘法映射到 DSP，单元约 10 DSP |
| `pw_systolic_array_8x8` | OOC PASS | 8x8 int8 PE 目前映射到 LUT/CARRY |
| `dw_mac_lanes` | OOC PASS | 16 lane DW MAC 映射到 LUT/CARRY |
| `feature_sram_bank` | OOC PASS | 当前映射为 LUTRAM，不是 BRAM |
| `dw_tile_buffer` | OOC PASS | 3D RAM 阻塞已修复，但 LUT/LUTRAM 成本高 |
| `dw_tile_fusion_engine` | OOC PASS | synthesis-proof staging 后可综合，但成本很高 |
| `ds_block_tile_engine` | OOC PASS | DW+PW 核心数据面可综合，但成本很高 |
| `cnn_top` | INCOMPLETE | full top 仍因 `cnn_layer_runner` 的 packed payload buffer 过大而无法在本机 1 小时内完成 |

非常重要的判断：

当前昂贵资源成本不是算法本身不可做，而是 v1 RTL 大量使用了“仿真友好”的 packed vector、动态 part-select、临时 staging shift register。这些写法对 Verilator 很方便，但对 FPGA synthesis 很不友好。

## 2. 昂贵资源成本来源与优化方向

### 2.1 `cnn_layer_runner` 的 packed payload vector

当前问题：

- `cnn_layer_runner` 内部持有大 packed vector，例如 `ds_input_tile`、`pw_weight`、`gap_feature_in`、`fc_weight`。
- 对这些 packed vector 做动态下标写入或传给下级模块，会让 Vivado 展开成巨大的 mux、fanout 和寄存器网络。
- full `cnn_top` 不能快速综合完成，主要就是卡在这类结构。

面积影响：

- 巨大的 mux tree 会消耗大量 LUT。
- packed vector 若无法推断 RAM，容易被展开成 FF 或 LUTRAM。
- 层级之间传递几十万 bit 的端口会导致大 pin count 和极慢综合。

能耗影响：

- 大 mux 和宽总线在每次状态切换时可能产生大量无效翻转。
- FF/LUTRAM 替代 BRAM 会显著增加动态功耗和布线功耗。

效率影响：

- 数据虽然在逻辑上是 tile buffer，但实际结构不是高效 SRAM。
- 综合和布局布线时间长，时序也更难收敛。

推荐改法：

1. 把 `cnn_layer_runner` 改成 loader + SRAM/buffer interface。
2. 不再把完整 input tile / weight tile 作为 packed vector 传给 engine。
3. engine 通过地址读取本地 buffer 或共享 SRAM，而不是接收超宽 port。
4. 对每类 payload 建立独立小 memory：
   - `ds_input_tile_mem`
   - `dw_weight_mem`
   - `pw_weight_mem`
   - `bias_mem`
   - `mul_shift_mem`
5. 每个 memory 用 1D array 或 Xilinx XPM wrapper 表达，接口固定为同步读/写。

验收标准：

- `cnn_layer_runner` 不再包含大于约 32K bit 的 packed payload reg。
- `cnn_top` front-end synthesis 不再出现 `large pin count` 级别的 payload warning。
- OOC `cnn_layer_runner` 能在可接受时间内完成 synthesis。

### 2.2 synthesis-proof staging shift register

当前问题：

- 为了先让 `dw_tile_fusion_engine` 和 `ds_block_tile_engine` 可综合，临时加入了串行 staging：
  - `dw_tile_fusion_engine` 把 packed input tile shift 到 byte memory。
  - `ds_block_tile_engine` 把 packed PW weight shift 到 byte memory。
- 这解决了 Vivado 内部错误，但带来极高 FF 成本。

面积影响：

- `dw_tile_fusion_engine` OOC 已明显超出 K26 可用资源。
- `ds_block_tile_engine` OOC 更大，只能作为“Vivado 接受该 RTL”的证明。

能耗影响：

- 大 shift register 每个 load 周期都在翻转大量寄存器，能耗很差。
- 数据搬移不是按 memory port 局部访问，而是宽寄存器整体移动。

效率影响：

- 每个 tile 开始前增加很长 staging 时间。
- staging 不贡献 MAC，降低有效 compute utilization。

推荐改法：

1. 去掉 synthesis-proof shift register。
2. 让上级 loader 直接按地址写入 engine-local SRAM。
3. DW engine 按 `(iy, ix, c)` 地址读 `input_tile_mem`。
4. PW engine 按 `(cout, cin)` 地址读 `pw_weight_mem`。
5. 对仿真保留同样 memory load 流程，而不是继续使用 packed vector 快捷路径。

验收标准：

- `dw_tile_fusion_engine` 和 `ds_block_tile_engine` 不再拥有几十万 bit 的 shift register。
- OOC synthesis 仍 PASS。
- 资源显著下降，至少不再超过目标 FPGA 总资源。

### 2.3 `feature_sram_bank` 未推断 BRAM

当前问题：

- 32KB feature SRAM bank 当前映射为 LUTRAM。
- 这与“Feature SRAM A/B 32KB ping-pong”的设计初衷不一致。

面积影响：

- LUTRAM 会吃掉大量 LUT，抢走计算逻辑资源。
- BRAM 资源未被有效利用。

能耗影响：

- 大容量 LUTRAM 通常比 BRAM 更分散，布线和翻转功耗更高。

效率影响：

- 若后续需要多端口访问，LUTRAM 复制会迅速放大资源。

推荐改法：

1. 使用 Xilinx-friendly simple dual-port RAM pattern。
2. 或直接用 `xpm_memory_sdpram` / `xpm_memory_tdpram`。
3. 明确读延迟，例如同步读 1 cycle。
4. 修改依赖它的模块，使其接受同步读延迟。

推荐 wrapper 方向：

```verilog
module simple_sdp_bram #(
    parameter ADDR_WIDTH = 15,
    parameter DATA_WIDTH = 8
) (
    input  wire clk,
    input  wire wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data
);
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    always @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            rd_data <= mem[rd_addr];
        end
    end
endmodule
```

验收标准：

- Vivado `report_utilization` 中 `Block RAM Tile > 0`。
- `LUT as Distributed RAM` 明显下降。
- 原功能仿真全部通过。

### 2.4 `dw_tile_buffer` 多读需求导致 LUTRAM/bank 成本高

当前问题：

- PW 每次读取 8 pixels × 1 channel 的 activation vector。
- 为了同时读 8 个 pixel，当前显式分成很多 bank。
- 这解决了 3D RAM 不可综合问题，但会消耗较多 LUT/LUTRAM。

面积影响：

- `dw_tile_buffer` 当前 OOC 约 46k CLB LUT，BRAM=0。

能耗影响：

- 多 bank LUTRAM 分散，功耗和布线压力较高。

效率影响：

- 当前结构能满足 PW 读取形态，但不是最省资源。

可选优化路线：

1. 保持 8-pixel 并行读，用 banked LUTRAM，接受面积成本。
2. 改成 BRAM 双 buffer，但降低每 cycle 读宽，需要 PW feed 多 cycle 组包。
3. 改变 DW tile buffer layout，使 PW 读取更自然：
   - pixel-major：利于 PW 读 pixels。
   - channel-major：利于 DW 写 channels。
4. 做两个小 buffer：
   - DW write buffer 按 channel-friendly。
   - PW read buffer 按 pixel-friendly。
   这会增加搬运，但能改善端口匹配。

推荐第一步：

- 不急着大改 layout。
- 先把 `cnn_layer_runner` 和 `feature_sram_bank` 修成 memory-oriented。
- 等 full top 能综合后，再根据真实资源瓶颈决定是否优化 `dw_tile_buffer`。

### 2.5 requant 乘法器成本

当前问题：

- `requant_activation_unit` 的 Q31 fixed-point multiply 使用 64-bit product。
- Vivado 映射到 DSP48E2 cascade，单个 requant 单元约 10 DSP。

面积影响：

- 如果每个 lane 或每个输出通道复制 requant，会很快吃满 DSP。

能耗影响：

- DSP cascade 动态功耗不低。
- 若组合路径很长，可能导致低频或额外 pipeline。

效率影响：

- 如果 requant 不流水，会成为 MAC 后处理瓶颈。
- 如果过度复制，会造成 DSP 利用率低但资源占用高。

推荐改法：

1. 先保持 bit-exact，不急着改算法。
2. 加入一个共享 requant pipeline：
   - input valid/ready
   - acc + bias
   - Q31 multiply
   - shift + zero point
   - saturate + clamp
   - output valid
3. 在 DW/PW/FC 中复用该 pipeline，而不是到处复制函数。
4. 若吞吐不够，再增加 2 路或 4 路 requant lane。

验收标准：

- Python golden 与 RTL requant 完全一致。
- `requant_activation_unit` 有明确 pipeline latency。
- 顶层通过 valid/ready 或 fixed-latency schedule 消费结果。
- DSP 使用量可控，并且写入资源报告。

### 2.6 PW systolic array 的广播 fanout

当前问题：

- 当前 8x8 PW array 已取消传统数据流动，使用较直接的输入分发。
- 这在功能上简单，但可能带来 `act_vec`、`wgt_vec`、`clear_acc`、`valid` 的高 fanout。

面积影响：

- synthesis 可能插入复制逻辑。

能耗影响：

- 高 fanout net 翻转会带来明显动态功耗。

效率影响：

- 若 fanout 限制 Fmax，实际吞吐会低于预期。

推荐改法：

1. 等拿到 timing-capable part 的 timing report 后再决定。
2. 若 PW array 在 critical path 上，加入寄存器复制：
   - row-wise act register
   - column-wise weight register
   - per-row/per-column valid register
3. 不要一开始就改回复杂 systolic 数据流，先用最小寄存复制解决 fanout。

验收标准：

- timing report 中 PW 相关高 fanout path 消失或降低。
- 功能仿真 bit-exact。
- 资源增加可解释。

### 2.7 Word-per-int8 外部 memory layout

当前问题：

- v1 仿真中很多 output 采用每个 int8 写一个 32-bit word 的低 8 位。
- 这很适合调试，但外部带宽和存储都是 4 倍浪费。

面积影响：

- 地址生成和 memory 容量都不够真实。

能耗影响：

- 多 4 倍 memory transaction，能耗偏高。

效率影响：

- 外部 memory 带宽效率低，不利于真实性能评估。

推荐改法：

1. 保持当前 layout 作为 debug mode。
2. 新增 packed NHWC mode：
   - 4 个 int8 打包到一个 32-bit word。
   - 支持 byte lane select。
   - input/output/weight loader 做对齐处理。
3. 所有报告中明确区分 debug layout 和 packed layout。

验收标准：

- packed mode 与 Python golden 完全一致。
- 外部 memory traffic 报告下降接近 4 倍。

## 3. 按含金量/时间排序的后续行动

评分说明：

- 含金量：对项目说服力、可展示性、技术闭环的提升。
- 时间：预计完成时间，越短越好。
- 性价比：综合考虑含金量和时间，5 最高。

| 优先级 | 行动 | 含金量 | 时间估计 | 性价比 | 验收标准 |
| --- | --- | ---: | --- | ---: | --- |
| P0 | 恢复 Verilator/WSL 环境并重跑核心回归 | 5 | 0.5 天 | 5 | `run_all_sims.sh` 或关键 TB PASS |
| P0 | 给当前 synthesis-proof 改动补功能回归 | 5 | 0.5 天 | 5 | DW/DSBlock/fullnet logits 与 golden 一致 |
| P0 | 将 `cnn_layer_runner` packed payload 改成 SRAM/loader 接口 | 5 | 2-4 天 | 5 | full `cnn_top` OOC synthesis 能完成 |
| P0 | 把 `feature_sram_bank` 改为 BRAM/XPM wrapper | 5 | 1-2 天 | 5 | BRAM Tile > 0，功能回归 PASS |
| P1 | 生成 full top synthesis utilization 报告 | 5 | 0.5-1 天 | 5 | 有 LUT/FF/BRAM/DSP 汇总表 |
| P1 | 做每层 cycle breakdown 表 | 4 | 0.5 天 | 5 | README/报告中列出每层 cycles |
| P1 | 做 Python golden vs RTL 多样本 logits compare 表 | 5 | 0.5-1 天 | 5 | 至少 10 个样本逐元素一致 |
| P1 | 做 RV32I software baseline cycle 估算 | 5 | 1 天 | 5 | 给出 CPU-only cycles 与加速比 |
| P1 | 补一张 memory traffic 图 | 4 | 0.5 天 | 4 | 每层 external read/write bytes |
| P1 | 补一张 roofline/utilization 图 | 4 | 0.5-1 天 | 4 | MAC/cycle、array utilization 可视化 |
| P1 | 获取 timing-capable part 或完整器件支持 | 5 | 0.5-1 天 | 4 | 能输出 WNS/TNS/Fmax |
| P2 | requant pipeline/shared unit | 4 | 1-2 天 | 4 | DSP 使用下降或时序改善 |
| P2 | DW/DSBlock staging 改成 BRAM-backed loader | 5 | 2-4 天 | 4 | OOC 资源降到可放入目标 FPGA |
| P2 | PW fanout register replication | 3 | 1 天 | 3 | high fanout path 减少，功能不变 |
| P2 | packed NHWC byte layout | 4 | 2-4 天 | 3 | memory traffic 接近下降 4 倍 |
| P2 | Vivado power report | 4 | 1-2 天 | 3 | 有静态/动态功耗估计 |
| P3 | QAT/calibration 提升 int8 准确率 | 3 | 2-5 天 | 2 | int8 accuracy 更稳定超过 50% |
| P3 | 形式化断言或 SVA | 3 | 2-4 天 | 2 | FIFO/handshake/bounds 有 assertion |
| P3 | 板上 ILA debug 脚本 | 4 | 2-4 天 | 3 | 能抓 start/done/status/logits |

最推荐的执行顺序：

1. 恢复仿真环境。
2. 确认当前 synthesis-proof RTL 功能仍正确。
3. 先修 `cnn_layer_runner` packed payload。
4. 再修 `feature_sram_bank` BRAM inference。
5. 跑 full top synthesis。
6. 再考虑 requant/PW/DW 的资源与时序优化。

## 4. 离 FPGA 上板验证还缺哪些步骤

### 4.1 工具与器件环境

缺口：

- 当前 K26 part 在 timing report 阶段报 `Cannot run timing on a non-timing device`。
- 这意味着目前只有 synthesis utilization，没有真实 timing closure。

需要做：

1. 确认目标 FPGA 板卡和准确 part。
2. 安装完整 Vivado device support 和 board files。
3. 确认 timing report 可用。
4. 准备真实 XDC：
   - clock period
   - reset
   - UART/SPI/JTAG/DDR 引脚
   - false path / multicycle path
   - I/O standard

验收标准：

- `report_timing_summary` 能输出 WNS/TNS。
- `report_utilization` 和 `report_power` 能完整输出。

### 4.2 SoC 集成

缺口：

- 现在项目内有 NPC 副本和 custom bridge，但还不是完整生产级 FPGA SoC top。
- 需要明确 CPU、ROM/RAM、CNN accelerator、外设、调试接口如何连接。

需要做：

1. 定义 FPGA top：
   - `clk`
   - `rst_n`
   - UART/JTAG/debug pins
   - optional LEDs
2. 实例化 NPC core。
3. 实例化 `cnn_top`。
4. 建立统一 memory map：
   - instruction ROM
   - data RAM
   - model/feature memory
   - custom instruction bridge
   - optional MMIO debug regs
5. 明确 CPU 和 accelerator 访问 memory 的仲裁：
   - 简单单端口仲裁
   - 双端口 BRAM
   - AXI-like wrapper

验收标准：

- FPGA top 能综合。
- CPU 能读写 RAM。
- CPU 能触发 CNN start。
- CNN done/status 能被 CPU poll 到。

### 4.3 Firmware 与模型数据装载

缺口：

- 当前 firmware/demo 更偏仿真。
- 上板需要考虑 ROM 初始化、模型权重放在哪里、输入图片如何送入。

需要做：

1. 生成可上板 ROM hex 或 bitstream init memory。
2. 决定模型权重存储位置：
   - BRAM init
   - DDR
   - UART 下载到 RAM
   - SPI flash
3. 决定输入图片装载方式：
   - 固化一张图
   - UART 下载多张图
   - JTAG memory write
4. firmware 输出结果：
   - UART 打印 logits/argmax/cycles
   - 或写到 debug register

验收标准：

- 板上能看到 firmware 启动信息。
- 能打印 CNN status。
- 能打印 logits 和 argmax。
- 至少 1 个样本与 Python golden 一致。

### 4.4 Implementation 与 bitstream

缺口：

- 目前只做 synthesis，没有 opt/place/route。

需要做：

1. `synth_design`
2. `opt_design`
3. `place_design`
4. `route_design`
5. `report_timing_summary`
6. `report_utilization`
7. `report_power`
8. `write_bitstream`

验收标准：

- WNS >= 0。
- bitstream 成功生成。
- 上板下载成功。

### 4.5 板上调试

缺口：

- 没有 ILA/VIO 或 debug counter 方案。

建议添加：

- LED heartbeat。
- `cnn_busy/done/error` 输出到 debug register 或 LED。
- ILA probe：
  - custom start pulse
  - desc base
  - current layer
  - mem req valid/write/addr
  - done/error
  - logits writeback

验收标准：

- ILA 能抓到一次完整 start -> layer progression -> done。
- UART/寄存器读数与 ILA 观察一致。

## 5. 贡献边界与对你目前代码水平的估计

先明确项目贡献边界，避免后续汇报时把代码作者、架构设计和工程判断混在一起：

- RV32I 五级流水线处理器是你完全手写的部分，这是最能代表你独立 RTL 实现能力的代码资产。
- CNN 加速器的总体架构、模块划分、DW/PW 吞吐权衡、tile fusion 方向、验证目标，是你与 GPT/Codex 共同讨论形成的。
- CNN 加速器的大部分 RTL、Python 工具、testbench、firmware glue 和文档实现主要由 Codex 生成，因此不能简单把这些代码量当作你的手写代码水平证明。
- 你对项目的真实贡献更适合表述为：自研 RV32I CPU + AI 协作完成 CNN accelerator 架构探索、RTL 原型生成、功能验证闭环和综合问题定位。

基于这个更准确的边界，我对你当前水平的估计是：

你已经具备较扎实的 RV32I/RTL 基础和系统级理解能力，能够独立完成处理器级 RTL，并能围绕 CNN 加速器提出关键架构问题，例如 DW/PW 吞吐不匹配、PW 是否需要反压 DW、buffer 面积与性能权衡、requant 乘法器成本、PW fanout、CPU 与 accelerator 频率关系等。这说明你不是只在“调用生成代码”，而是在主动判断架构取舍。

但就 CNN 加速器 RTL 的逐模块实现而言，由于大部分代码由 Codex 写成，你目前更需要补强的是“读懂、审查、修改、收敛 AI 生成 RTL”的能力，而不是直接声称自己已经独立实现了完整 CNN accelerator。这个说法更稳，也更符合项目事实。

你已经掌握或正在掌握的能力：

- 能独立手写 RV32I 处理器 RTL。
- 能读懂并修改 Verilog RTL，尤其是 CPU/流水线/控制通路相关逻辑。
- 能识别 AI 生成 RTL 中的工程问题，例如 packed vector、动态 part-select、过大 staging、BRAM 推断失败。
- 能围绕模块理解 testbench 与 golden model 的对应关系。
- 能理解 int8 quantization、bias、multiplier、shift、ReLU6。
- 能使用 Python golden model 对 RTL 做逐元素比较。
- 能用 Vivado 观察资源报告。
- 能理解 CPU custom instruction 到 accelerator 的控制路径。
- 能发现 DW/PW 吞吐不匹配、fanout、backpressure 等架构问题。

目前最需要补强的能力：

1. AI 生成 RTL 的审查与重构能力
   - 不要把 Codex 生成的 RTL 默认视为最终结构。
   - 先判断它是“仿真友好”还是“综合友好”。
   - 对每个大模块画出寄存器、memory、FSM、组合路径。
   - 能主动把不合理的大 packed vector 改成 memory/interface。

2. FPGA-friendly memory inference
   - 少用巨大 packed vector。
   - 少用动态 part-select。
   - 多用 1D memory + address generator。
   - 接受同步读 1 cycle latency。

3. 面向综合的微结构意识
   - Verilator 能跑不代表 Vivado 容易综合。
   - 大 mux、宽 bus、隐式多端口 memory 都会变得很贵。
   - 一定要边写 RTL 边做 OOC synthesis。

4. timing-driven design
   - 不只是功能正确，还要关注 critical path、fanout、register boundary。
   - combinational function 写得太大，综合器会生成很长路径。

5. 层级化验证
   - 每改一个模块，先跑模块 TB，再跑上层 TB。
   - 每个模块保留 Python golden 或局部 reference。

6. 资源/性能 trade-off
   - 不是所有并行都值得。
   - 不是所有 buffer 都该省。
   - 要用表格和数据决定 DW lanes、PW array、requant lanes、buffer banks。

更适合在简历/答辩中使用的表述：

- “本人独立实现 RV32I 五级流水线处理器。”
- “在 CNN 加速器部分，本人主导需求拆解、架构取舍、吞吐与 buffer 权衡分析，并借助 Codex 生成 RTL 原型。”
- “本人负责阅读、验证、综合问题定位与后续 FPGA-friendly 重构。”
- “项目重点不宣称 CNN accelerator 全部 RTL 手写，而强调 CPU/accelerator 协同设计、验证闭环和综合收敛能力。”

## 6. 你接下来实现时的详细指导

### 6.1 写 RTL 前先写小规格

每个模块动手前，先写 10 行规格：

- 输入是什么。
- 输出是什么。
- 一次事务从哪拍开始，哪拍结束。
- 内部 memory 有多大。
- 读延迟是多少。
- 是否允许 backpressure。
- done/valid 什么时候拉高。
- 边界条件是什么。
- 测试向量从哪里来。
- 资源期望是什么。

这能避免后面改来改去。

### 6.2 避免 packed vector 的经验规则

如果一个 signal 超过几千 bit，就问自己：

- 它是不是本质上是 memory？
- 是否可以改成 `mem[addr]`？
- 是否应该通过 loader 写入？
- 是否真的需要同时访问所有 bit？

建议规则：

- 小参数、少量 bias/mul/shift 可以 packed。
- 大 feature map、weight、tile buffer 不要 packed。
- 模块之间不要传几十万 bit 的 port。

### 6.3 改 `cnn_layer_runner` 的建议步骤

第一步：提取 payload memory。

建议新增或拆分：

- `layer_payload_buffer.v`
- `tile_input_buffer.v`
- `weight_param_buffer.v`

每个 buffer 用简单接口：

```verilog
wr_en
wr_addr
wr_data
rd_en
rd_addr
rd_data
```

第二步：修改 load phase。

现在 `store_response_word()` 是根据 phase 写 packed vector。应改为：

- PH_INPUT 写 `input_tile_mem`
- PH_DW_WEIGHT 写 `dw_weight_mem`
- PH_PW_WEIGHT 写 `pw_weight_mem`
- bias/mul/shift 可先继续 packed，后续再 memory 化

第三步：修改 engine 接口。

不要再：

```verilog
.input_tile(ds_input_tile)
.pw_weight(pw_weight)
```

而是让 engine 通过地址读：

```verilog
engine_input_rd_addr
engine_input_rd_data
engine_weight_rd_addr
engine_weight_rd_data
```

如果接口改动太大，折中方案是 engine 内部保留 memory，但上级用写口把数据 load 进去。

第四步：回归测试。

顺序：

1. `tb_dw_tile_fusion_engine`
2. `tb_ds_block_tile_engine`
3. `tb_cnn_top_sram_tiled_dsblock_datapath`
4. `tb_cnn_top_fullnet_sram_datapath`
5. CPU/fullnet 联合仿真

第五步：OOC synthesis。

顺序：

1. `dw_tile_fusion_engine`
2. `ds_block_tile_engine`
3. `cnn_layer_runner`
4. `cnn_top`

### 6.4 ready/valid 的使用建议

不要给所有小模块都加 ready/valid。

适合 ready/valid 的位置：

- loader 到 memory。
- engine start/done。
- requant pipeline。
- PW array input/output。
- memory arbitration。

不一定需要 ready/valid 的位置：

- 固定延迟的小算术函数。
- 固定 schedule 的内部状态机。
- 只被一个上级严格控制的内部 buffer。

经验：

- 跨模块、可能 stall 的地方用 ready/valid。
- 模块内部固定节拍用 FSM。
- 如果 ready 从很深处组合反传到很前面，会造成长组合路径。此时应使用 skid buffer 或注册 ready。

### 6.5 每次修改后的最小验收清单

每个优化都必须至少满足：

1. `git diff` 只包含相关文件。
2. 模块级 TB PASS。
3. 上一级 TB PASS。
4. OOC synthesis PASS。
5. 资源变化写进文档。
6. 如果无法跑某项验证，明确记录原因。

## 7. Baseline 选取建议

为了让项目更有说服力，需要至少三个 baseline。

### 7.1 CPU-only RV32I baseline

目的：

- 证明 custom accelerator 的加速比。

实现方式：

- 写一个纯 C int8 inference 或 cycle estimate。
- 先不要求真的在 RV32I 上跑完整 CNN，也可以用公式估算：
  - int8 multiply
  - int32 accumulate
  - loop overhead
  - load/store
  - requant

报告指标：

- 总 MAC = 约 5.14M。
- 假设 RV32I 每 MAC 至少 4-8 cycles。
- CPU-only cycles 粗估 = 20M-50M cycles。
- 与 RTL accelerator cycle counter 对比。

更强版本：

- 在 NPC 上跑一个小层的纯 C conv，与 accelerator 小层对比。

### 7.2 Python/Numpy golden baseline

目的：

- 证明数值正确性。

报告指标：

- sample index
- label
- Python logits
- RTL logits
- mismatch count
- argmax

建议至少给 10 个样本。

### 7.3 简单硬件 baseline

目的：

- 证明 DW fusion 和 PW 8x8 array 的设计选择有价值。

可选 baseline：

1. No fusion baseline
   - DW 输出完整写回 external memory。
   - PW 再读回来。
   - 对比 external memory traffic。

2. Scalar PW baseline
   - 1 个 MAC lane 做 PW。
   - 对比 8x8 array 的 cycle reduction。

3. No SRAM ping-pong baseline
   - 全部经外部 memory。
   - 对比片上 SRAM reuse 的流量减少。

建议优先做 No fusion memory traffic baseline，因为它最容易，且最能体现 DW tile fusion 的价值。

## 8. 建议补充的报告、文字和图表

### 8.1 必补报告

1. Full top synthesis report
   - LUT
   - FF
   - BRAM
   - DSP
   - module hierarchy breakdown

2. Timing report
   - target frequency
   - WNS/TNS
   - top critical paths
   - high fanout nets

3. Cycle report
   - 每层 cycle
   - 总 cycle
   - PW/DW/GAP/FC 占比

4. Accuracy/correctness report
   - 多样本 logits compare
   - argmax compare
   - mismatch count
   - int8 sampled accuracy

5. Memory traffic report
   - 每层 input/weight/output bytes
   - DW fusion 节省的 bytes
   - word-per-int8 与 packed layout 对比

### 8.2 强烈建议的图表

1. 模块资源柱状图
   - x 轴模块
   - y 轴 LUT/FF/BRAM/DSP

2. 每层 cycle breakdown
   - x 轴 layer
   - y 轴 cycles
   - 颜色区分 DW/PW/other

3. Memory traffic 对比图
   - no fusion vs fusion
   - debug word layout vs packed NHWC

4. 验证闭环图
   - PyTorch
   - quant export
   - Python golden
   - RTL
   - Verilator
   - CPU firmware
   - logits compare

5. 数据流图
   - CPU custom instruction
   - descriptor fetch
   - feature SRAM ping-pong
   - DW tile buffer
   - PW array
   - GAP/FC

6. 上板计划甘特图
   - synthesis-ready
   - implementation
   - bitstream
   - firmware
   - UART/ILA debug
   - multi-sample demo

### 8.3 文字材料建议

README 中建议增加：

- 当前 verified scope。
- 当前 synthesis scope。
- 当前不是最终优化版的声明。
- 下一步 FPGA memory pass 计划。
- 资源数字的口径说明：
  - primitive cell count
  - CLB LUT site count
  - BRAM tile count
- 为什么 full top 暂时没有最终 utilization。

PPT 中建议强调：

- 这是一个 end-to-end co-design 项目。
- 难点不是单个卷积，而是 CPU custom instruction、descriptor、quantization、tile fusion、systolic array、firmware、golden compare 的闭环。
- 当前 synthesis-proof 版本已经证明核心 RTL 可被 Vivado 接受。
- 下一步优化方向明确：memory/interface pass。

## 9. 适合作为阶段性成果的验收口径

如果近期要展示项目，建议采用以下口径：

已完成：

- RV32I custom instruction 控制路径。
- CNN descriptor-driven execution。
- int8 golden model 与 RTL logits compare。
- DW tile fusion + PW 8x8 array 的功能闭环。
- CPU/fullnet 仿真路径。
- 代表模块 Vivado OOC synthesis。
- synthesis blocker 识别与修复记录。

未完成但有计划：

- full `cnn_top` FPGA-friendly memory pass。
- BRAM/XPM memory wrapper。
- timing-capable implementation。
- board-level demo。
- resource/power optimization。

避免过度承诺：

- 不要说当前 RTL 已经适合直接上板。
- 不要把 synthesis-proof staging 的资源数字当作最终资源。
- 不要声称已有 timing closure。
- 不要用 50% 左右模型准确率作为算法贡献重点。

应该强调：

- 这是一个完整系统集成与硬件验证项目。
- 当前最有价值的是 CPU-to-accelerator-to-golden 的闭环。
- 资源优化方向已经由真实 Vivado 报告驱动，而不是凭感觉猜。

## 10. 最推荐的下一周行动计划

第 1 天：

- 修复 WSL/Verilator 环境。
- 重跑 DW、DSBlock、cnn_top、CPU fullnet 关键仿真。
- 把 PASS/FAIL 写入 development log。

第 2-3 天：

- 重构 `cnn_layer_runner` 的 `ds_input_tile` 和 `pw_weight`。
- 从 packed vector 改成 memory + address generator。
- 保持现有 testbench 输入输出不变。

第 4 天：

- 把 `feature_sram_bank` 改成 BRAM-friendly wrapper。
- 跑 `feature_sram_pingpong` 和 SRAM datapath TB。

第 5 天：

- 跑 `cnn_layer_runner` / `cnn_top` OOC synthesis。
- 更新 full top synthesis report。
- 生成资源柱状图和每层 cycle 表。

周末可选：

- 做 CPU-only baseline cycle estimate。
- 做 no-fusion memory traffic baseline。
- 更新 PPT 的结果页。

## 11. 一句话总结

当前项目最值得继续投入的方向不是继续堆算力，而是把“功能仿真友好的大 packed buffer”改造成“FPGA 综合友好的 SRAM/loader 数据面”。这一步完成后，full top utilization、timing、power、上板验证和性能对比都会自然变得更有说服力。

## 12. 模块级设计契约

所有自研 RTL 模块的输入、输出、事务边界、memory 容量、读延迟、backpressure、done/valid、边界条件、测试向量和资源期望，统一记录在：

- [`docs/module_design_contracts.md`](module_design_contracts.md)

修改模块接口、流水延迟、buffer 容量或握手语义时，应同步更新该文档和对应 testbench。
