# RTL 模块设计契约

本文逐个说明 `rtl/common`、`rtl/cnn`、`rtl/cpu_if` 中的自研模块。每个模块回答以下问题：

1. 输入是什么。
2. 输出是什么。
3. 一次事务从哪拍开始，哪拍结束。
4. 内部 memory 有多大。
5. 读延迟是多少。
6. 是否允许 backpressure。
7. `done`/`valid` 什么时候拉高。
8. 边界条件是什么。
9. 测试向量从哪里来。
10. 资源期望是什么。

`rtl/npc` 是复制进工程的 RV32I CPU 基线，本文件只描述本项目新增的 CNN 接口和加速器模块，不展开 NPC 内部流水线模块。

## 1. 当前主数据路径说明

当前 fullnet 主路径是：

```text
rv_cnn_custom_if / npc_cnn_custom_bridge / cnn_mmio_regs
  -> cnn_top
  -> descriptor_fetch
  -> cnn_layer_runner
  -> conv3x3_stem_engine / ds_block_tile_engine / gap_unit / fc_unit
  -> feature_sram_pingpong 或 external memory
```

以下模块当前没有接入 fullnet 主数据路径：

- `round_shift`
- `saturate_int8`
- `requant_activation_unit`
- `dw_line_buffer`
- `dw_window_generator`
- `dw_mac_lanes`

其中 `requant_activation_unit` 和 `dw_mac_lanes` 有独立功能价值，但 Stem、DW、PW、FC 当前仍使用模块内部函数或临时串行数据通路。后续重构时应决定是正式复用这些公共模块，还是删除重复实现。

## 2. Common 算术模块

### 2.1 `round_shift`

- **输入**：有符号 `value_in`、无符号右移量 `shift`。
- **输出**：按绝对值加半 LSB、远离零舍入后的有符号 `value_out`。
- **事务边界**：纯组合逻辑；输入稳定后同一拍内输出稳定，没有时钟事务。
- **内部 memory**：无；只有 `abs_value`、`rounded_abs`、`offset` 组合临时量。
- **读延迟**：无寄存延迟，只有组合传播延迟。
- **Backpressure**：不适用，没有握手接口。
- **done/valid**：无；调用者自行保证输入稳定。
- **边界条件**：`shift=0` 时直通；契约要求 `shift < WIDTH`，极小负数取绝对值时需要注意补码溢出。
- **测试向量**：没有独立 TB；舍入规则由 `python/golden_int8.py::round_shift_away_from_zero` 和 `tb_requant_activation_unit` 间接覆盖。
- **资源期望**：一个可变移位器、加法器和符号处理逻辑；应为小到中等 LUT，不使用 BRAM，通常不应使用 DSP。

### 2.2 `saturate_int8`

- **输入**：有符号 32-bit `value_in`。
- **输出**：限制到 `[-128, 127]` 的有符号 int8。
- **事务边界**：纯组合逻辑，同一拍完成。
- **内部 memory**：无。
- **读延迟**：无寄存延迟。
- **Backpressure**：不适用。
- **done/valid**：无。
- **边界条件**：大于 127 输出 127，小于 -128 输出 -128，其余保留低 8 位。
- **测试向量**：没有独立 TB；由 requant、GAP、FC 的 Python golden 和对应 TB 间接覆盖。
- **资源期望**：两个有符号比较器和一个选择器；少量 LUT，无 FF、BRAM、DSP。

## 3. Requant 模块

### 3.1 `requant_activation_unit`

- **输入**：`acc_int32`、`bias_int32`、Q31 `multiplier_int32`、右移量 `shift`、输出零点、激活上下界，以及 `valid_in/ready_in`。
- **输出**：Requant、int8 饱和、激活裁剪后的 `output_int8`，配套 `valid_out/ready_out`。
- **事务边界**：在 `valid_in && ready_in` 的上升沿接受；无停顿时经过乘法级、Q31/shift 级、clamp 输出级，到 `valid_out` 拉高结束。
- **内部 memory**：无数组；有两级内部 payload 寄存器和一级输出寄存器，约数百 bit。
- **读延迟**：无停顿时从接受沿到输出有效约两个后续时钟，通常称三段寄存流水。
- **Backpressure**：支持。`ready_out=0` 且输出有效时会冻结输出，并通过 `ready_s2/ready_s1` 向输入传播。
- **done/valid**：没有 `done`；结果有效时 `valid_out=1`，直到 `ready_out=1` 完成传输。
- **边界条件**：当前只实现第二次算术右移；`shift` 契约为 `0..63`。激活上下界应在 int8 范围内且 `min <= max`。int32 accumulator 加 bias 后进入 64-bit 乘法。
- **测试向量**：`python/generate_test_vectors.py::generate_requant_cases` 生成 `tests/vectors/requant_cases.hex`，由 `sim/tb_requant_activation_unit.v` 对照。
- **资源期望**：一个 64-bit 有符号乘法数据通路、移位器和比较逻辑。当前 Vivado OOC 约使用 10 DSP；后续可流水化或共享，但不应复制到每个输出 lane。

