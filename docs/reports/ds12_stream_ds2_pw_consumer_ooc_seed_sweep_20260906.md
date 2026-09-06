# DS2 PW consumer OOC seed-labelled sweep（2026-09-06）

结论：**NEGATIVE_RESULT**。对已完成功能验证的
`ds12_stream_ds2_pw_consumer` banked-ledger post-synthesis DCP，使用四个固定
尝试标签 `2, 3, 7, 11` 完成 XC7Z020、8 ns 的独立
`place_design` / `phys_opt_design` / `route_design`。四次都完整布线并生成
post-route DCP，但四次 setup 结果均为 `WNS=-0.160 ns`，没有达到
`WNS>=0` 的 125 MHz setup closure。

这是隔离 module OOC 证据，不是 full-top、full-network、功耗、能效、板级或
硬件闭合证据。

## 扫描边界与 seed 语义

- 工具：Vivado 2025.2，part `xc7z020clg400-1`，top
  `ds12_stream_ds2_pw_consumer`，clock period `8.000 ns`。
- 每次从同一个 immutable post-synthesis DCP
  `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_synth.dcp`
  重新 `open_checkpoint`，不重复综合。
- 每次使用 `place_directive=Explore`、`phys_opt_directive=Explore`、
  `route_directive=Explore`，`general.maxThreads=8`。
- 本 slice 未修改 RTL、TB、接口或 dataflow；只新增扫描脚本、尝试清单和
  结果报告。
- Vivado 2025.2 的非 project `place_design` / `route_design` 不支持本脚本
  所需的显式 seed 属性；每个 attempt 的
  `seed_property_audit.txt` 均记录：

  ```text
  GET place.seed=UNSUPPORTED
  GET route.seed=UNSUPPORTED
  ```

  因此 `2/3/7/11` 是可复现的尝试标签，不伪造为工具控制的随机 seed；
  `seed_mode=label_only` 已写入所有结果。

## 结果

闭合接受条件为：route 完整、post-route DCP 存在、`WNS>=0` 且 `WHS>=0`。
所有尝试均 route 完成且 hold 通过，但 setup 仍失败。

| 标签 | place/phys_opt/route | WNS (ns) | TNS (ns) | WHS (ns) | THS (ns) | setup failing endpoints | LUT | FF | BRAM tile | DSP | route | 接受 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 2 | PASS/PASS/PASS | -0.160 | -8.447 | +0.068 | 0.000 | 108 | 9,188 | 6,870 | 20 | 80 | 19,195/19,195，0 errors | 否 |
| 3 | PASS/PASS/PASS | -0.160 | -8.447 | +0.068 | 0.000 | 108 | 9,188 | 6,870 | 20 | 80 | 19,195/19,195，0 errors | 否 |
| 7 | PASS/PASS/PASS | -0.160 | -8.447 | +0.068 | 0.000 | 108 | 9,188 | 6,870 | 20 | 80 | 19,195/19,195，0 errors | 否 |
| 11 | PASS/PASS/PASS | -0.160 | -8.447 | +0.068 | 0.000 | 108 | 9,188 | 6,870 | 20 | 80 | 19,195/19,195，0 errors | 否 |

因此 `attempts_requested=4`、`attempts_completed_route=4`、
`closure_found=0`。四次的资源和 timing 行完全一致；本扫描没有发现通过
标签变化获得 setup closure 的迹象。BRAM tile 为 16 个 RAMB36/FIFO 加
8 个 RAMB18，DSP 为 80。

## 产物与复现

脚本和尝试清单：

- `scripts/vivado_ds12_stream_ds2_pw_consumer_ooc_seed_sweep_20260906.tcl`
- `scripts/ds12_stream_ds2_pw_consumer_ooc_seed_sweep_20260906.txt`

汇总与边界声明：

- `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_seed_sweep_20260906/seed_sweep_summary.tsv`
- `build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_seed_sweep_20260906/sweep_result.txt`

每个 `attempt_0*_label_*` 目录都包含 timing、utilization、route-status、
result、manifest、seed-property audit 和
`ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp`。由于本次没有接受的
尝试，输出目录没有 `best/`；脚本已包含未来出现闭合时复制首个接受尝试的
DCP、报告和选择元数据的逻辑。

复现命令：

```powershell
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source (Resolve-Path 'scripts\vivado_ds12_stream_ds2_pw_consumer_ooc_seed_sweep_20260906.tcl') `
  -log (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_seed_sweep_20260906')\sweep.vivado.log `
  -journal (Resolve-Path 'build\reports\vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_seed_sweep_20260906')\sweep.vivado.jou
```

该结果只说明当前 banked-ledger OOC post-route 在四个独立标签尝试中稳定地
留下约 `160 ps` setup 缺口；不能据此宣称 full-top timing、功耗、能效或
硬件成功。
