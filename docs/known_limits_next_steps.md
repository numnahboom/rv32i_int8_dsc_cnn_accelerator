# 当前限制与下一步（2026-09-01）

## 当前结论

固定 EdgeDSCNet-C10 的 `cnn_top` 完整仿真路径保持 bit-exact；但 XC7Z020
目标的完整顶层仍未同时满足时序、周期和能效目标。权威基线和实验报告索引
位于 [`reports/README.md`](reports/README.md)。

| 项目 | 当前权威结果 | 结论 |
| --- | ---: | --- |
| CSA 完整顶层 | 1,003,577 cycles；5,136,896 MAC；10/10 logits exact | 功能通过，WNS -0.799 ns，未闭合 |
| shared unified64 完整网络 | 713,086 cycles；5,136,896 MAC；logits exact | 仅综合资源证据 |
| shared + persistent DS 完整网络 | 695,553 cycles；5,136,896 MAC；logits exact | OOC WNS -0.838 ns，未晋级 |
| group-published shared64 隔离 DS | 87,553 cycles；4,194,304 DS MAC | 同步读 OOC WNS +0.032 ns，非 full-top |

完整网络目标为 125 MHz（8 ns）、WNS/WHS >= 0、<=2.0M cycles、LUT/FF/DSP/BRAM
各 <70%、on-chip power <=3 W，并以 MAC=2 ops 计算 >=20 GOPS/W。当前 CSA
基线在 125 MHz、0.234 W 下约 5.47 GOPS/W；达到 20 GOPS/W 约需 <=274k cycles。

## 证据边界

- `build/reports/vivado_cnn_top_impl/runs/20260828T_stem_csa_fulltop_max2/`
  是完整顶层 post-route 基线，报告 `docs/reports/fulltop_csa_baseline_20260828.md`
  汇总其 timing、端点、资源、功耗和关键路径。
- `ds_group_published_shared64_sync_read_equivalence_20260901.md` 是当前最强
  的隔离 DS 证据：Verilator 显式模拟同步 XPM BRAM 一拍读响应，覆盖 Cin
  16/32/64/128、tail、mask、epoch/session、descriptor fence 和 backpressure。
- OOC 正 slack 只证明相应隔离车辆的布局布线，不证明 `cnn_top` 的全局路由、
  完整网络周期或板级功耗。
- Vivado power 是默认活动率下的 vectorless on-chip 估算，不是板级实测。
- 尚无 bitstream、板级 I/O/时钟约束、硬件运行、CDC/formal 或完整功耗测量证据。

## 接口与存储限制

- 外部读协议最多一个 outstanding；握手后的响应最早下一拍到达，不能同拍返回。
- 外部写无响应；`valid && !ready` 时 write/address/data 必须保持稳定。
- 当前仿真外存仍以“一 int8 element 一 32-bit word、低 8 位有效”为主；packed
  NHWC 和 burst adapter 尚未成为默认生产布局。
- `cnn_out_buffer`、feature SRAM、DW/PW tile buffer 的同步读语义必须在仿真、
  XPM 综合和下游控制器之间保持一致。

## 下一步

1. 维持 CSA 默认生产路径，先对 shared64 的 runner 合同、同步读和 fence 做
   集成前审查；未有 full-top 证据前不修改默认选择器。
2. 针对 full-top 最差路径族优化：DW 参数/控制高扇出、tiled-loader 地址控制、
   FC 配置寻址和全局布线拥塞；使用 Vivado 8 线程取得可比较的 post-route。
3. 只有候选同时改善 cycle、WNS/TNS/WHS、失败端点、资源、功耗和 GOPS/W，才
   进行完整顶层晋级；否则在报告索引中保留负结果和原因。
4. 晋级后再补齐 fullnet XSim/Verilator、完整顶层 post-route、活动率功耗和硬件
   smoke，最后才宣称目标完成。
