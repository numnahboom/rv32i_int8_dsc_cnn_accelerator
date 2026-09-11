# EdgeDSCNet-C10 D4 vstream v5 `mb16_down` XC7Z020 OOC 物理筛选（2026-09-10）

## 决策状态

**NEGATIVE_RESULT：功能与局部周期门通过；OOC 综合完成，但资源门失败，未进入 place/route。**

v5 的 `mb16_down` standalone block 在三种 Verilator 模式下都保持
byte-exact，no-backpressure 的 accepted-start 到最终输出排空周期为
`23,843`，满足 block 的 `<=25,000` 周期目标。新建的 OOC wrapper 也确实
保留了完整 candidate 接口并完成了 Vivado 2025.2 synthesis；但是
`xc7z020clg400-1` 综合结果已经需要 `264,810` Slice LUT（器件只有
`53,200`，`497.76%`），并产生 9 个综合后 `UTLZ-1` 资源错误。因此不能把
该结果称为 routed OOC、时序闭合或生产候选。

本报告只记录 v5 candidate 和本次 fresh OOC run；没有替换
`cnn_top`，没有改写 v3/v4/C0 或其他生产路径，也没有提交、reset、checkout
或清理工作树中的其他 dirty 路径。

## Candidate 范围与修复

本轮 OOC top 为
`edgembconv_hwacandidate_d4_vstream_v5_ooc_wrapper`。wrapper 直通
`edgembconv_hwacandidate_d4_vstream_v5_mb16_controller` 的 cfg/start、
done、byte output、word sink、计数器和 scratch 读服务端口，避免 OOC
边界把算术或输出服务常量折叠掉。约束只有 `clk` 的 `8.000 ns` 时钟，没有
path exception 或放宽的多周期约束。

初次综合使用单个 `scratch0` 数组，Vivado 报
`[Synth 8-3391] ... scratch0_reg ... number of bits (262144) is too large`，
因此该次没有综合资源结论。随后只在 v5 scheduler 内做了保持语义的存储
组织修复：

1. `scratch0` 改为 16 个 channel bank，每个 bank 为 `2,048 x 8-bit`；
   DW source 的 16-channel 读取仍对应同一个逻辑数据。
2. `scratch1` 改为 7 个 `2,048 x 32-bit` word read copies；project
   dedicated pass 的 7 个空间读取仍写入同一逻辑 word 的所有副本。
3. 保留原始 PW/DW MAC、RQ、final commit、word sink 和 ready/valid ledger，
   没有用少发 issue 或少提交输出来换取周期数。

修复后的 fresh synthesis run 是
`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt`；它使用
`flatten_hierarchy=rebuilt`、`RuntimeOptimized` 和实际生效的
`general.maxThreads=8`。初次 monolithic 失败的原始证据保留在
`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0215_baseline/`。

## 冻结 workload 与功能验收

| stage | operation | PW/DW MAC | RQ vectors | output |
|---|---|---:|---:|---:|
| expand | PW 16→32 | 524,288 | 8,192 | 32,768 intermediate bytes |
| depthwise | DW 3x3, 32 channels | 73,728 | 2,048 | 8,192 bytes |
| project | PW 32→32 | 262,144 | 2,048 | 8,192 final bytes |
| **total** |  | **PW 786,432 + DW 73,728** | **12,288** | **8,192** |

TB 强制检查 `pw_mac_count=786432`、`dw_mac_count=73728`、
`rq_accept_count=12288`、`dw_req=dw_resp=4418`、`final_commit=8192`、
`word_sink_fire=2048` 和 `byte_commit=8192`，并逐字节比对冻结 golden
output。随机 ready 下检查 sink 的 address/data/index/epoch 稳定性；
`V5_FINAL_WORD_STALL` 还在 `sink_index=2047` 将 `sink_ready` 拉低至少
32 cycles 后再释放。

| 模式 | cycles | sink stalls | PW MAC | DW MAC | RQ accepts | DW req/resp | final/words/bytes | errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| no-BP | 23,843 | 0 | 786,432 | 73,728 | 12,288 | 4,418/4,418 | 8,192/2,048/8,192 | 0 |
| random BP | 24,466 | 126 | 786,432 | 73,728 | 12,288 | 4,418/4,418 | 8,192/2,048/8,192 | 0 |
| final-word stall | 24,498 | 158 | 786,432 | 73,728 | 12,288 | 4,418/4,418 | 8,192/2,048/8,192 | 0 |

三次运行都打印 `PASS ... exact=8192 aligned_word_sink=2048`，
`sink_protocol_errors=0`，且 final-word stall 的稳定性断言通过。这里的
cycles 是 TB 从 accepted start 到 done/最终 sink drain 的实测口径，不是
静态 cycle model。