## 4. PW 计算模块

### 4.1 `systolic_pe`

- **输入**：`act_in`、`wgt_in`、`valid_in`、`clear_acc`。
- **输出**：延迟后的 activation、weight、`valid_out` 和 int32 `psum_out`。
- **事务边界**：`valid_in=1` 的上升沿执行一次 int8 乘加；该沿后 `valid_out=1`，结果写入 `psum_out`。
- **内部 memory**：一个 int32 accumulator，加两个 int8 传播寄存器。
- **读延迟**：一次寄存延迟。
- **Backpressure**：不支持；输入有效时必须被接受。
- **done/valid**：每次接受输入后 `valid_out` 在下一拍有效；没有 `done`。
- **边界条件**：`clear_acc=1` 时用当前乘积覆盖累加器；否则累加。int32 溢出按补码回绕，无饱和。
- **测试向量**：没有独立 TB；由 `tb_pw_systolic_array_8x8` 和 `pw_cases.hex` 间接覆盖。
- **资源期望**：每个 PE 一个 int8 乘法器、一个 int32 加法器和约 49 bit 寄存器；可映射 LUT 或 DSP。

### 4.2 `pw_systolic_array_8x8`

- **输入**：每拍 8 个 pixel activation、8 个 output-channel weight、`clear_acc`、`k_last` 和输入握手。
- **输出**：64 个 int32 psum 的 `psum_out`，配套输出握手。
- **事务边界**：每个 K 项在 `valid_in && ready_in` 时接受；第一项要求 `clear_acc=1`，最后一项要求 `k_last=1`；最后 K 项接受后的下一拍形成结果事务。
- **内部 memory**：64 个 int32 accumulator，约 2 Kbit；另有少量 valid/control 寄存器。
- **读延迟**：每个 K 项一拍更新；最后 K 项之后一拍产生 `valid_out`。
- **Backpressure**：支持输出反压，但粒度是整个阵列。`valid_out && !ready_out` 时 `ready_in=0`，停止接收后续 K 项。
- **done/valid**：没有 `done`；完整 8x8 psum 就绪时 `valid_out=1`，保持到 `ready_out=1`。
- **边界条件**：K 至少为 1；首项必须 clear，末项必须标记 `k_last`。不足 8 个 pixel 或 Cout 时由上层填零并屏蔽写回。
- **测试向量**：`generate_pw_cases` 生成 `tests/vectors/pw_cases.hex`，由 `tb_pw_systolic_array_8x8.v` 与 Python 8xKx8 matmul 比较。
- **资源期望**：64 个 int8 乘法器、64 个 int32 accumulator。当前 Vivado OOC 约 5957 CLB LUT、4098 register、0 DSP；后续主要关注输入广播扇出和时序。

## 5. DW 前端候选模块

### 5.1 `dw_line_buffer`

- **输入**：`valid_in/ready_in` 输入握手、`ready_out` 输出反压、`x_idx/y_idx`，以及包含 16 个 int8 channel 的 128-bit `pixel_vec_in`。
- **输出**：3x3 窗口的九个 128-bit channel vector，以及 `window_valid`。
- **事务边界**：只在 `valid_in && ready_in` 的上升沿接受一个 pixel；接受后更新两行 memory 和水平三列寄存器。输出在 `window_valid && ready_out` 时被消费。
- **内部 memory**：2 x 32 x 128 bit，共 1024 B；另有九个 128-bit 窗口寄存器，共 144 B。
- **读延迟**：接受 pixel 后同一上升沿更新注册窗口；非阻塞赋值保证窗口右列读取的是写入前的 line-memory 值。
- **Backpressure**：支持。`ready_in = !window_valid || ready_out`；有效窗口未被接收时 memory、窗口和 valid 全部保持。
- **done/valid**：没有 `done`；坐标满足 `y_idx>=2 && x_idx>=2` 的已接受输入产生 `window_valid=1`。旧输出被消费且没有新输入时 valid 清零。
- **边界条件**：`x_idx/y_idx` 为 5 bit，契约范围 `0..31`；内部 line memory 不复位，因此上游必须按行顺序先填充两行，才能使用第一个有效窗口。
- **测试向量**：`DWLineBufferGolden` 提供逐拍模型；`generate_dw_line_buffer_cases` 生成 `tests/vectors/dw_line_buffer_cases.hex`，包含扫描、空拍和连续反压，由 `tb_dw_line_buffer.v` 逐周期比较。
- **资源期望**：约 1 KB distributed RAM/LUTRAM、144 B 窗口寄存器和少量握手逻辑；不应使用 BRAM 或 DSP。

