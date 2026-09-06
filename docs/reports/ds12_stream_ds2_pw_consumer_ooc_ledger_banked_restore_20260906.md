# DS2 PW consumer ledger-banked restore — frozen evidence (2026-09-06)

结论：**DONE（源码恢复、功能回归和 fresh XC7Z020 OOC 均完成）**。本报告
冻结的是 DS2 PW consumer 隔离模块证据；OOC 的 setup WNS 仍为负，因此不能
称为 timing closure，也不能外推为 full-top/full-network、功耗、能效或硬件
闭合结果。

## 恢复对象与边界

- 唯一恢复的 RTL 是
  `rtl/cnn/ds12_stream_ds2_pw_consumer.v`；外部接口、DW handshake/tag/epoch、
  `dw_valid` 门控、64-MAC/token 口径和 sink 输出协议保持不变。
- `ds12_stream_ds2_slot_ledger_entry` 已移除，改为 4 个
  `ds12_stream_ds2_slot_ledger_bank` 实例；每个 bank 是 8-entry 的
  array-backed ledger（`state/context/owner/epoch/seen`）。父模块按
  `input_group[4:3]` 做 one-hot bank 选择，并将 `dw_valid` 仅送入选中的
  bank；tag/epoch 比较、duplicate-slice 过滤和状态更新留在本地 bank。
- 未改动 DS1、DS3-DS6、full-top 集成或系统接口。当前工作树原有的其他
  dirty/untracked 路径不属于本报告的冻结范围。

源码身份：

```text
path   = rtl/cnn/ds12_stream_ds2_pw_consumer.v
bytes  = 48001
lines  = 1087
SHA256 = 37253EC01289BCBC1E961993D82845204FF7AF28864CF2D97FE2E754066DC788
modules = ds12_stream_ds2_pw_consumer,
          ds12_stream_ds2_slot_ledger_bank,
          ds12_stream_ds2_pw_dsp_accum
```

OOC 的固定 source manifest 只有该 RTL：
`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/source_manifest.txt`。

## 功能回归

四项回归均通过；以下保留实际 PASS 行及关键计数：

```text
DS12_DS2_PW_PASS byteexact=1 weight_map=512/512 weight_prefetch=65536/65536 cfg_reads=704 weight_reads=512 dw_vectors=512 dw_commits=512 pw_tokens=8192 mac=524288 output_words=4096 partial_context_peak=15 span=8987 active_cycles=8192 compute_segments=32 last_pending=32 result_pending=32 dsp_width_errors=0 k_seq_errors=0 errors=0 error=0 error_code=00 cfg_error=0 dw_input_gaps=16 dw_ready_stalls=0 sink_stalls=625
DS12_DS2_PW_PROTOCOL_PASS duplicate_ignored=1 mismatched_tag_epoch_rejected=1 cfg_reads=704 dw_vectors=2 error_code=04
PURE_TWO_LAYER_REAL_PASS start_to_done=23075 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576 mismatches=0 errors=0
PURE_TWO_LAYER_REAL_PASS start_to_done=33109 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576 mismatches=0 errors=0
```

对应回归入口：

```text
bash scripts/run_ds12_stream_ds2_pw_consumer_sim.sh
bash scripts/run_ds12_stream_ds2_pw_consumer_protocol_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_sim.sh
bash scripts/run_ds12_stream_pure_two_layer_top_random_bp.sh
```

保存的回归日志包括：

- `build/ds12_stream_harness/direct_bank_select_20260906.log`
- `build/ds12_stream_harness/protocol_bank_select_20260906.log`
- `build/ds12_stream_pure_two_layer_top/run_timing_pipeline_20260906.log`
- `build/ds12_stream_pure_two_layer_top_random_bp/run_timing_pipeline_20260906.log`

## Fresh Vivado 2025.2 OOC

固定配置：`xc7z020clg400-1`、top `ds12_stream_ds2_pw_consumer`、`clk=8.000 ns`、
out-of-context synth/place/phys_opt/route，`general.maxThreads=8`，
RuntimeOptimized/Explore/Explore/Explore。运行设置见：
`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/run_settings.txt`。

### Post-route 结果

| 指标 | 值 |
| --- | ---: |
| Slice LUTs | 9,248 |
| LUT as logic | 6,514 |
| LUT as distributed RAM | 2,734 |
| Slice registers | 6,921 |
| RAMB36E1 | 16 |
| RAMB18E1 | 8 |
| DSP48E1 | 80 |
| WNS | -0.155 ns |
| TNS | -2.529 ns |
| setup failing endpoints | 54 / 39,245 |
| WHS | +0.108 ns |
| THS | 0 ns |
| routable / fully routed | 19,348 / 19,348 |
| routing errors | 0 |

权威产物：

- log：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/vivado_restore.log`
- post-route timing：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/timing_summary_post_route.txt`
- post-route utilization：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/utilization_post_route.txt`
- route status：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/route_status_post_route.txt`
- post-synth DCP：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_synth.dcp`
- post-route DCP：`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906/ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_route.dcp`

## 被否决候选的封存

one-hot ledger 候选没有覆盖当前恢复源码，单独保留在：

`build/reports/vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_onehot_20260906/source_onehot_negative_20260906.v`

```text
bytes  = 53480
SHA256 = BF4190198A4DD58E2762FE3E86E7FAB161D3BA907F9FA0536154FF4D4F0180CB
post-route WNS/TNS/WHS = -0.965 ns / -178.772 ns / +0.148 ns
setup failing endpoints = 787 / 39029
```

该快照只作 negative candidate 追溯，不得覆盖本报告所冻结的
`ds12_stream_ds2_pw_consumer.v`。

## 证据限制与交接

- 这是 isolated DS2 PW consumer OOC，不是 full-top/full-network implementation，
  没有板级运行或实测功耗/能效证据。
- setup timing 未闭合（WNS/TNS 为负）；hold timing 和布线状态通过，但不能
  将其解释为 100/125 MHz 系统级 closure。
- 本收尾只新增本报告，不执行 reset/checkout/clean，不执行 seed sweep，不提交
  任何文件。
