# D4 vstream v4 `mb16_down` DW tile/FIFO 优化实验 — 2026-09-10

## 结论

本轮完成了 D4 vstream v4 的两个控制/数据流修正，并用无诊断的标准
Verilator 脚本重新复验了 `mb16_down`。候选保持 bit-exact：8192 个最终
字节、2048 个 32-bit sink word、PW/DW/RQ 和 DW source request/response
ledger 全部匹配；随机 sink backpressure 也通过稳定性和 exactness 检查。

v4 no-BP 为 **36,401 cycles**，随机 BP 为 **37,927 cycles**，相对 v3
的 43,688/44,965 cycles 分别减少 7,287/7,038 cycles。但 no-BP 仍比
`<=25,000` gate 多 11,401 cycles，因此吞吐验收仍是
**NEGATIVE_RESULT/partial**，不是 D4 生产晋级或时序闭合结论。

本轮没有启动 Vivado、P&R、fullnet、训练或 C0/生产 runner 集成；没有把
周期改善外推为 OOC/full-top PPA 或 timing 成功。

## 范围与候选结构

本实验只使用 v4 独立 scheduler/controller/filelist/TB 组合，保留工作树中
其他 dirty 路径。v4 的关键改动为：

1. 修复首个 expansion context 的 `S_E_WAIT` raw-pass 控制。普通七像素
   pass 在接受最后一个 K 时进入 wait，但 PW island 的输出有一拍延迟；
   `S_E_WAIT` 现在继续接受并排空 `ded_raw_phase` 的第二 pass，避免
   `pw_k` 永远停在 0、context 永远不能 ready 的死锁。project 的
   `S_P_WAIT` 采用同样的排空规则。
2. DW scheduler 改为 `8x8` spatial tile（每个 tile 64 个 output vector），
   `DW_FIFO_DEPTH=64` 的 raw capture FIFO；8 个 DW command 覆盖两组、四个
   spatial tile/组，替代 v3 的 512 个逐点 command。DW arithmetic/source
   ledger 不变。
3. 保留两 context ping-pong、16-DSP shared RQ pool、112-lane dedicated PW
   island、registered 4-byte output sink 和所有 semantic ledger 断言。sink
   仍要求地址四字节对齐、`byte_enable=4'b1111`，并在 `valid && !ready`
   时保持 payload/tag 稳定。

候选源码当前 SHA256（实验报告和 release log 均以这些文件为准）：

| 文件 | SHA256 |
|---|---|
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v4_scheduler.v` | `251F8AA5AB089FAC5BA5D6B33E3C1FDF6C5D01CD0F24F2E12A2F5908C173E254` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v4_mb16_controller.v` | `FE139644E5D8564CEA6E3EE96E143696EFCC096CBBD0C67AD4A5D72FDC91A0CE` |
| `sim/tb_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller.v` | `9C72B1BFEE7C27D883517A0DBE6832DCD0DFB0A48410CC9C6792A86026BD098F` |
| `sim/filelist_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller.f` | `58C8F8CEFDF16BEB067E485E93FC19062A0EDE344363229B06B929AFE00A1FCE` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller_nobp.sh` | `C771B34D2C592A0D849E54E6E68DE8382251DF472D730C3A9DDBB01266E409C0` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller_sim.sh` | `F103D1B75C05AF188A7708208B402268A984B9873353EDFDCC7DDA6FEFD5FA8A` |

## 冻结 workload 与 semantic ledger

| stage | operation | PW/DW MAC | RQ vectors | final output |
|---|---|---:|---:|---:|
| expand | PW 16→32 | 524,288 | 8,192 | 32,768 bytes intermediate |
| depthwise | DW 3x3, 32 channels | 73,728 | 2,048 | 8,192 bytes |
| project | PW 32→32 | 262,144 | 2,048 | 8,192 bytes final |
| **total** |  | **PW 786,432 + DW 73,728** | **12,288** | **8,192** |

TB 强制检查 `pw_mac_count=786432`、`dw_mac_count=73728`、
`rq_accept_count=12288`、`dw_req=dw_resp=4418`、`final_commit=8192`、
`word_sink_fire=2048`、`byte_commit=8192`，并逐字节比对冻结 golden
output。v4 报出的 `dw_start=8` 是 8 个 8x8 command，不是减少了 DW
算术工作。

