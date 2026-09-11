# EdgeDSCNet-C10 D4 vstream v5 `mb16_down` candidate

## 决策状态

v5 是一个已完成 Verilator 功能/服务验收的 D4 block candidate：冻结的
`mb16_down` workload 在 no-backpressure、随机 backpressure 和强制最后一个
word stall 三种模式下均 byte-exact，且 semantic/service ledger 全部相等。
no-backpressure 实测 start-to-final-output 周期为 `23,843`，通过 D4 block
合同的 `<=25,000` 周期门。

这只是 standalone block evidence。v5 尚未替换生产 `cnn_top`，也没有建立
完整 D4 网络、XC7Z020 full-top post-route、资源、功耗、GOPS/W 或训练证据。

## v5 变更边界

本轮只新增/修改 v5 candidate 路径；没有改动 v3、v4、C0、`cnn_top` 或
shared pool 的既有路径。

1. scheduler 增加两个 64-word bank 的对齐 32-bit output service。每个
   project RQ 结果直接形成一个 sink word，bank 只有在两个 channel group
   的 64 个 word 均写完后才 publish；另一个 bank 可按全局 word index drain。
   sink 仍要求四字节对齐、`byte_enable=4'b1111`，并在 stall 期间保持
   data/address/index/epoch 稳定。
2. project raw PW accumulation 启用已有 16-DSP elastic pool；dedicated
   112-DSP PW island 保持原路径和 semantic ledger。两类 PW 工作在同一
   cycle 的计数中分别累计，不能以少发 issue 代替 semantic MAC。
3. DW source service 允许 response 与下一条 request 在同一 edge 发生。
   capture/issue 使用单调独立计数，raw slot 保存每个 quad 的 response
   count；这避免 RQ 暂停后的 slot reuse、重复第五个 quad 和 capture/issue
   边界混淆。source capture 只在对应 expansion fence 满足后启动。

## 冻结 workload 与 semantic ledger

| stage | operation | PW/DW MAC | RQ vectors | final/output bytes |
|---|---|---:|---:|---:|
| expand | PW 16->32 | 524,288 | 8,192 | 32,768 intermediate |
| depthwise | DW 3x3, 32 channels | 73,728 | 2,048 | 8,192 |
| project | PW 32->32 | 262,144 | 2,048 | 8,192 final |
| **total** |  | **PW 786,432 + DW 73,728** | **12,288** | **8,192** |

The testbench requires `pw_mac_count=786432`, `dw_mac_count=73728`,
`rq_accept_count=12288`, `dw_req=dw_resp=4418`, `final_commit=8192`,
`word_sink_fire=2048`, and `byte_commit=8192`. It also compares every frozen
golden output byte and checks the sink payload/tag stability while stalled.
`dw_start=8` denotes eight 8x8 source commands; it does not reduce the 73,728
DW arithmetic operations.

## Candidate source manifest

| file | SHA256 |
|---|---|
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v5_scheduler.v` | `006B4F05C5ADC113D5CA194D849ECCA2364E29A9B1381D506B01ACCB85F0B738` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.v` | `247881C2E99A50802B2B7B8BA011ACF5BA79AB781DA64073BC8610AAE352D364` |
| `sim/tb_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.v` | `D3D6D4B25D7B43EC4A2828461575CE807DAA6DD83FC300D4D7BC3F666A72EF07` |
| `sim/filelist_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller.f` | `3AB360D4FA2AFC56AD7EE5E13263A9806341D3133499D07D5FBCEB431D31190C` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller_nobp.sh` | `26F2C9E4BB2A2D237C33D97AB8F7741553EF5A079C7D09F4217ACB69B66FD231` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller_sim.sh` | `B90C82DFB24C5DA08E878A51330C0FA391DDE144F721193AC75235779BCA34A3` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v5_mb16_controller_finalstall.sh` | `91C5626409D85440C341D8CC4B5F7B8947A55130997236BA62276DF9F6BDE3FB` |

## Release verification

All runs used the standard WSL Verilator scripts and the same frozen vectors.
The lint run exited `0` (with the existing non-fatal latch/blocking-assignment
warnings captured in its log). Every simulation exited `0` and printed `PASS`.

| mode | cycles | sink stalls | PW MAC | DW MAC | RQ accepts | DW cfg/start | DW req/resp | final commits | words/bytes | errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| no-BP | 23,843 | 0 | 786,432 | 73,728 | 12,288 | 288/8 | 4,418/4,418 | 8,192 | 2,048/8,192 | 0 |
| random BP | 24,466 | 126 | 786,432 | 73,728 | 12,288 | 288/8 | 4,418/4,418 | 8,192 | 2,048/8,192 | 0 |
| final-word stall | 24,498 | 158 | 786,432 | 73,728 | 12,288 | 288/8 | 4,418/4,418 | 8,192 | 2,048/8,192 | 0 |

The final-word test held `sink_ready=0` for at least 32 cycles while
`sink_index=2047`; the testbench observed and released that hold, and the
result remained exact. The 158 total stalls are the randomized stalls plus
the deliberate final-word hold.

Corresponding release lines:

```text
D4_V5_MB16 words=2048 bytes=8192 cycles=23843 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0 sink_errors=0 child_overlap=10806 errors=0 dw_rq=2048 p_rq=2048
D4_V5_MB16 words=2048 bytes=8192 cycles=24466 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=126 sink_errors=0 child_overlap=10806 errors=0 dw_rq=2048 p_rq=2048
D4_V5_MB16 words=2048 bytes=8192 cycles=24498 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=158 sink_errors=0 child_overlap=10806 errors=0 dw_rq=2048 p_rq=2048
PASS edgembconv_hwacandidate_d4_vstream_v5_mb16_controller exact=8192 aligned_word_sink=2048
```

Logs:

- `build/d4_v5_stage4b_nobp_release_20260910.log`
- `build/d4_v5_stage4b_bp_20260910.log`
- `build/d4_v5_stage4b_finalstall_20260910.log`
- `build/d4_v5_stage4b_lint_20260910.log`

## Cycle and service evidence

The no-BP state occupancy ledger is
`0/288/16/21/10752/255/6275/102/32/11/6027/64/0`; random BP is
`0/288/16/21/10752/255/6326/670/32/11/6027/68/0`; final-word stall is
`0/288/16/21/10752/255/6326/670/32/11/6027/100/0`.
The 32-cycle final-word hold appears in the output state and does not change
any arithmetic or output ledger.

For no-BP, the shared pool recorded `14,336` busy cycles, `9,032` idle cycles,
`630` turnaround cycles, `129` mode switches, `2,048` PW outputs and `12,918`
RQ outputs. The measured `child_overlap=10,806` is real overlap accounting;
it does not imply that all pool/context/output tail latency was hidden.

Relative to the v4 no-BP release result of 36,401 cycles, v5 measures 12,558
fewer cycles (about 34.5%); this improvement is from project raw-PW pool
service, banked word output, and the DW source/issue repair while preserving
the exact work ledger.

## Evidence boundary and next direction

This report supports standalone `mb16_down` functional exactness, true local
start-to-final-output cycles, ready/valid stability, semantic/service ledgers,
the deliberate final-word-stall contract, and Verilator lint execution. It
does not support any claim about full-network functionality, XC7Z020 timing
(WNS/TNS/WHS/THS), route completion, LUT/FF/DSP/BRAM use, power, GOPS/W,
accuracy, or production `cnn_top` replacement. No Vivado/P&R was run in this
milestone.
