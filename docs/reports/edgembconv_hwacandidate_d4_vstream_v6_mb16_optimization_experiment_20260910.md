# EdgeDSCNet-C10 D4 vstream v6 `mb16_down` candidate

## 决策状态

v6 完成了 standalone `mb16_down` 的功能与 ready/valid 验收。no-BP、随机
backpressure、最后一个 word 强制 stall，以及 two-epoch + done backpressure
均通过 byte-exact 检查和完整 semantic/service ledger。修正 DW scratch 物理
读请求的 `scratch_read_ready` 门控后，当前 source-manifest 下 no-BP
start-to-done 周期为 `24,030`，仍通过 `<=25,000` 周期门。

v6 仍不是生产 `cnn_top` 替换，也没有 full-network、板级、功耗、GOPS/W 或
训练结论。当前 13 个 RTL 源（包含 DW request adapter、fetch-pair 与
raw-FIFO）完成了新的 Vivado 2025.2 XC7Z020 synth-only：Slice LUT 为
`31,832 (59.83%)`，低于 `<37,240` 资源门；但 synthesis setup 仍失败
（WNS `-4.533 ns`、TNS `-5,767.454 ns`、4,805 个 failing endpoints），
所以本轮没有启动
place/route。旧的 `...0915_launcherfix` manifest 只有 10 个 RTL 源，漏列
fetch-pair/raw-FIFO，不作为当前 v6 完整候选的资源基线。

## 本轮变更边界

本轮只新增/修改 v6 candidate、registered-input pool、activation bank、独立
unit/OOC 验证及对应脚本；v3/v4/C0、`cnn_top`、runner 及其他 dirty 路径保持
不动。v5 仅重跑既有对照 TB 以确认诊断输出已清理。

1. v6 TB 将 sink epoch 改为 epoch-local 检查，增加 pool 总 input/output、
   PW/RQ 分 mode conservation、两 epoch counter reset、done_valid 持续
   backpressure 和 final-word stall 验收。
2. 新增 `edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin`。该
   shell 在 pool 前捕获被接受的 mode、operand、metadata 和 RQ tags；当
   pool 消费旧项时可同边沿替换新项，保持同一 mode 下 II=1。底层仍只有
   16 个 DSP48E1，且保留原有 DSP `PREG=1`。
3. v6 scheduler 使用 registered-input pool；新增独立 II/tag/mode contract
   TB 与 registered-input pool 的 XC7Z020 OOC synthesis entrypoint。
4. 新增 `edgembconv_hwacandidate_d4_vstream_v6_banked_storage` 的独立
   activation storage boundary。behavioral TB 覆盖 8 input banks、16
   scratch0 banks、scratch1 的 0..6 vector banks、独立 bank-7 pool bank、
   synchronous response hold 及 same-edge behavioral write-first bypass；
   synthesis 通过 XPM block-RAM instances 验证物理映射。
5. 修复 pool source 在最终 K 后继续发起物理读的问题：expand/project
   分别限制在 K15/K31，并抑制 final response 后的残余请求，避免 RQ fence
   跨 context 污染；修复后 no-BP 仍保持 byte-exact。
6. 新增 `edgembconv_hwacandidate_d4_vstream_v6_fetch_pair` 的独立请求/响应
   配对 contract TB；请求描述符在 activation/weight 两路共享，只有同描述符
   的双响应才可消费，并覆盖真实 pending-response stall、K15/K31、bubble 和
   epoch/slot context switch。
7. 新增 `edgembconv_hwacandidate_d4_vstream_v6_raw_fifo` 的独立 FIFO TB 与
   filelist/launcher；覆盖 16-lane burst、同步 response hold、full/empty、
   circular wrap、full 边界同边沿 push/pop 及独立队列 no-overwrite 检查。

## 冻结 workload 与 ledger

| 项目 | 要求/观测 |
|---|---:|
| PW MAC | `786,432` |
| DW MAC | `73,728` |
| RQ accepts | `12,288` |
| DW source request/response | `4,418 / 4,418` |
| final byte commits | `8,192` |
| accepted sink words | `2,048` |
| pool input/output | `14,336 / 14,336` |
| pool PW input/output | `2,048 / 2,048` |
| pool RQ input/output | `12,288 / 12,288` |
| pool conservation errors | `0` |