### 5.2 `dw_window_generator`

- **输入**：九个 int8 window 元素和 `valid_in`。
- **输出**：打包后的 72-bit `window_flat` 和 `valid_out`。
- **事务边界**：`valid_in=1` 的上升沿采样九个元素；该沿后输出寄存器有效。
- **内部 memory**：72-bit 输出寄存器。
- **读延迟**：一拍。
- **Backpressure**：不支持。
- **done/valid**：`valid_out` 是 `valid_in` 的一拍延迟。
- **边界条件**：padding、stride 和边界值必须由上游生成；本模块只负责打包。
- **测试向量**：当前没有独立 TB，也未接入当前 DW 主路径；适合用固定 3x3 pattern 做顺序检查。
- **资源期望**：主要是 72 个 FF 和连线，几乎不消耗算术资源。

### 5.3 `dw_mac_lanes`

- **输入**：最多 16 lane 的 3x3 activation window、DW weight、`lane_active`，以及 `valid_in/ready_in` 输入握手和 `ready_out` 输出反压。
- **输出**：每 lane 一个 int32 accumulator、`busy` 和保持型 `valid_out`。
- **事务边界**：`valid_in && ready_in` 的上升沿锁存输入；随后三拍分别计算三行，每行三个乘法；结果通过 `valid_out && ready_out` 完成传输。
- **内部 memory**：锁存的 window 和 weight 各 `LANES x 9 B`，16 个 int32 accumulator，合计约 800 B 寄存器状态。
- **读延迟**：从 start 接受沿到 `valid_out` 约三个后续时钟。
- **Backpressure**：支持。计算期间 `ready_in=0`；结果未被接收时 `valid_out` 和 `acc_vec` 保持不变；结果被接收的同一拍允许接受下一笔输入。
- **done/valid**：没有 `done`；第三行累加完成时 `valid_out=1`、`busy=0`，保持到 `ready_out=1`。
- **边界条件**：无效 lane 必须由 `lane_active=0` 屏蔽；int32 溢出回绕；输入必须在 start 时完整提供。
- **测试向量**：`generate_dw_mac_lanes_cases` 生成 `tests/vectors/dw_mac_lanes_cases.hex`，由 `tb_dw_mac_lanes.v` 验证数学结果、inactive lane、busy 和输出反压。
- **资源期望**：16 lane x 3 int8 multiplier，共 48 个乘法器，外加 16 个 accumulator。当前 Vivado OOC 约 9759 CLB LUT、3367 register、0 DSP。

## 6. DW Tile 存储与融合

### 6.1 `dw_tile_buffer_bank`

- **输入**：单写口 `wr_en/wr_addr/wr_data` 和异步读地址 `rd_addr`。
- **输出**：异步 `rd_data`。
- **事务边界**：写事务在 `wr_en` 上升沿完成；读没有显式事务。
- **内部 memory**：默认 64 x 8 bit，即 64 B。
- **读延迟**：组合异步读，地址变化后经过 memory/MUX 传播延迟输出。
- **Backpressure**：不支持。
- **done/valid**：无。
- **边界条件**：地址必须小于 `BANK_DEPTH`；同地址读写语义依赖综合 memory 类型，外层当前在下一拍采样。
- **测试向量**：由 `dw_tile_buffer`、DW fusion 和 DSBlock TB 间接覆盖，没有独立 TB。
- **资源期望**：每 bank 应映射为 LUTRAM 或与其它 bank 合并为 BRAM；不应展开为大量普通 FF。

### 6.2 `dw_tile_buffer`

- **输入**：最多 16 lane 的同 pixel 连续 channel 写入；读取指定 channel 上连续 8 个 pixel。
- **输出**：`rd_data_vector[8]`，即 8 pixel x 1 channel。
- **事务边界**：写在 `wr_en_vec` 有效的上升沿完成；读在 `rd_en` 上升沿采样 bank 异步输出，并更新 `rd_data_vector`。
- **内部 memory**：64 pixel x 128 channel x 8 bit，共 8192 B；实现为 128 个 64 B bank。
- **读延迟**：外部观察为一拍，模块没有 `rd_valid`，调用者固定等待一拍。
- **Backpressure**：不支持；调用者必须遵守固定读延迟。
- **done/valid**：无；写使能和读使能本身定义事务。
- **边界条件**：pixel 为 `0..63`，channel 为 `0..127`；`WRITE_LANES` 预期不超过 16；越界读 pixel 返回零。
- **测试向量**：由 `tb_dw_tile_fusion_engine` 和 `tb_ds_block_tile_engine` 间接验证，向量来自 `dw_cases.hex`、`dsblock_cases.hex`。
- **资源期望**：目标约 8 KB，即约 2 个 BRAM36 或适量 LUTRAM。当前显式 128-bank OOC 约 46131 CLB LUT，说明 banking 方式仍需 FPGA memory pass。