## Release 验证

使用 WSL 中的 Verilator 标准脚本，未定义 `V4_DIAGNOSTIC`：

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller_nobp.sh > build/d4_v4_dw8x8_nobp_release_20260910.log 2>&1'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_edgembconv_hwacandidate_d4_vstream_v4_mb16_controller_sim.sh > build/d4_v4_dw8x8_bp_release_20260910.log 2>&1'
```

两次脚本均 exit `0`，并打印 `PASS`。结果如下：

| 模式 | cycles | sink stalls | PW MAC | DW MAC | RQ accepts | DW cfg/start | DW req/resp | final commits | words/bytes | errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| no-BP | 36,401 | 0 | 786,432 | 73,728 | 12,288 | 288/8 | 4,418/4,418 | 8,192 | 2,048/8,192 | 0 |
| random BP | 37,927 | 511 | 786,432 | 73,728 | 12,288 | 288/8 | 4,418/4,418 | 8,192 | 2,048/8,192 | 0 |

对应 release log：

- `build/d4_v4_dw8x8_nobp_release_20260910.log`
- `build/d4_v4_dw8x8_bp_release_20260910.log`
- `build/d4_v4_dw8x8_lint_20260910.log`（lint exit `0`）

最终 no-BP 行为：

```text
D4_V4_MB16 words=2048 bytes=8192 cycles=36401 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0 sink_errors=0 child_overlap=8160 errors=0
PASS edgembconv_hwacandidate_d4_vstream_v4_mb16_controller exact=8192 aligned_word_sink=2048
```

随机 BP 行为：

```text
D4_V4_MB16 words=2048 bytes=8192 cycles=37927 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=8 dw_req=4418 dw_resp=4418 final=8192 sink_stall=511 sink_errors=0 child_overlap=8160 errors=0
PASS edgembconv_hwacandidate_d4_vstream_v4_mb16_controller exact=8192 aligned_word_sink=2048
```

TB 还检查 sink 在 stall 期间的 address/data/index/epoch 稳定性；两种模式
均无 `sink_errors` 或 protocol errors。

## 周期分解与门槛判断

no-BP 的 v4 state occupancy ledger 为
`0/288/16/21/10752/255/7168/2605/2048/2368/2688/8192/0`，按状态映射为：

| state | 含义 | cycles |
|---:|---|---:|
| 1 | DW config | 288 |
| 2 | expansion dedicated both | 16 |
| 3 | expansion wait | 21 |
| 4 | expansion RQ | 10,752 |
| 5 | expansion pool turnaround | 255 |
| 6 | DW RQ | 7,168 |
| 7 | DW wait/launch | 2,605 |
| 8 | project dedicated both | 2,048 |
| 9 | project wait | 2,368 |
| 10 | project RQ | 2,688 |
| 11 | serial byte output | 8,192 |
| **sum** |  | **36,401** |

随机 BP 的 state ledger 为
`0/288/16/21/10752/255/7168/3620/2048/2368/2688/8703/0`，总计
37,927；增加的 511 个 sink stall 都由真实 output handshake 反映出来。

主要残余开销是 expansion RQ 10,752 cycles、DW RQ 7,168 cycles 和
串行 byte output 8,192 cycles；因此 `child_overlap=8160` 并未消除
shared-pool/context service 与 output drain 的长尾。v4 相对 v3 的周期改善
证明 tile/FIFO 和死锁修复可运行，但不足以支持 `<=25,000` 的 throughput
claim：no-BP 仍为 gate 的 1.456x。

## Evidence boundary and next direction

本轮证据仅覆盖 standalone `mb16_down` 的 functional exactness、ready/valid
稳定性、semantic/service ledger、Verilator lint 和 measured cycles。没有
OOC、post-route WNS/TNS/WHS、资源、功耗、GOPS/W、full-top 或训练证据；
因此不能把 v4 宣称为生产候选或 timing/power closure。

下一步若继续优化，应在保持上述 ledger 的前提下评估 context/RQ queueing
与 word-output/overlap；任何打包、减少提交或模型投影都不能作为已经验证的
周期收益。
