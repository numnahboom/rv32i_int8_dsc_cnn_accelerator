# D4 vstream v3 `mb16_down` PW refill 优化实验 — 2026-09-09

## 结论

本轮完成了当前源码同源基线、冗余 PW issue 诊断、最小 RTL 修正和两种
ready/valid 复验。候选保持 bit-exact、8192 个最终字节和 2048 个 32-bit
sink fires，且把专用 PW 计数从错误的 `821248` 修正为语义应有的
`786432`；但周期没有下降，no-BP 仍为 `43688`，未达到 `<=25000` 门槛。
因此本轮是**功能/工作量修正成功、吞吐门槛 NEGATIVE_RESULT/partial**，不是
D4 v3 生产或时序闭合结论。

没有启动 Vivado、P&R、训练或完整网络集成；C0 路径未改动。

## 工作边界和哈希

基线是在本实验改动前、同一工作树的 v3 scheduler/controller/filelist/TB
组合上采集的；工作树其他 dirty 路径保留。SHA256 如下（基线 → 候选）：

| 文件 | 基线 | 候选 |
|---|---|---|
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v3_mb16_controller.v` | `BD01838E474D3D34CD2DF42FD6CBF9194DA430AF33E7CE235583D8A24A0245E4` | `BD01838E474D3D34CD2DF42FD6CBF9194DA430AF33E7CE235583D8A24A0245E4` |
| `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v3_scheduler.v` | `21D79F8BB927EC167C16F03A944104EC3AA729CC3BFC24B83BC828F0C33D558E` | `C555B865DCC67D69090CC3E92527C7D4783F8C95EBA1050AAD89918410B4A6EE` |
| `sim/tb_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller.v` | `9A7E58BA0D94CEBBEE9613C5B962F03259C3A72A47EE8391C238AACE16B66C8E` | `105B84634AAB7DA45F123F3DF82A351073B69631B925AE5255BB99F1D8F6ED94` |
| `sim/filelist_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller.f` | `3E9AE3123E40368B272EE6AE6672BB206C3FB9E95C6BEA61403C14282898BE23` | `3E9AE3123E40368B272EE6AE6672BB206C3FB9E95C6BEA61403C14282898BE23` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_nobp.sh` | `A4454102C2F2BD4370C539CD81673E03F79025B46CEB84E9A7ECD97CF44888B6` | `A4454102C2F2BD4370C539CD81673E03F79025B46CEB84E9A7ECD97CF44888B6` |
| `scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_sim.sh` | `B2401E414D8CB2FBCF24B0583934B3DD2F478DBC22D7606748A1EF9D4FADC259` | `B2401E414D8CB2FBCF24B0583934B3DD2F478DBC22D7606748A1EF9D4FADC259` |

本实验新增本报告；未编辑历史 `edgembconv_hwacandidate_d4_vstream_v3_mb16_20260902.md`。

## 基线证据

执行命令（WSL，输出分别保存）：

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_nobp.sh > build/d4_v3_mb16_current_nobp_20260909.log 2>&1'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_sim.sh > build/d4_v3_mb16_current_bp_20260909.log 2>&1'
```

日志：

- `build/d4_v3_mb16_current_nobp_20260909.log`
- `build/d4_v3_mb16_current_bp_20260909.log`

两次都 exact，且 sink 地址/索引递增、epoch 和 `4'b1111` byte enable 检查通过：

| 基线模式 | cycles | words | bytes | PW MAC 计数 | DW MAC | RQ accepts | DW cfg/start | DW req/resp | final commits | sink stalls | sink errors | errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| no-BP | 43688 | 2048 | 8192 | 821248 | 73728 | 12288 | 288/512 | 4418/4418 | 8192 | 0 | 0 | 0 |
| 随机 BP | 44965 | 2048 | 8192 | 821248 | 73728 | 12288 | 288/512 | 4418/4418 | 8192 | 512 | 0 | 0 |

`821248 - 786432 = 34816 = 272*128`。静态追踪发现专用 112-lane PW
在每个真实 context 的末 K 接受后，因一拍输出延迟而重新打开 ready，
并在最后一个真实 context 后把 `next_*` 推进到不存在的 `y=32` phantom
context；这些 issue 不改变最终结果，却污染工作量计数。

## 最小修正

只在 D4 v3 scheduler 做控制修正，保留 112-lane PW、16-DSP shared pool、
16-DSP DW 和接口/ready-valid 结构：

1. 新增 `ded_last_fire`。专用 PW 接受最后 K 的同一边沿立即清除
   `ded_active`，阻止 `pw112` 最后一拍输出等待期间的第 17 个 token。
2. `pw112_valid` 不再要求 `ded_active` 仍为 1 才捕获；这样既关闭输入，
   又保留最后 psum 写入 context slot 的时序。
3. 在 `S_E_POOL` 以 `e_done_tiles!=9'd255` 保护 `next_*` refill；最终
   context 直接进入 RQ，不再启动 `y=32` phantom dedicated job。
4. TB 增加语义 ledger 断言：PW `786432`、DW `73728`、RQ `12288`、
   DW source `4418/4418`、final `8192`、sink `2048/8192`。因此不能以少
   提交输出或少做算术来制造“周期改善”。

