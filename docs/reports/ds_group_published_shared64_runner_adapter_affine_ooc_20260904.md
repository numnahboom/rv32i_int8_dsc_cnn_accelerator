# affine 地址映射候选验证（2026-09-04）

## 结论

`ds_group_feature_word_address_adapter` 的 affine 候选完成了真实六形状仿真、Vivado 2025.2 XC7Z020 综合及 8 ns OOC 完整布局布线。仿真和实现流程均完成，但该候选是 **NEGATIVE_RESULT**：post-route setup 时序仍不达标，不能进入 `cnn_top`/full-top 集成。

这是 bridge-only OOC 证据，不是 full-top closure，也不代表完整 C0 推理已达标。

## 验证阶段与耗时

| 阶段 | 实际结果 | 实际耗时/时间证据 |
|---|---|---|
| 六形状真实 producer 仿真 | PASS | launcher wall time 约 30 s |
| synth-only | 0 errors；生成 DCP | Vivado 23:56:16–23:58:58，约 2m42s；`synth_design` elapsed 2m15s |
| synth DCP 查询 | 生成综合时序/功耗/层次资源 | 23:59:38–00:00:25，约 47s |
| opt/place/phys_opt/route OOC | route 成功、0 routing errors | 00:01:05–00:19:30，约 18m25s；`route_design` elapsed 450.341s |
| 定向 source/producer timing 查询 | 生成三份 crossing/endpoint 报告 | 约 00:20:39–00:24:06 |

## 功能与周期证据

命令：

```text
bash scripts/run_ds_group_published_shared64_runner_adapter_sim.sh
```

结果：

```text
PASS six-shape real-producer ledger source_words=32034 output_words=21504
```

各 shape `perf_cycles` 为 `33342 / 25690 / 34620 / 17018 / 26084 / 20670`，总计 **157424 cycles**。交通计数为 21504 output words、32034 source words；六形状语义工作量仍为 4,194,304 MAC / 8,388,608 operations。配置 ABI 的 35,072 个 scalar writes 若计入端到端账本，则总计 **192496 cycles**。

## 综合结果

来源：

```text
build/reports/vivado_ds_group_published_shared64_runner_adapter_synth_20260903/
build/reports/vivado_ds_group_published_shared64_runner_adapter_synth_query_20260903/
```

综合资源：LUT 14,438/53,200 (27.14%)、FF 34,382/106,400 (32.31%)、BRAM 38.5/140 (27.50%，35 RAMB36 + 7 RAMB18)、DSP 123/220 (55.91%)。综合查询时序为 WNS -1.505 ns、TNS -1486.001 ns、WHS +0.194 ns；这是 synthesized 状态，不是最终实现结论。综合 vectorless total power 为 0.527 W，不能替代 post-route 功耗。

## Post-route 结果

来源：

```text
build/reports/vivado_ds_group_published_shared64_runner_adapter_route_20260903/
```

| 项目 | post-route 结果 | 判定 |
|---|---:|---|
| 时钟 | 8.000 ns / 125.000 MHz | 约束正确 |
| WNS / TNS | **-1.618 ns / -2289.723 ns**；3179/77896 endpoints failing | **NO-GO** |
| WHS / THS | +0.089 ns / 0 | hold 通过 |
| Routing | 45652/45652 fully routed；0 routing errors | 通过 |
| LUT | 12996/53200 = 24.43% | 通过 |
| FF | 32159/106400 = 30.22% | 通过 |
| BRAM | 38.5/140 = 27.50% | 通过 |
| DSP | 123/220 = 55.91% | 通过 |
| Total on-chip power | 0.316 W（dynamic 0.208 W，static 0.108 W，medium confidence） | 通过 |
| DRC | 0 errors；270 checks 为 warning（DPIP/DPOP/RTSTAT/ZPS7） | 无 error |

最终最差 setup path 位于 shared sweep/scratch BRAM，而非 source adapter：

```text
u_sweep/pw_row_block_q_reg[0]_replica/C
 -> u_sweep/gen_scratch_bram[0].u_scratch_mem/.../ADDRARDADDR[7]
WNS=-1.618 ns, data delay=8.968 ns (logic=1.448 ns, route=7.520 ns), 8 logic levels
```

## affine 控制锥证据

定向报告：

```text
source_adapter_paths_max.txt
source_to_producer_paths_max.txt
producer_endpoint_paths_max.txt
```

`source_to_producer_paths_max.txt` 的最差 crossing 是 `u_source_adapter/rd_ptr_reg[1]/C` 到 producer bank write-data register，slack **+2.016 ns**、data delay 5.637 ns、仅 LUT3/LUT5/LUT6/MUXF7 四级逻辑；没有动态除法/取模/乘法单元进入该 crossing。`producer_endpoint_paths_max.txt` 的 producer 端最差路径为 -0.216 ns、9 级 LUT/MUX 逻辑，亦没有 DSP/CARRY 地址算术。

source adapter 内部仍有一个 prep/初始 pixel-base 路径（`source_y_reg` 到 `pixel_base_reg[0]`）为 -0.343 ns，包含 5 个 CARRY4 和 1 个 DSP48E1；这是上下文准备的本地路径，不是 steady-state producer request-ready/address crossing。该事实不能被省略，且说明 affine 候选并非整个模块完全没有乘法资源。

## 能效边界

以 post-route 0.316 W、125 MHz 和真实六形状 8,388,608 operations 计算：

- 只计 `start`–`done` 的 157424 cycles：约 6.661 GOPS、21.079 GOPS/W；
- 加入必须计入的 35,072 scalar configuration writes 后为 192496 cycles：约 5.447 GOPS、**17.238 GOPS/W**。

因此不能用排除配置阶段的数字宣称端到端能效达标。当前 bridge 也没有完整单次 C0 logits/fullnet 证据；不得据此宣称 ≤2M cycles 或 full-top closure。