### 6.3 `dw_tile_fusion_engine`

- **输入**：输出 tile 尺寸、Cin、stride、输入零点、packed input tile、DW weight 和逐通道量化参数、`start`。
- **输出**：写向 `dw_tile_buffer` 的 lane vector、`busy` 和 `done`。
- **事务边界**：`start` 在 IDLE 上升沿接受；先把整个最大 input packed vector 串行 staging 到 `input_mem`，再逐 pixel、逐 channel、逐 kernel 点计算；最后一个输出写入后进入 DONE。
- **内部 memory**：`input_shift_reg` 36,992 B，加 `input_mem` 36,992 B；合计约 73,984 B，另有少量 accumulator/control。
- **读延迟**：`input_mem` 当前组合读；整个事务固定先花 36,992 拍 staging，每个 DW 输出再约花 11 拍。
- **Backpressure**：不支持输出反压；busy 时不能接受新 start，buffer 写脉冲必须被下游立即接受。
- **done/valid**：每个 DW 输出在 `ST_WRITE` 产生一拍 `buf_wr_en_vec`，当前只有 lane 0 有效；所有输出完成后 `done=1` 一拍。
- **边界条件**：`channels<=128`；父模块限制输出 tile 不超过 64 pixel；stride 为 1 或 2；输入必须已经包含 halo/padding，越界 fallback 使用 `input_zero_point`。
- **测试向量**：`generate_dw_cases` 生成 `dw_cases.hex`，覆盖 stride 1、stride 2、padding 和多 channel，由 `tb_dw_tile_fusion_engine.v` 比较。
- **资源期望**：最终目标应恢复 16-lane x 3 multiplier DW 数据通路，并只保留一份 line/tile memory。当前 synthesis-proof OOC 约 170408 CLB LUT、296388 register、10 DSP，只证明可综合，不是可接受目标。

## 7. DSBlock 集成模块

### 7.1 `ds_block_tile_engine`

- **输入**：一个带 halo 的 input tile、DW/PW weight、bias、multiplier、shift、输入输出 shape 和量化参数、`start`。
- **输出**：逐元素 PW int8 输出写接口、`busy` 和 `done`。
- **事务边界**：start 后先固定串行装载全部最大 PW weight，再完整执行 DW，再按 8 pixel x 8 Cout 分组执行 PW，最后逐个写出 64 个阵列结果。
- **内部 memory**：PW shift register 32,768 B、PW weight memory 32,768 B、DW tile buffer 8192 B；还包含子模块中的约 73,984 B DW staging，合计超过 147 KB 的临时状态。
- **读延迟**：DW tile buffer 读固定等待一拍；每个 PW K 项当前经过 READ、READ_WAIT、FEED 三个状态；阵列在最后 K 后一拍给出 psum。
- **Backpressure**：内部 PW array 支持 ready，但 `ready_out` 固定为 1；模块输出没有 ready，不能被下游反压。
- **done/valid**：每个输出元素在 `ST_WRITE` 产生一拍 `out_wr_en`；最后一个输出之后 `done=1` 一拍。
- **边界条件**：`Cin<=128`、`Cout<=256`、输出 tile 不超过 64 pixel；不足 8 pixel/Cout 的阵列边缘靠零填充和写回条件屏蔽。
- **测试向量**：`generate_dsblock_cases` 生成 `dsblock_cases.hex`，由 `tb_ds_block_tile_engine.v` 对比融合 DW+PW golden。
- **资源期望**：最终应由 8 KB DW tile buffer、一个 8x8 PW array、可复用 weight/quant SRAM 和 DW lanes 主导。当前 OOC 约 389253 CLB LUT、565654 register、20 DSP，仅为 synthesis-proof。

## 8. Stem、GAP、FC

### 8.1 `conv3x3_stem_engine`

- **输入**：最大 10x10x3 packed tile、16x3x3x3 weight、逐通道量化参数、输出 tile shape 和 `start`。
- **输出**：逐 pixel、逐 channel 的 int8 写接口、`busy` 和 `done`。
- **事务边界**：start 后进入 WRITE；每拍计算并写一个输出 channel；完成 `out_h*out_w*16` 个元素后结束。
- **内部 memory**：没有独立数组，输入和参数由 packed 端口直接组合读取；只有计数器和输出寄存器。
- **读延迟**：每个输出元素在一个组合计算拍后注册输出；整层约 `out_pixels*16` 个运行拍，加 start/done 状态开销。
- **Backpressure**：不支持；`out_wr_en` 连续产生时下游必须接受。
- **done/valid**：每个运行拍 `out_wr_en=1`；最后一个元素之后 `done=1` 一拍。
- **边界条件**：输入 tile 固定容量 10x10x3；当前主用途是最大 8x8 输出；padding 应由 layer runner 填 `input_zero_point`。
- **测试向量**：`generate_stem_cases` 生成 `stem_cases.hex`，由 `tb_conv3x3_stem_engine.v` 比较；tiled same-padding 还由 top-level stem TB 覆盖。
- **资源期望**：当前每个输出拍组合展开 27 个 int8 MAC 和一个 64-bit requant 乘法，面积和关键路径偏大。最终宜复用小 MAC 阵列和共享/流水 requant。

