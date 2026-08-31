# Direct 8x8 PW full-top route screen

Date: 2026-08-29  
Device: `xc7z020clg400-1`  
Run: `build/reports/vivado_cnn_top_impl/runs/20260829T055447782-18072/`

## Scope

The current worktree maps `ds_block_tile_engine_new` to the direct 8x8
output-stationary PW DSP block (`rtl/cnn/pw_direct_8x8_dsp.v`).  DW, runner,
SRAM ABI, and the exact MAC definition are otherwise unchanged for this
screen.  The direct block keeps 64 local accumulators and accepts one K token
per cycle, removing the retained 8x4 two-half replay.

## Functional and performance evidence

* `tb_pw_direct_8x8_dsp`: 3 cases, 11 blocks, 704 exact psum/mask checks.
* `tb_cnn_top_fullnet_sram_datapath`: 10/10 exact logits, status `0x0d534982`,
  `hw_cycles=873,289`, `mem_reads=78,890`, `mem_writes=10`, and
  `5,136,896` MACs.
* At 125 MHz this is `1.471 GOPS`; with the routed `0.225 W` estimate the
  arithmetic efficiency is `6.54 GOPS/W`, far below the 20 GOPS/W target.

## Fresh full-top post-route result

| Metric | Result |
|---|---:|
| WNS / TNS | `-0.672 ns` / `-106.082 ns` |
| Setup failing endpoints | `583` |
| WHS / THS | `+0.054 ns` / `0 ns` |
| LUT / FF | `30,942 (58.16%)` / `34,929 (32.83%)` |
| BRAM / DSP | `48 (34.29%)` / `127 (57.73%)` |
| On-chip power | `0.225 W` |
| Routing errors | `0` |

The direct PW change is a useful throughput/resource point: it reduces the
fullnet cycle count relative to the retained 1,003,577-cycle CSA baseline and
remains below all four resource limits.  It does not close timing or energy.
The remaining setup failure is dominated by global runner/stem control and
high-fanout routing rather than the direct PW arithmetic; no full-top target
claim is made.