所有冻结 golden output bytes 均逐 word 比较；sink 在 stall 时的
data/address/index/epoch 也保持稳定。

## 功能与服务结果

| 模式 | epoch | cycles | sink stalls | words/bytes | errors |
|---|---:|---:|---:|---:|---:|
| no-BP | `0xA` | 24,030 | 0 | 2,048 / 8,192 | 0 |
| random BP | `0xA` | 25,374 | 126 | 2,048 / 8,192 | 0 |
| final-word stall | `0xA` | 25,406 | 158 | 2,048 / 8,192 | 0 |
| two-epoch + done BP | `0xA` | 25,374 | 126 | 2,048 / 8,192 | 0 |
| two-epoch + done BP | `0xB` | 25,375 | 126 | 2,048 / 8,192 | 0 |

two-epoch 测试在每个 epoch 重新检查同一 ledger，并在 `done_valid` 上保持
`done_ready=0` 17 个周期，期间 `done_valid` 与 `done_epoch` 稳定。第二次
start 不重新配置 memories，仍得到相同的算术与 sink 结果。

registered-input pool 的独立 contract TB 结果为：

```text
POOL_REGIN_STATS accepted=40 produced=40 pw=32 rq=8 ii1_gaps=0 cycles=64 errors=0
PASS edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin ii=1 tag_mode_exact
```

独立 activation bank unit TB 结果为：

```text
PASS edgembconv_hwacandidate_d4_vstream_v6_banked_storage maps=8+16+7+pool handshake=hold+bypass
```

对应 v6 release lines：

```text
D4_V6_MB16 epoch=10 words=2048 bytes=8192 cycles=24030 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0 sink_errors=0 child_overlap=11379 errors=0 dw_rq=2048 p_rq=2048
D4_V6_MB16 epoch=10 words=2048 bytes=8192 cycles=25374 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=126 sink_errors=0 child_overlap=11379 errors=0 dw_rq=2048 p_rq=2048
D4_V6_MB16 epoch=10 words=2048 bytes=8192 cycles=25406 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=158 sink_errors=0 child_overlap=11379 errors=0 dw_rq=2048 p_rq=2048
D4_V6_MB16 epoch=10 words=2048 bytes=8192 cycles=25374 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=126 sink_errors=0 child_overlap=11379 errors=0 dw_rq=2048 p_rq=2048
D4_V6_MB16 epoch=11 words=2048 bytes=8192 cycles=25375 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=126 sink_errors=0 child_overlap=11379 errors=0 dw_rq=2048 p_rq=2048
PASS edgembconv_hwacandidate_d4_vstream_v6_mb16_controller exact=8192 aligned_word_sink=2048
```

独立 A-path 配对与 B-path raw FIFO contract TB 结果为：

```text
PASS edgembconv_hwacandidate_d4_vstream_v6_fetch_pair one_cycle=1 burst=K15+K31 bubble=1 stall_hold=1 context_switch=1 requests=96 responses=96
PASS edgembconv_hwacandidate_d4_vstream_v6_raw_fifo depth=4 lanes=16 burst=1 stall_hold=1 full_empty=1 wrap=1 same_edge_push_pop=1 no_overwrite=1 pushes=10 responses=10
```

raw FIFO TB 使用 `DEPTH=4` 参数化小深度快速覆盖 circular 边界；生产实例仍
使用默认 `DEPTH=64`，并由 16 个 `64 x 32` XPM simple-dual-port RAM lane 映射。

DW request adapter 的独立 TB 在清理临时诊断输出后重新通过：

```text
PASS edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter jobs=2 halo=K4+K5+K7+K8 interior=K0..K8 mem_stall=1 resp_stall=1 service_stall=1 requests=26 responses=26
```

该 TB 同时覆盖 `mem_req_ready`、响应 backpressure 与 service stall，并检查
请求/响应地址与数据稳定性、exactly-once conservation 和 protocol errors=0。

## 独立 registered-input pool OOC synthesis

新建的 OOC run：
`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_synth_20260910_0445_regin/`

目标为 `xc7z020clg400-1`、8.000 ns、`general.maxThreads=8`，top 为
`edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_wrapper`。