### 8.2 `gap_unit`

- **输入**：固定 4x4x256 packed int8 feature 和 `start`。
- **输出**：256 个 int8 平均值、`busy` 和 `done`。
- **事务边界**：start 后每拍处理一个 channel；第 256 个 channel 写入后结束。
- **内部 memory**：没有独立输入 memory，但端口本身是 4096 B packed vector；输出寄存器 256 B。
- **读延迟**：每 channel 一拍，完整运行 256 拍，加 start/done 状态开销。
- **Backpressure**：不支持。
- **done/valid**：结果在 `gap_out` 中逐通道更新；全部完成后 `done=1` 一拍，没有逐元素 valid。
- **边界条件**：只支持固定 4x4x256；平均采用算术右移 4，对负数是向负无穷取整，不是重新量化。
- **测试向量**：`generate_gap_cases` 生成 `gap_cases.hex`，由 `tb_gap_unit.v` 对照。
- **资源期望**：当前每拍组合读取并相加 16 个 int8。最终更合理的是流式累计，只保留 256 个 int32 sum，消除 4 KB packed feature。

### 8.3 `fc_unit`

- **输入**：固定 256-element int8 vector、10x256 int8 weight、10 路量化参数和 `start`。
- **输出**：10 个 int8 logits、`busy` 和 `done`。
- **事务边界**：start 后每拍处理一个 class，共 10 个运行拍；最后一个 class 完成后结束。
- **内部 memory**：没有独立 memory；packed 输入约 256 B、weight 2560 B、参数 90 B，输出 10 B。
- **读延迟**：每 class 一拍，但该拍组合展开 256 个 MAC 和 requant；完整运行约 10 拍。
- **Backpressure**：不支持。
- **done/valid**：logits 逐 class 更新；全部 10 类完成后 `done=1` 一拍。
- **边界条件**：固定 256 输入、10 输出；int32 accumulator 溢出回绕；最终激活通常设为 `[-128,127]`。
- **测试向量**：`generate_fc_cases` 生成 `fc_cases.hex`，由 `tb_fc_unit.v` 比较。
- **资源期望**：当前组合展开极其昂贵且时序长。最终应使用复用 MAC、PW array 或小型向量 MAC，权重放 BRAM/ROM。

## 9. Feature SRAM

### 9.1 `feature_sram_bank`

- **输入**：一个同步写口和一个同步读请求口。
- **输出**：注册的 `rd_data` 和 `rd_valid`。
- **事务边界**：写在 `wr_en` 上升沿完成；读在 `rd_en` 上升沿接受，随后输出有效。
- **内部 memory**：默认 `2^15 x 8 bit`，即 32 KB。
- **读延迟**：一拍；同地址同时读写采用 write-first，返回新写入数据。
- **Backpressure**：不支持；每拍最多一读一写。
- **done/valid**：读请求后一拍 `rd_valid=1`；写没有完成信号。
- **边界条件**：地址范围 `0..32767`；memory 不在 reset 时清零，软件/loader 必须先初始化有效区域。
- **测试向量**：`generate_feature_sram_bank_cases` 生成对应 hex，由 `tb_feature_sram_bank.v` 验证读写和同地址 bypass。
- **资源期望**：目标每 bank 32 KB，约 8 个 BRAM36。当前 Vivado OOC 映射为 distributed RAM，约 5120 LUTRAM LUT，需要 BRAM-friendly wrapper 或 XPM。

### 9.2 `feature_sram_pingpong`