对应符号位于 `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v3_scheduler.v`
的 `ded_last_fire`、`pw112_valid` 捕获、`S_E_BOTH/S_E_RQ/S_E_POOL/S_P_BOTH`
末 K 分支和最终 `e_done_tiles` fence。

## 候选复验

快速 lint 命令及证据：

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && verilator --lint-only --timing --Wall --Wno-fatal --Wno-BLKLOOPINIT --Wno-UNOPTFLAT -f sim/filelist_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller.f --top-module tb_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller > build/d4_v3_mb16_opt_lint_clean_20260909.log 2>&1'
```

`build/d4_v3_mb16_opt_lint_clean_20260909.log`，exit `0`。当前组合仍有既有
`PINCONNECTEMPTY`、`WIDTHEXPAND/WIDTHTRUNC`、`BLKSEQ` 和少量 `LATCH`
warning；没有 lint error。本轮没有把这些结构性 warning 误报成时序或功能成功。

候选命令及证据：

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_nobp.sh > build/d4_v3_mb16_opt_nobp_clean_20260909.log 2>&1'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_sim.sh > build/d4_v3_mb16_opt_bp_clean_20260909.log 2>&1'
```

日志：

- `build/d4_v3_mb16_opt_nobp_clean_20260909.log`
- `build/d4_v3_mb16_opt_bp_clean_20260909.log`
- `build/d4_v3_mb16_opt_lint_clean_20260909.log`

这些清理后的回归日志只保留 lint 输出以及最终 `D4_V3_MB16` 指标和
`PASS` 行，不包含临时 pool/expand/project/DW/RQ trace。旧的
`build/d4_v3_mb16_opt_nobp_final_20260909.log` 是清理前的历史诊断日志，
仅用于状态边界分解，不作为本次清理后的回归证据。

两种模式均打印：

```text
D4_V3_MB16 words=2048 bytes=8192 cycles=43688/44965 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=512 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0/512 sink_errors=0 child_overlap=4080 errors=0
PASS edgembconv_hwacandidate_d4_vstream_v3_mb16_controller exact=8192 aligned_word_sink=2048
```

其中 no-BP 为 `43688, sink_stall=0`，随机 BP 为 `44965,
sink_stall=512`；两者均 `sink_errors=0, errors=0`。TB 的 ledger 断言也均
通过。候选相对基线的功能/工作量/周期对比：

| 模式 | cycles 基线→候选 | PW 计数基线→候选 | sink stalls 基线→候选 | exact/errors |
|---|---:|---:|---:|---|
| no-BP | 43688→43688（0） | 821248→786432（-34816） | 0→0 | 8192/0 |
| 随机 BP | 44965→44965（0） | 821248→786432（-34816） | 512→512 | 8192/0 |

`child_overlap` 从 4608 变为 4080 是关闭 stale dedicated token 后的有效
活动窗口变化，不是周期收益；RQ、DW 和 sink service counts 保持不变。

## 周期分解与门槛判断

no-BP 候选的状态边界参考同一候选 RTL 的历史诊断日志
`build/d4_v3_mb16_opt_nobp_final_20260909.log`（该次 TB 额外带有临时
state-edge trace）。该日志仅用于状态边界分解；清理后的回归证据是上节列出的
clean 日志，它们复现总周期和全部 ledger，但只保留最终指标/PASS：

| 区段 | cycles |
|---|---:|
| 首组 DW config | 144 |
| expand PW/RQ（含 256 context 的 pool turnaround） | 17664 |
| DW group 0 source/compute/RQ | 6040 |
| 第二组 DW config | 144 |
| DW group 1 source/compute/RQ | 6064 |
| project PW/RQ（64 context） | 5440 |
| 最终 byte output（串行 8192 字节） | 8192 |
| **合计** | **43688** |

因此 no-BP 相对 `25000` 仍差 `18688` cycles（`1.748x` 门槛）；随机 BP
为 `44965`，差 `19965`。本轮高置信控制修正只消除了无效 issue，未改变
shared pool 的模式切换、DW service 或串行 byte-output 结构，周期不下降是
符合瓶颈诊断的结果。

## 下一步高信息增益方向

应先在同一 ledger/ready-valid 约束下验证两个独立瓶颈，而不是继续改 PW
末 K fence：

- 输出服务：为 scheduler 增加保持 byte-exact 语义的 4-byte word drain
  路径，确认 `final_commit=8192`、`sink fires=2048` 后再判断能否去掉当前
  8192-cycle 串行 output 区段。
- shared-pool 数据流：对 expansion 的 256 个 context 记录 pool mode
  turnaround 和 RQ latency，评估不增加 DSP 的 banked/context queue 或
  更大粒度 partial-K 调度；当前 256 context 的约 69-cycle/context 节奏
  是主要算术控制瓶颈。

两者都必须先通过 no-BP/random-BP exact、语义 MAC/RQ/output ledger，再考虑
任何 OOC/P&R；本报告没有为候选提供 timing/resource/power/full-top 证据。