| synthesis resource | used | device | gate |
|---|---:|---:|---|
| Slice LUTs | 3,110 (5.85%) | 53,200 | pass `<70%` |
| Slice Registers | 11,233 (10.56%) | 106,400 | pass `<70%` |
| DSP48E1 | 16 (7.27%) | 220 | pass; pool contract 16 |
| BRAM tile | 0 (0%) | 140 | pass |

该 island synthesis timing 不是 closure 证据：WNS `-1.091 ns`，TNS
`-699.497 ns`，hold worst slack `+0.252 ns`。本轮没有对该 island 做
post-route claim。

## Activation bank 与完整 v6 OOC synthesis

新鲜 full candidate synthesis run（13 个 RTL 源，包含 DW request adapter、
fetch-pair/raw-FIFO，
带 SHA256 manifest）：
`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/`

PowerShell launcher 使用全新 `RunId` 完成 synth-only 并输出 `PASS`；Vivado
console 末尾的 synthesis summary 为 `0 errors`，并记录
`V6_OOC_SYNTH_DONE`。console 中另有一条非致命的
`Common 17-1257 Failed to create directory 'C'` 行；它未阻止 DCP、timing
与 utilization reports 生成，故原始 console 保留在证据目录中。本目录的
`source_manifest.txt` 记录了 13 个 RTL 源和 XDC 的 SHA256；独立校验结果为
`manifest_sources=14 mismatches=0`。

本 run manifest 的 SHA256 摘要如下（完整原文仍以 manifest 为准）：