对应日志：

- [lint](../../build/d4_v5_ooc_repair3_lint_20260910.log)
- [no-BP](../../build/d4_v5_ooc_repair3_nobp_20260910.log)
- [random BP](../../build/d4_v5_ooc_repair3_bp_20260910.log)
- [final-word stall](../../build/d4_v5_ooc_repair3_finalstall_20260910.log)

Verilator lint 和三次仿真脚本均 exit `0`；日志保留现有非致命
`DECLFILENAME`、空 pin、latch 和 sequential blocking-assignment warnings，
没有把这些 warnings 隐藏成无诊断运行。

## Fresh Vivado 2025.2 OOC synthesis

| 项目 | 值 |
|---|---|
| run id | `20260910_0300_synth_rebuilt` |
| tool/device | Vivado 2025.2 / `xc7z020clg400-1` |
| top | `edgembconv_hwacandidate_d4_vstream_v5_ooc_wrapper` |
| clock | `clk`, 8.000 ns, 125 MHz |
| hierarchy/directive | `rebuilt` / `RuntimeOptimized` |
| threads | requested/actual `8/8` |
| synthesis | 0 errors, 0 critical warnings；32966 ordinary warnings |
| post-synth checkpoint | `v5_ooc_post_synth.dcp`，75,407,115 bytes |

### 资源与时序

| resource/timing | used/result | device/requirement | 判断 |
|---|---:|---:|---|
| Slice LUTs | 264,810 (`497.76%`) | 53,200 | **FAIL** |
| LUT as logic | 221,896 (`417.10%`) | 53,200 | **FAIL** |
| LUT as distributed RAM | 42,914 (`246.63%`) | 17,400 | **FAIL** |
| Slice registers/FF | 89,320 (`83.95%`) | 106,400 | **FAIL**（若按 `<70%` full-top reference） |
| F7 muxes | 95,431 (`358.76%`) | 26,600 | **FAIL** |
| F8 muxes | 44,936 (`337.86%`) | 13,300 | **FAIL** |
| DSP48E1 | 144 (`65.45%`) | 220；D4 block budget ≤146 | pass local DSP count |
| BRAM tile | 0 (`0%`) | 140 | pass count |
| setup WNS/TNS | `-5.930 ns` / `-28,469.662 ns` | WNS≥0, TNS=0 | **FAIL（synth estimate）** |
| setup failing endpoints | 7,426 / 313,524 | 0 | **FAIL（synth estimate）** |
| hold WHS/THS | `+0.210 ns` / `0 ns` | WHS≥0, THS=0 | pass hold at synth |

综合 timing summary 报出的最差 setup path 为
`u_candidate/u_arithmetic/ded_raw_phase_reg/C` 到
`u_candidate/u_arithmetic/u_pw112/gen_v2_pw_dsp[100].u_dsp/u_dsp48e1/A[10]`，
reported data-path delay 为 `10.124 ns`（logic `3.261 ns`、estimated route
`6.863 ns`）。该路径来自综合状态，包含 unplaced net 的估计，不能当作
post-route timing。

由于这是保持完整接口的 standalone OOC shell，XDC 只约束 `clk`，没有给
外部输入/输出端口建立 top-level I/O delay；timing summary 的 check_timing
因此记录了 61 个 no-input-delay 和 320 个 no-output-delay 项。这进一步
限定了该 WNS/TNS 只能作为内部时钟路径的综合筛选，不能外推为 full-top
时序签署。

`report_drc` 共发现 570 checks，其中 `UTLZ-1` 有 9 个 Error，分别覆盖
F7/F8、LUT logic、LUT memory/distributed RAM、LUT6、MUXF7、MUXF8 和
RAMD64E over-utilization。故“synth_design completed successfully”只表示
综合命令和 checkpoint 成功完成，不表示器件资源可放置。

## 映射诊断

综合层级报告给出：

| instance | LUT | LUTRAM | FF | DSP |
|---|---:|---:|---:|---:|
| `u_arithmetic` / v5 scheduler | 49,793 | 42,914 | 74,501 | 0 |
| `u_pool` / elastic RQ pool | 102,229 | 0 | 5,450 | 16 |
| `u_pw112` / dedicated PW island | 109,209 | 0 | 7,201 | 112 |
| `u_dw` / DW16 tile | 3,577 | 0 | 2,074 | 16 |

这说明当前负结果首先是综合映射和资源规模问题，而不是功能 ledger
失败：