- **输入**：逻辑 input-bank 读口、output-bank 写口、host 读写口、`reset_to_a` 和 `layer_done`。
- **输出**：输入读数据、host 读数据，以及当前 input/output bank 选择。
- **事务边界**：普通读写沿用 bank 的单拍事务；`layer_done` 上升沿交换 A/B 角色，`reset_to_a` 优先恢复 A 为输入。
- **内部 memory**：两个 32 KB bank，共 64 KB。
- **读延迟**：一拍，bank 选择和请求有效也延迟一拍用于返回路由。
- **Backpressure**：没有 ready。host 与 accelerator 同时访问同一 bank 时 host 优先，低优先级请求可能被静默覆盖，因此系统必须避免冲突。
- **done/valid**：input 和 host 读分别使用 `input_rd_valid`、`host_rd_valid`；写和 bank swap 没有 done。
- **边界条件**：只允许 input 侧读 active bank、output 侧写 opposite bank；只有 descriptor flag 允许时 layer done 才应触发 swap。
- **测试向量**：`generate_feature_sram_pingpong_cases` 生成向量，由 `tb_feature_sram_pingpong.v` 验证 A/B 切换、host 访问和读延迟。
- **资源期望**：目标约 16 个 BRAM36，加少量仲裁和路由 LUT；不应由大量 FF 或 distributed RAM 承担。

## 10. Descriptor、调度和状态

### 10.1 `descriptor_fetch`

- **输入**：`start`、descriptor base、layer index，以及外部 memory request/response 握手。
- **输出**：32-word descriptor、`op_type`、`busy`、单拍 `valid` 和 memory read request。
- **事务边界**：IDLE 中 start 上升沿开始；逐 word 发请求并等待响应；第 32 个响应写入后结束。
- **内部 memory**：1024-bit descriptor register，即 128 B。
- **读延迟**：由外部 memory 决定；模块一次只允许一个 outstanding read。
- **Backpressure**：支持 request 侧 `mem_req_ready` 和任意响应等待；busy 时不能接受新 start。
- **done/valid**：没有 done；32 words 全部返回时 `valid=1` 一拍，`busy=0`。
- **边界条件**：descriptor stride 固定 128 B；地址为 `base + layer_index*128 + word*4`；没有总线 error/timeout。
- **测试向量**：由所有 `tb_cnn_top*` 的 memory image 间接覆盖，descriptor 由 `generate_test_vectors.py` 生成。
- **资源期望**：128 B register/distributed RAM、地址加法和小 FSM；资源较小。

### 10.2 `tile_scheduler`

- **输入**：输出 H/W、stride、`start` 和 `next`。
- **输出**：tile 起点、有效尺寸、所需 input tile 尺寸、`valid` 和 last 标志。
- **事务边界**：start 上升沿建立第一个 tile；每个 `next && valid` 上升沿推进到下一 tile；最后 tile 接受 next 后事务结束。
- **内部 memory**：无；只有当前 H/W 两个 8-bit 寄存器。
- **读延迟**：tile 属性由当前位置组合生成；start 后寄存状态更新即可观察第一个有效 tile。
- **Backpressure**：没有 ready；调用者通过何时拉高 `next` 控制推进，等价于显式消费节拍。
- **done/valid**：`valid` 从 start 后保持；最后 tile 被 next 消费后拉低。`is_last_tile` 是组合标志。
- **边界条件**：`out_h/out_w` 必须非零；stride 只支持 1 或 2；tile 固定最大 8x8；边缘 tile 自动缩小。
- **测试向量**：`generate_tile_scheduler_cases` 生成 `tile_scheduler_cases.hex`，由 `tb_tile_scheduler.v` 检查完整序列。
- **资源期望**：少量加减法、比较器和两个位置寄存器；很小的 LUT/FF，无 memory/DSP。

### 10.3 `status_counter`

- **输入**：`clear`、全局 `enable`、`layer_start` 和 layer index。
- **输出**：总周期、当前层周期和 active layer。
- **事务边界**：clear 定义一次推理计数开始；enable 每拍计数；layer_start 清当前层计数。
- **内部 memory**：三个计数寄存器，共 72 bit。
- **读延迟**：同步更新，外部组合读取寄存器。
- **Backpressure**：不适用。
- **done/valid**：无；输出始终有效。
- **边界条件**：32-bit counter 溢出后回绕；clear 优先于 enable，layer_start 优先于 layer cycle increment。
- **测试向量**：没有独立 TB；由 `tb_cnn_top`、fullnet status 和 cycle check 间接覆盖。
- **资源期望**：两个 32-bit incrementer 和寄存器，少量 LUT/FF。

## 11. Layer 执行与顶层控制

### 11.1 `cnn_out_buffer`

- **输入**：单写口和异步读地址。
- **输出**：异步 int8 读数据。
- **事务边界**：写在上升沿完成；读无显式事务。
- **内部 memory**：默认 16384 x 8 bit，即 16 KB。
- **读延迟**：组合异步读。
- **Backpressure**：不支持。
- **done/valid**：无。
- **边界条件**：地址必须小于 DEPTH；仿真初始化只在非综合模式存在。
- **测试向量**：由 Stem/DSBlock top datapath TB 间接覆盖。
- **资源期望**：目标约 4 个 BRAM36，但异步读通常不利于 BRAM 推断；后续应改同步读或缩成输出 FIFO。

### 11.2 `cnn_layer_runner`