| source | SHA256 |
|---|---|
| `rtl/cnn/edgembconv_hwacandidate_d4_dsp_pool.v` | `21F57C636AA2CF2B224D3A1EF90619EF7046E752D2A84EC36E4FB75A464C4418` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool.v` | `E2187379F26B7FC06132CFC94662E087D0615F76C29A783457B447BAA5F31C6C` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin.v` | `EC95DDE8731858DB42E82EAC7156A6B66E12D9D27AA92831C0CBCAEDAA46AE90` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_banked_storage.v` | `06E2EDFB9B2866262CC3E286C484F4CCE70F5D9ED4A54D94014601E02E179241` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_common_bank.v` | `76CFF53C369085854CEFB86F8BD264FB40DCE6F33042553B579BF4A5EEFA758E` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_fetch_pair.v` | `593DC34B8E520FB8C9946AF74130DCDA17673866FF1137DACF673EF74466A26E` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_raw_fifo.v` | `CF59323C715CE3726501E6635A15C025E9B170E93096DF438F294DD361AC9FE0` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter.v` | `EF07D151477EF5267E3AF4185047BC45C85E1BB4C4176760A4077A030ADF376A` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v2_datapath.v` | `19D15CE2DB31DB7C6B70EBE718D82A3CF60779C5C64306B9E99C72F80C6CF75E` |
| `rtl/cnn/edgembconv_hwacandidate_d4_dw16_stream_tile.v` | `90CB4B89050F0BEBC2E57DEDE02D70ABF15302982B0135363E4645226C9C81F7` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_scheduler.v` | `B903E0D66032A0EE7EDBC7B7E412C6EBD8E7F10ED249B260A07AF8EF68E5AC20` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_mb16_controller.v` | `9C3AD7C275C48B20B2EDEB7814144AC12BF29AAB31FCE73C33078F18EADD0CF6` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_ooc_wrapper.v` | `BC19BCD5416E6AB9258189388105B7073E4CDE596A0BDE2519F01844D975A93F` |
| `constraints/edgembconv_hwacandidate_d4_vstream_v6_ooc_8ns.xdc` | `3F6F3FB524A568B5066D7ECCDA0B260582C760268E94E7CB33F2AC7499C5CF23` |

| synthesis resource | used | device | decision |
|---|---:|---:|---|
| Slice LUTs | 31,832 (59.83%) | 53,200 | pass `<37,240` |
| LUT as logic | 30,902 (58.09%) | 53,200 | pass local `<70%` |
| LUT as distributed RAM | 930 (5.34%) | 17,400 | pass local `<70%` |
| Slice Registers | 24,635 (23.15%) | 106,400 | pass local `<70%` |
| DSP48E1 | 144 (65.45%) | 220 | pass local DSP budget `<=146` |
| BRAM tile | 28 (20.00%), RAMB18=56 | 140 | pass local count |

`synth_cell_counts.txt` 给出 `synth_cells=71,848`、`synth_lut_cells=32,218`、
`synth_ff_cells=24,635`、`synth_dsp48e1_cells=144`、
`synth_ramb_cells=56`、
`synth_banked_storage_ramb_cells=32` 和
`synth_common_bank_ramb_cells=8`。Vivado synthesis log 的 Block RAM
Preliminary Mapping 列出 raw FIFO 的 `gen_raw_lane[0..15].u_mem` 共 16 个
`64 x 32` XPM block-RAM 实例，并列出
`u_v6_banked_storage/gen_input_xpm[0..7]`、
`gen_scratch0_xpm[0..15]`、`gen_scratch1_xpm[0..6]` 及独立
`u_scratch1_pool_mem` 的 XPM block-RAM implementations；这是当前 13 源
manifest 对应的真实 mapping 证据。

该候选 synthesis setup 为 4,805 个 failing endpoints，WNS `-4.533 ns`、
TNS `-5,767.454 ns`；hold 为 0 个 failing endpoints、worst slack
`+0.210 ns`。当前资源门虽已通过，但本 run 没有执行
`opt_design/place_design/phys_opt_design/route_design`；
setup timing 仍未通过，因此没有 post-route WNS/TNS、route complete、
congestion 或 power 结论。

## 证据边界与下一步

本报告支持 v6 standalone `mb16_down` 的功能 exactness、真实 local
cycles、sink/epoch stability、pool conservation、two-epoch reset、done
backpressure、registered-input pool II=1 contract、activation bank unit
contract、fetch-pair/raw-FIFO unit contract，以及当前 13 源完整候选的 OOC
资源快照。资源门在当前 source manifest 下通过，但 synthesis setup timing
仍失败；它不支持时序 closure、post-route、full-top、硬件或能效结论。

完整候选应先停止在当前 synthesis timing gate，下一阶段只做真实单写/单读的
BRAM-compatible input/scratch/weight/FIFO storage 与局部宽 mux/fanout 重构，
并重新执行同一 semantic ledger 和 `<=25,000` cycle gate；setup timing 未
解决前不把 OOC 结果外推为 post-route 或 full-top closure。

## 可复现入口与证据

本次 `scratch_read_ready` 与 DW request adapter 修正后的控制器结果由以下
launcher 直接重跑得到；
下列旧的 `after_cleanup`/`stagec_rerun` 日志保留作历史快照，不用于本报告当前
的周期数字。

- `scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp.sh`
- `scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_sim.sh`
- `scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_finalstall.sh`
- `scripts/run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_two_epoch.sh`
- `scripts/run_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter_sim.sh`

- `build/v6_nobp_latest.log`
- `build/v6_random_bp_latest.log`
- `build/v6_finalstall_latest.log`
- `build/v6_two_epoch_latest.log`
- `build/verilator_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter/`
- `build/d4_v6_lint_after_cleanup_20260910.log`
- `build/d4_v6_nobp_after_cleanup_20260910.log`
- `build/d4_v6_random_after_cleanup_20260910.log`
- `build/d4_v6_finalstall_after_cleanup_20260910.log`
- `build/d4_v6_two_epoch_after_cleanup_20260910.log`
- `build/d4_v6_banked_storage_unit_20260910.log`
- `build/d4_v6_banked_storage_lint_20260910.log`
- `build/d4_v6_fetch_pair_unit_20260910.log`
- `build/d4_v6_raw_fifo_unit_20260910.log`
- `build/d4_v6_lint_stagec_rerun_20260910.log`
- `build/d4_v6_nobp_stagec_rerun_20260910.log`
- `build/d4_v6_random_stagec_rerun_20260910.log`
- `build/d4_v6_finalstall_stagec_rerun_20260910.log`
- `build/d4_v6_two_epoch_stagec_rerun_20260910.log`
- `build/d4_v5_nobp_after_cleanup_20260910.log`
- `build/d4_v5_finalstall_after_cleanup_20260910.log`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_synth_20260910_0445_regin/synth_cell_counts.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_synth_20260910_0445_regin/utilization_synth.txt`
- `build/d4_v6_ooc_synth_independent_20260910.log`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/source_manifest.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/synth_cell_counts.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/utilization_synth.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/utilization_hierarchical_synth.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/timing_summary_synth.txt`
- `build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_104727/vivado.log`

工作树保持 dirty；本轮没有 commit、reset、checkout 或 clean。