- v5 scheduler 的 `scratch0_bank` 上仍出现 `Synth 8-7186`，即
  `ram_style="block"` 因该对象用法不满足 RAM inference 而被忽略；最终
  scheduler 的 42,914 memory LUT 被映射成 distributed RAM/RAMD64E。
- `scratch1` 的多空间行组合读也保留了宽 mux/分布式存储代价；此外
  `weight_mem_reg` 被 `Synth 8-4767` 报告为 registers，而不是 BRAM。
- `u_pool` 和 `u_pw112` 本身还分别占用约 102k/109k LUT；所以即使只
  处理 scratch RAM，当前 OOC top 仍不能直接视为可放置设计。

## 为什么停止在 synthesis

本次 Tcl 以 `synth_only` 结束；没有执行 `opt_design/place_design/
phys_opt_design/route_design`。在已有 497.76% LUT、358.76% F7 和
337.86% F8 的情况下继续 route 不会提供有筛选价值的物理结果，反而会
把资源门失败误写成 placement/route 时序问题。当前目录没有
`timing_summary_post_route.txt`、route status、congestion 或 power 报告。

因此本报告**没有**以下结论：

- post-route WNS/TNS/WHS/THS、route complete 或 unrouted=0；
- fullnet/full-top functional、资源、功耗或 GOPS/W；
- accuracy、训练恢复、板级运行或生产 `cnn_top` 替换。

下一步应先把 scratch/weight storage 改成真实单写/单读的 BRAM-compatible
时序接口，并重新通过同一套 semantic ledger、`<=25,000` cycles、8 ns
OOC 资源筛选；在资源门未通过前不应启动当前 v5 的完整 P&R。

## 可复现证据

- [source_manifest.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/source_manifest.txt)
- [run_settings.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/run_settings.txt)
- [utilization_synth.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/utilization_synth.txt)
- [utilization_hierarchical_synth.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/utilization_hierarchical_synth.txt)
- [timing_summary_synth.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/timing_summary_synth.txt)
- [drc_synth.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/drc_synth.txt)
- [vivado_console.txt](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/vivado_console.txt)
- [v5_ooc_post_synth.dcp](../../build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_synth_20260910_0300_synth_rebuilt/v5_ooc_post_synth.dcp)，SHA256 `895520E1F8082340F1EB8A6C3EAB8586AECBC55E88C01D9ACCFB4A1D0879868D`

## 当前文件 SHA256

以下哈希以 `20260910_0300_synth_rebuilt` 的当前工作树和 OOC source
manifest 为准；其中 Tcl、PowerShell runner、TB 和 filelist 作为复现入口
一并锁定。

| 文件 | SHA256 |
|---|---|
| `rtl/cnn/edgembconv_hwacandidate_d4_dsp_pool.v` | `21F57C636AA2CF2B224D3A1EF90619EF7046E752D2A84EC36E4FB75A464C4418` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool.v` | `E2187379F26B7FC06132CFC94662E087D0615F76C29A783457B447BAA5F31C6C` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v2_datapath.v` | `19D15CE2DB31DB7C6B70EBE718D82A3CF60779C5C64306B9E99C72F80C6CF75E` |
| `rtl/cnn/edgembconv_hwacandidate_d4_dw16_stream_tile.v` | `90CB4B89050F0BEBC2E57DEDE02D70ABF15302982B0135363E4645226C9C81F7` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v5_scheduler.v` | `100B8816249C151A1719AC4E2B8544D64196DB1A2044427DFDF8B0686D345DE1` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.v` | `247881C2E99A50802B2B7B8BA011ACF5BA79AB781DA64073BC8610AAE352D364` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v5_ooc_wrapper.v` | `A30117BDA86ECA076BAF995D1F91896E633242C157566557D79FF5AEF8F23557` |
| `constraints/edgembconv_hwacandidate_d4_vstream_v5_ooc_8ns.xdc` | `6295BF6F19BB2CD5A6BDCA6162121A91C98C82C977BCB67A21610F41C3A243AA` |
| `scripts/vivado_edgembconv_hwacandidate_d4_vstream_v5_ooc_20260910.tcl` | `E2CF330248C4D685593F641BA67679901C222C224C6E1C917518986913B02988` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v5_ooc_20260910.ps1` | `0EE019FCBF5803615B4955C5187518F415DE3451BEA2038AED0A1DE8DB1EBC47` |
| `sim/tb_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.v` | `D3D6D4B25D7B43EC4A2828461575CE807DAA6DD83FC300D4D7BC3F666A72EF07` |
| `sim/filelist_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.f` | `3AB360D4FA2AFC56AD7EE5E13263A9806341D3133499D07D5FBCEB431D31190C` |
