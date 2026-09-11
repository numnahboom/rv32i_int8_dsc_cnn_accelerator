# Shared64 metadata-commit timing candidate (2026-09-08)

## Decision

**NEGATIVE_RESULT for the full-top timing-closure gate.** The shared64
arithmetic island now reserves a bank on the first accepted token and commits
the complete metadata bundle from a registered pending record on the following
clock. Functional checks remain exact and the isolated runner OOC result
improves, but the production `cnn_top` run still has negative setup slack. The
new full-top bottleneck is in the retained FC path, not the shared64 bank
metadata enable cone.

## RTL change

`rtl/cnn/unified64_shared_compute_array.v` adds a single-entry registered
metadata bundle (`meta_pending_*`) and per-bank `bank_meta_valid` fences. The
reservation path captures mode, masks, geometry/tag, bias, multiplier, shift,
zero point, and activation bounds immediately. `meta_commit0/1` writes that
bundle into the selected bank one cycle later. Drain selection requires both
`bank_ready` and committed metadata, and releases the metadata-valid fence with
the physical bank. The existing 256-bit packed XPM row path and look-ahead
request protocol are unchanged.

## Functional evidence

All runs used the current dirty checkout and completed with zero functional
errors:

| Check | Result |
|---|---|
| C0 exact, six layers, both modes | `PASS shared64 C0 ... total_pw_mac=4194304 total_ops=8388608`; per-mode C0 fixture checks pass |
| Adapter DS1 exact, delayed/random source/output handshakes | `PASS adapter DS1 exact cycles=21633 dw=4096 desc=256 pw=8192 out=8192 source=6976 stalls=2527 cfg=800` |
| Isolated six-shape sweep, row/group reorder and periodic output stalls | `PASS ds_group_published_shared64_sweep`; 6/6 layers, no intermediate requantization, first/last-K audits pass |
| Production no-backpressure | `PASS ... hw_cycles=245819 checks=10 errors=0` |
| Production random backpressure + response delay 2 | `PASS ... hw_cycles=283716 checks=10 errors=0 mem_req_stalls=6618` |
| Production response delay 64 | `PASS ... hw_cycles=1896441 checks=10 errors=0 resp_delay=64` |

## Routed OOC evidence

Source: `build/reports/vivado_ds_group_published_shared64_runner_ooc_20260908_write_sideband/`

Vivado 2025.2, XC7Z020, 8.000 ns, Explore, `general.maxThreads=8`:

| Metric | Result |
|---|---:|
| Route | 51,688/51,688 fully routed; 0 routing errors |
| WNS / TNS | **-1.771 ns / -2,782.820 ns**; 3,499/88,705 setup endpoints failing |
| WHS / THS | +0.070 ns / 0 |
| LUT / FF / BRAM / DSP | 29.85% / 35.79% / 31.79% / 53.18% |
| Total on-chip power | 0.503 W |

The prior write-sideband OOC result was WNS/TNS `-1.901 ns / -3,690.285 ns`
with 3,990 failing endpoints. The former shared-bank multiplier CE path is no
longer the worst path; the current OOC worst path is local source-adapter
`origin_y_reg -> pixel_base_reg` (`reg_to_reg_maxpaths.txt`).

## Full-top evidence and limit

Independent run ID:

`build/reports/vivado_cnn_top_group_shared64_full_impl/runs/20260908T075000-metadata-commit/`

The hierarchy proof has exactly one group top/runner/sweep/shared64 arithmetic
instance, zero legacy DS and zero M11A instances, and one Stem/GAP/FC instance.
Route completed with 73,311/73,311 fully routed nets and 0 routing errors.
Post-route timing is:

| Metric | Result |
|---|---:|
| WNS / TNS | **-2.820 ns / -12,107.572 ns**; 12,656/105,466 setup endpoints failing |
| WHS / THS | +0.086 ns / 0 |
| LUT / FF / BRAM / DSP | 63.86% / 41.89% / 46.07% / 67.27% |
| Total on-chip power | 0.448 W |

The current worst full-top path is
`u_layer_runner/aux_cfg_index_reg[0]_replica ->
u_layer_runner/u_fc_unit/acc_mem_reg[3][31]` in `timing_maxpaths.txt`.
Therefore the required full-top acceptance condition (WNS >= 0 and TNS = 0,
with hold/routing/resource gates) is not met; no timing-closure or 125 MHz
claim is made.
