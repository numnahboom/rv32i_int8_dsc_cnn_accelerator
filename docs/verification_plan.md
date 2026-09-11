# Verification Plan

## Current gate status (2026-09-11)

Verification now has two explicitly separate tracks:

- C0 is the frozen complete-system control. Ten logits are exact; no-BP,
  response-2 and response-64 cycles are 219,970 / 268,503 / 1,902,452. The
  fully routed 8 ns full-top has WNS/TNS -0.880/-482.059 ns and WHS/THS
  +0.070/0, so setup and the 20 GOPS/W gate remain open.
- D4 is the network mainline. Software accuracy/ledger is frozen at 91.46%
  INT8, 11,645,440 MAC and 23,290,880 ops. Retained v6 candidate4 standalone
  regression is exact with 24,039 no-BP cycles, but OOC post-route WNS is
  -1.028 ns and no D4 full-network/full-top exists.

See `docs/reports/README.md` for the current evidence map. C0 results cannot
be relabelled as D4; a standalone or OOC PASS cannot close a full-network or
full-top gate.

本项目采用严格的分阶段门禁：一个模块必须先有 Python/integer golden 对照、
testbench 和 simulator PASS，才进入综合；只有资源和路径结构值得继续的候选
才进入 place/route。项目当前已停止推进，以下入口用于复核或未来恢复。

## D4 retained v6 gate

Required functional checks:

```text
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter_sim.sh
scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_sim.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_sim.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_finalstall.sh
scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_two_epoch.sh
```

Acceptance requires 8,192 output bytes / 2,048 sink words, PW/DW/RQ ledger
786,432 / 73,728 / 12,288, DW request/response 4,418 / 4,418, `errors=0`,
exactly-once under stalls, and no-BP `<=25,000 cycles`. Current candidate4
passes these checks.

Physical promotion remains separate: only a matching-source D4 full-top on
`xc7z020clg400-1`, Vivado 2025.2, 8.000 ns can establish final timing,
resources, power and energy efficiency. The current OOC result is not enough.

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

若 Verilator 批处理被终端或控制器超时中断，可在保留同一 `SIM_LOG_DIR` 的前提下
设置 `SIM_RESUME=1` 重跑。脚本只会复用包含该测试精确 `PASS <test>` 标记的旧日志；
其余测试照常执行，并在全部选定测试处理完后更新 `summary.csv`：

```bash
GENERATE_TEST_VECTORS=0 SIM_LOG_DIR=build/reports/verilator_final \
  SIM_RESUME=1 SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
```

默认不设置 `SIM_RESUME` 时，批处理行为和原有流程相同，`summary.csv` 会从本次运行重新开始。

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

## Windows XSim Streaming-Refactor Gate

The memory-oriented branch also provides a native Windows/Vivado gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_cnn_xsim.ps1
```

It compiles the CNN/common RTL from `sim/filelist_cnn_current.f`; the RTL is
compiled once and each selected TB is compiled incrementally.  The current gate
contains the refactored datapath tests, including bounds and tiled backpressure
coverage.  The exact final test count is emitted by the script rather than
hard-coded here.

Acceptance standard:

- every selected TB prints its own PASS token and the wrapper prints its PASS
  token only after all selected TBs pass;
- full-network SRAM logits match all 10 golden values and report the fresh
  `944568`-cycle / `0x0e69b882` result when run on the fixed reference vector;
- the fullnet oracle checks 78602 payload external reads plus 288 descriptor
  reads, 10 external writes, 115808 SRAM reads, and 102656 SRAM writes;
- bounds tests check every SRAM address transaction-by-transaction;
- tiled backpressure tests cover a single outstanding external read, 0..3
  idle-cycle response delay, ready stalls, and payload stability while stalled;
- a synthesis result is not accepted as a replacement for this functional gate.

At the time of this document update, the complete XSim run is complete:
`PASS cnn_xsim_regression tests=16` after recompiling 27 RTL files.  WSL
Verilator 5.020 independently passes the three high-risk current testbenches:
tiled Stem (16384 checks), tiled DSBlock (2256 checks), and the 7-case / 2191-
check tail-channel tile engine.  The full 38-test Verilator aggregation is not
yet an accepted gate because its controller invocation was time-limited; do
not represent the three directed passes as full-suite coverage.

## Memory Interface Assumptions

The external read interface permits one outstanding request.  A read response
may be arbitrarily delayed after its request handshake, but cannot be returned
in the same cycle; the earliest legal response is the next cycle.  Writes have
no response.  A stalled write keeps `{write, address, data}` stable.  AXI and
combinational-RAM adapters must register read data to provide this contract.

The phrase “0 idle-cycle response delay” in a backpressure test means that the
response appears in the first cycle *after* the handshake; it does not permit a
combinational same-cycle response.

`cnn_out_buffer` has a synchronous behavioral model for ordinary XSim and
Verilator.  Its XPM implementation is validated through synthesis structure;
ordinary simulators do not directly execute the XPM branch.

For a reproducible evidence set, preserve the wrapper log, `summary.csv` (for
Verilator), the fullnet metrics/CSV, and `git rev-parse HEAD` together.  A PASS
line from a previous commit, a different vector export, or an OOC synthesis run
is not a substitute for the corresponding gate on the exact RTL under review.
