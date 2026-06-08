# Verification Plan

本项目采用严格的分阶段门禁：一个模块必须先有 Python golden 对照、testbench 和 Verilator 通过结果，才开始下一个模块。

## 阶段 1：基础算术模块

实现思路：

- `round_shift.v` 提供 signed round-away-from-zero right shift，供 requant 或独立单元复用。
- `saturate_int8.v` 将 signed int32 clamp 到 signed int8。
- `requant_activation_unit.v` 用 64-bit 中间乘法实现 `bias -> fixed point multiply -> shift -> zero point -> int8 saturate -> activation clamp`。
- `python/golden_int8.py` 固化同一 requant 算法。
- `python/generate_test_vectors.py` 生成覆盖正数、负数、饱和、ReLU6 clamp、随机值的 vectors。

验证标准：

- `tb_requant_activation_unit.v` 读取 Python 生成的 `tests/vectors/requant_cases.hex`。
- 每个 case 的 RTL int8 输出必须等于 Python expected。
- Verilator 仿真以 0 退出，并打印 `PASS tb_requant_activation_unit`。

## 阶段 2：PW 8x8 脉动阵列

实现思路：

- `systolic_pe.v` 实现 int8xint8->int32 MAC PE。
- `pw_systolic_array_8x8.v` 第一版采用 8x8 并行 MAC 寄存器阵列，接口保持 systolic 数据流语义：每 cycle 输入 `act_vec[8]` 和 `wgt_vec[8]`，`k_last` 后输出 `psum[8][8]`。
- Python golden 生成随机 `A[8][Cin]`、`W[Cin][8]`，输出矩阵乘结果。

验证标准：

- 覆盖多个 Cin，包括 1、3、8、16、32。
- 覆盖正负 int8 和 accumulator 正负溢出附近的普通范围。
- RTL `psum_out[pixel][cout]` 与 Python matmul 完全一致。

## 阶段 3：DW tile fusion

实现思路：

- `dw_tile_buffer.v` 实现 64 pixels x 128 channels byte buffer。
- `dw_mac_lanes.v` 并行处理最多 16 channels，每个 lane 对 3x3 window 做 int32 累加。
- `dw_tile_fusion_engine.v` 第一版用可验证优先的顺序控制实现单 tile DW3x3，支持 stride=1/2、same padding、input zero point。
- Python golden 生成单 tile depthwise convolution 输出。

验证标准：

- 单 tile stride=1。
- 单 tile stride=2。
- 左上、右下等边界 padding。
- 多 channel，至少覆盖 1、3、16、32 channels。
- RTL tile buffer 内容与 Python golden 完全一致。

## 阶段 4：Conv3x3 Stem

实现思路：

- `conv3x3_stem_engine.v` 支持 Cin=3、Cout=16、stride=1、same padding。
- 第一版串行遍历 output pixel 和 output channel，复用 requant。

验证标准：

- 对随机 32x32x3 小范围输入和随机权重，输出 32x32x16 与 Python golden 一致。
- 覆盖四周 padding 使用 input zero point。

## 阶段 5：DSBlock 集成

实现思路：

- 将 DW tile fusion 和 PW array 串接。
- DW 输出只进 `dw_tile_buffer`。
- PW 按 `8 pixels x cout_tile=8` 消费 tile buffer。

验证标准：

- DSBlock1 输出与 Python golden 完全一致。
- 检查 DW 中间结果没有外部 memory write。

## 阶段 6：完整 cnn_top

实现思路：

- `descriptor_fetch.v` 读取 layer descriptor。
- `tile_scheduler.v` 生成固定 8x8 tile。
- `cnn_top_ctrl.v` 顺序执行 Stem、6 个 DSBlock、GAP、FC。
- Feature SRAM A/B ping-pong，DW tile 不回写外部 memory。

验证标准：

- `tb_cnn_top.v` 跑固定 descriptor smoke test。
- 完整 logits 与 `python/golden_int8.py` 输出一致。
- 输出总 cycle count、每层 cycle count、外部 memory 访问量。

## 阶段 7：CPU 接入

实现思路：

- `rv_cnn_custom_if.v` 解码 `cnn.start`、`cnn.poll`、`cnn.stat`。
- start 只等待 command ready，不等待整网完成。
- firmware 提供 inline assembly 和 memory-mapped fallback。

验证标准：

- RV32I 程序能发起 start。
- CPU poll 能观察 busy -> done。
- CPU 读取 logits 并 argmax。

## Regression Script

`scripts/run_all_sims.sh` is the top-level Verilator regression entry.
It preserves fail-fast behavior by default and supports long-run chunking:

```bash
./scripts/run_all_sims.sh
SIM_LIST=1 ./scripts/run_all_sims.sh
SIM_ONLY="tb_requant_activation_unit tb_tile_scheduler" ./scripts/run_all_sims.sh
SIM_FROM=tb_cnn_top_tiled_stem_datapath ./scripts/run_all_sims.sh
SIM_TO=tb_cnn_top_fullnet_sram_datapath ./scripts/run_all_sims.sh
SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
```

Each selected test writes:

```text
build/reports/sim_logs/<test>.log
build/reports/sim_logs/summary.csv
```

The CSV format is:

```text
test,status,seconds,log
```

Acceptance standard:
- Every selected row in `summary.csv` must report `PASS`.
- Interface/fullnet regressions must also check `cnn.stat` or MMIO `STAT` against the decoded cycle counter, `{8'd0, status[31:8]}`.
