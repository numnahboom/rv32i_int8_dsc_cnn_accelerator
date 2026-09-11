# EdgeDSCNet-C10 D4 v6 PW operand/token stage — 2026-09-10

## 判决

**NEGATIVE_RESULT（功能与资源通过，OOC route 完成但 8 ns setup 未闭合）。**

本轮在 D4 v6 专用 dedicated-PW 路径加入一个可替换的一项 operand/token
寄存器。它把 banked activation/weight 的同步响应及 16-bit descriptor 一起
捕获，再送入 112-DSP PW island；同边沿消费/替换时保持 II=1。未修改 C0、
`cnn_top`、runner 或模型软件，也未开始 shape sweep。

## 改动

- `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v2_datapath.v`
  - 新增 `edgembconv_hwacandidate_d4_vstream_v6_pw_operand_stage`。
  - stage 携带完整 256-bit activation、128-bit weight 和 descriptor；
    `in_ready = !entry_valid || out_ready`，空槽/消费边沿可直接替换。
- `rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_scheduler.v`
  - dedicated fetch-pair 的 response-ready 改接 stage input；PW island 改接
    stage output。
  - K/first/last/pass、payload 均从同一 stage token 驱动；scheduler 的请求
    计数仍绑定 pair response 被接受的边沿，因此不引入每 token bubble。

未提交、未 reset/checkout/clean；其他 dirty 路径保留。

## 功能验收

下列均使用当前 RTL/filelist，退出码为 0，`errors=0`，8192 bytes 与 2048
aligned sink words exact：

| 命令 | 结果 |
|---|---|
| `wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter_sim.sh'` | `PASS ... requests=26 responses=26` |
| `wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_sim.sh'` | `PASS ... cases=3 real_cases=2 tail_case=1` |
| `.../run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_nobp.sh` | epoch 10, cycles **24032**, PW/DW/RQ `786432/73728/12288`, DW req/resp `4418/4418`, final `8192`, sink stall `0` |
| `.../run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_sim.sh` | epoch 10, cycles **25381**, sink stalls `126` |
| `.../run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_finalstall.sh` | epoch 10, cycles **25413**, sink stalls `158` |
| `.../run_edgembconv_hwacandidate_d4_vstream_v6_mb16_controller_two_epoch.sh` | epoch 10/11, cycles **25381/25382**, done backpressure held, sink stalls `126` |

All five controller lines report `dw_rq=2048 p_rq=2048 child_overlap=11379
errors=0`; pool input/output and mode ledgers remain exact in the TB checks.
No-BP remains below the 25,000-cycle gate.

## Fresh synth

Run directory:

`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_synth_20260910_145500_pwoperandstage/`

Manifest: `source_manifest.txt`, 13 RTL sources + XDC, Vivado 2025.2,
`xc7z020clg400-1`, 8.000 ns, `general.maxThreads=8`; generated manifest has
the current SHA256 for the modified v2 datapath (`B77190FE...A21F86A`) and
scheduler (`5A3B346E...BAA1BFD`), with no source omissions. Synth counts are:

| Resource | Used | Utilization | Gate |
|---|---:|---:|---|
| Slice LUTs | 30,438 | 57.21% | pass `<70%` |
| Slice Registers | 25,979 | 24.42% | pass `<70%` |
| DSP48E1 | 145 | 65.91% | pass `<=153` |
| BRAM tile | 28 (56 RAMB18) | 20.00% | pass |

Synth timing is not closure: WNS/TNS `-2.701/-1488.750 ns`, 1,570 failing
endpoints; WHS/THS `+0.210/0 ns`, 0 hold failures. The synth top path is now
the DW cursor lookahead cone (`dw_job_y_reg[3]/C -> u_dw/cursor_lookahead_addr_q_reg[10]/D`),
not banked-storage -> PW DSP. Hierarchical synth reports
`u_ded_pw_operand_stage` at 739 LUT / 401 FF and `u_v6_banked_storage` with
32 RAMB18.

## Fresh complete OOC route + power

Run directory:

`build/reports/vivado_edgembconv_hwacandidate_d4_vstream_v6_ooc_route_20260910_150000_pwoperandstage_route/`

`route_status_post_route.txt` reports 49,144/49,144 routable nets fully routed,
0 routing errors. Post-route resources: 18,601 LUT (34.96%), 26,069 FF
(24.50%), 145 DSP (65.91%), 28 BRAM tiles (56 RAMB18). Congestion report has no
window above level 5.

Post-route timing: WNS/TNS `-1.156/-2603.288 ns`, 6,682 setup failing endpoints;
WHS/THS `+0.093/0 ns`, 0 hold failures. The former baseline route was
banked-storage RAMB18 `CLKBWRCLK -> u_pw112 DSP A[16]`, 7.186 ns data and
3 logic levels, WNS/TNS `-2.992/-14438.564 ns`, 12,767 failing endpoints. This
candidate's top path is instead RQ control:

`u_arithmetic/rq_base_reg[2]_replica/C -> u_arithmetic/u_pool/input_rq_acc_reg[60]/D`

with 9.147 ns data, 12 logic levels, and -1.156 ns slack. The former bank path
is absent from the top path; the remaining registered PW boundary path is
`u_ded_pw_operand_stage/entry_valid_reg/C -> u_pw112/.../A[17]`, 5.335 ns,
2 logic levels, -1.141 ns slack. Thus the targeted path family improved
substantially, but the new RQ/control cone prevents 8 ns setup closure.

Post-route vectorless power is **0.378 W total** (`0.269 W` dynamic,
`0.109 W` static), confidence Medium; this is standalone OOC power only and
does not establish full-network GOPS/W.

## Evidence boundary

The stage is accepted for functional exactness, II=1 token alignment, resource
budget, and measurable OOC path-family improvement. The result is not timing
closure, full-network integration, board evidence, or energy-efficiency proof.
The next target is the fresh RQ `rq_base -> input_rq_acc` cone; do not infer
that fixing the PW path alone closes the candidate.