- **输入**：完整 descriptor、start、外部 memory 握手，以及 feature SRAM 读响应。
- **输出**：layer done/error、外部 memory 请求、feature SRAM 写请求和 busy。
- **事务边界**：IDLE 中 start 上升沿锁存 descriptor；依次 load 参数、启动 engine、等待完成、写回输出；ST_DONE 产生结束脉冲。
- **内部 memory**：当前 packed payload 和 out buffer 合计约 98,630 B，包括 36,992 B DS input、32,768 B PW weight、16,384 B output、4096 B GAP input 及其它参数。
- **读延迟**：外部 memory 响应可变；feature SRAM 固定一拍；tiled 输入逐 int8 读取；engine 延迟取决于 op type。
- **Backpressure**：外部 request 支持 `mem_req_ready`，response 可等待；SRAM 使用 `rd_valid`；engine 的逐元素输出没有 ready，必须被内部 out buffer 接受。
- **done/valid**：正常完成时 `done=1` 一拍；配置非法时 `error=1` 并进入 error completion；busy 覆盖完整 layer 生命周期。
- **边界条件**：Stem、DSBlock shape 受 `valid_config` 限制；tiled DS 支持输入到 32x32、Cin<=128、Cout<=256、stride 1/2；GAP/FC 当前固定 shape。外部 debug layout 是一个 int8 占一个 32-bit word。
- **测试向量**：由全部 `tb_cnn_top_*datapath.v` 间接覆盖；memory image 和 expected output 由 `generate_test_vectors.py` 生成。
- **资源期望**：控制本身应较小，资源应主要来自共享 activation/weight/quant SRAM。当前大 packed vector 和动态 part-select 是 full-top 综合的主要成本，应重构为 loader + SRAM 接口。

### 11.3 `cnn_top_ctrl`

- **输入**：start、layer_num、descriptor valid/op、layer done/error。
- **输出**：busy/done/error、current layer、descriptor fetch start/index 和 layer start。
- **事务边界**：IDLE 中 start 开始网络事务；每层依次 fetch、exec；最后一层完成或发生错误后结束。
- **内部 memory**：无数组；保存 FSM 和当前 layer index。
- **读延迟**：控制事件均为同步单拍脉冲。
- **Backpressure**：没有 start ready；上层必须只在 IDLE 发 start。内部会等待 descriptor 和 layer 完成。
- **done/valid**：网络结束时 `done=1` 一拍；`fetch_start`、`layer_start` 也各是一拍。
- **边界条件**：只支持 op 0..3；`layer_num=0` 立即 done；current layer 只有 8 bit，契约应限制最多 256 层。
- **测试向量**：由 `tb_cnn_top.v` 和所有多层/fullnet top TB 间接覆盖。
- **资源期望**：小型 FSM、比较器和计数寄存器，资源很小。

### 11.4 `cnn_top`

- **输入**：CPU command、descriptor base、layer count、统一 external memory request/response。
- **输出**：command ready、32-bit status 和统一 memory master。
- **事务边界**：`cmd_valid && cmd_ready && cmd_type=START` 的上升沿开始；控制器完成所有层时 done 被锁存在 status，直到下一条 command 清除。
- **内部 memory**：两个 32 KB feature SRAM bank，加 `cnn_layer_runner` 当前约 98.6 KB payload，以及 descriptor/status/control 状态。
- **读延迟**：descriptor 和 payload 取决于 external memory；feature SRAM 一拍；总事务周期由所有 layer 累加。
- **Backpressure**：command 侧只在不 busy 时 ready；memory request 支持 ready/response 等待。descriptor fetch 期间独占 memory bus。
- **done/valid**：`status[0]=busy`、`status[1]=done`、`status[2]=error`；done/error 为锁存状态，不是单拍。
- **边界条件**：只接受 `CMD_START=0`；status 只保留 total cycle 低 24 bit和 current layer 低 4 bit；没有 memory error 或 timeout。
- **测试向量**：`tb_cnn_top.v`、各 op/tiled/SRAM/multilayer/fullnet TB；fullnet memory image 来自 `cnn_top_fullnet_sram_cases.hex`。
- **资源期望**：最终应由 64 KB feature BRAM、PW array、DW lanes、weight/quant buffers 主导。当前 full top 因 layer runner packed payload 尚未在本机快速完成 OOC synthesis。

## 12. CPU 和 MMIO 接口

### 12.1 `rv_cnn_custom_if`

- **输入**：RV custom instruction、rs1/rs2、accelerator command ready 和 status。
- **输出**：instruction ready、accelerator command、rd response。
- **事务边界**：`instr_valid && instr_ready` 的上升沿接受指令；start 发一拍 accelerator command，poll/stat 注册一拍 rd response。
- **内部 memory**：无；只保存命令和 response 寄存器。
- **读延迟**：poll/stat 在接受沿后输出 `rd_valid=1`；start 是否可接受由 `acc_cmd_ready` 决定。
- **Backpressure**：start 支持反压，`instr_ready=acc_cmd_ready`；poll/stat 永远 ready。
- **done/valid**：start 使用 `acc_cmd_valid` 单拍；poll/stat 使用 `rd_valid` 单拍。
- **边界条件**：custom0 opcode 为 `0001011`，funct3 0/1/2 对应 start/poll/stat；非法命令返回 `0xffffffff`。
- **测试向量**：`tb_rv_cnn_custom_if.v` 手写指令场景；`tb_rv_custom_if_cnn_top_fullnet.v` 做接口到 fullnet 闭环。
- **资源期望**：少量 decode、MUX 和寄存器，资源极小，不应影响 CPU 主频的主要关键路径。

### 12.2 `npc_cnn_custom_bridge`

- **输入**：NPC 已解码的 command valid/funct3/rs1/rs2、accelerator ready/status。
- **输出**：CPU read data 和 accelerator start command。
- **事务边界**：poll/stat read data 是组合输出；start 在 valid、funct3=start、ready 同时满足的上升沿发出一拍 command。
- **内部 memory**：无；只有 command 寄存器。
- **读延迟**：poll/stat 组合读取；start 注册一拍输出。
- **Backpressure**：模块没有返回 CPU ready；如果 start 时 accelerator 不 ready，则命令不会发出，CPU 侧必须通过现有执行控制确保重试或只在 ready 时提交。
- **done/valid**：只有 `acc_cmd_valid` 单拍；无 rd valid。
- **边界条件**：funct3 0/1/2；默认 read data 返回 `acc_cmd_ready` bit0。
- **测试向量**：`tb_npc_cnn_custom_bridge.v` 手写场景，`tb_npc_bridge_cnn_top_fullnet.v` 和 RV core fullnet TB 做集成验证。
- **资源期望**：组合 MUX、比较器和少量寄存器，资源极小。

### 12.3 `cnn_mmio_regs`

- **输入**：简化 MMIO bus valid/write/address/data、accelerator ready/status。
- **输出**：bus ready/read response，以及 accelerator command。
- **事务边界**：普通寄存器访问在 `bus_valid && bus_ready` 上升沿接受；写 CMD start 时同拍锁存并发出一拍 command。
- **内部 memory**：三个 32-bit 配置寄存器：descriptor base、layer count、last command。
- **读延迟**：read 接受后 `bus_rvalid=1` 一拍，数据注册输出。
- **Backpressure**：只有 start CMD 访问会被 `acc_cmd_ready` 反压，其余访问始终 ready。
- **done/valid**：bus read 使用单拍 `bus_rvalid`；accelerator start 使用单拍 `acc_cmd_valid`。
- **边界条件**：offset `0x00/04/08/0c/10`；非法读返回 `0xffffffff`；写 start 前必须先写 descriptor base 和 layer count。
- **测试向量**：`tb_cnn_mmio_regs.v` 手写寄存器访问；`tb_mmio_cnn_top_fullnet.v` 复用 fullnet memory image。
- **资源期望**：约 96 bit 配置寄存器、地址 decode 和 MUX，资源极小。

## 13. 验证缺口汇总

以下模块缺少直接单元测试：

- `round_shift`
- `saturate_int8`
- `systolic_pe`
- `dw_line_buffer`
- `dw_window_generator`
- `dw_mac_lanes`
- `dw_tile_buffer`
- `dw_tile_buffer_bank`
- `descriptor_fetch`
- `status_counter`
- `cnn_top_ctrl`
- `cnn_layer_runner`
- `cnn_out_buffer`

其中多数已经被上层 TB 间接覆盖，但以下三类值得优先补测试：

1. `dw_line_buffer + dw_window_generator + dw_mac_lanes`
   - 它们当前未接主路径，间接测试实际上没有覆盖。
2. `descriptor_fetch`
   - 补 memory request backpressure、response 延迟和 descriptor 边界测试。
3. `cnn_out_buffer/feature SRAM`
   - 补同步 BRAM 重构前后的 read-during-write 语义测试。

## 14. 阅读和重构建议

修改任何模块前，先把本文件对应条目中的以下内容变成明确约束：

- 接受条件必须写成布尔表达式，例如 `valid && ready`。
- 延迟必须说明是组合、固定 N 拍还是可变。
- 输出 valid 是否保持到 ready，还是只脉冲一拍。
- memory 的 read-during-write 语义必须明确。
- 资源期望要说明是当前 synthesis-proof 数字还是最终设计目标。

当 RTL 改动改变了接口、延迟、buffer 容量或边界条件时，应同时更新本文件、对应 Python vector generator 和 testbench。
