# DS real-DW to partial-K PW prototype: audited result (2026-08-30)

## Disposition

`NEGATIVE_RESULT` for the 8 ns OOC timing gate.  The prototype is functionally
useful and the partial-K token contract is exercised with real DW inputs, but
it is not a candidate for the production `cnn_top` path.  No production
runner/top/fullnet file was changed for this slice.

The workspace already contains unrelated historical dirty paths.  The
slice-owned additions/changes are listed below; all are intentionally
isolated from the production integration path:

* `rtl/cnn/ds_block_tile_engine_partialk.v` — new transaction-level real-DW
  producer and partial-K PW wrapper.  The final version removes the
  simulation-only `TRACE_CFG`, `TRACE_DSPK_DETAIL`, and `TRACE_DSPK` prints.
* `sim/tb_ds_block_tile_engine_partialk.v` — three-case differential test with
  held-output/backpressure checks and token checks.
* `sim/filelist_ds_block_tile_engine_partialk.f` — isolated Verilator filelist.
* `scripts/run_ds_block_tile_engine_partialk_sim.sh` — Verilator 5.020 runner.
* `scripts/vivado_ds_block_tile_engine_partialk_ooc_20260830.tcl` — fresh
  XC7Z020 8 ns post-route OOC flow.
* `docs/reports/ds_block_tile_engine_partialk_20260830.md` — this audit.

For this slice, `git diff --stat` has no tracked-file delta because the RTL,
test, scripts, and report above are new untracked additions in the shared
worktree.  `git status --short` identifies them with `??`; no existing
production file is part of this slice's change set.

## Functional validation

Command actually run from WSL:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_ds_block_tile_engine_partialk_sim.sh'
```

The runner invokes:

```text
verilator --binary --timing --trace --top-module tb_ds_block_tile_engine_partialk \
  --Mdir build/verilator_ds_block_tile_engine_partialk --build-jobs 8 \
  -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f sim/filelist_ds_block_tile_engine_partialk.f \
  -o sim_ds_block_tile_engine_partialk
```

Raw result summary:

```text
CASE cfg=0 stride=1 P=1  Cin=32 Cout=8  tiles=1 cycles=7012  dw=2304  pw_tokens=32  transfer_wait=0 barrier_model=2368  saved_vs_barrier=32
CASE cfg=1 stride=1 P=8  Cin=48 Cout=16 tiles=2 cycles=21032 dw=6912  pw_tokens=96  transfer_wait=0 barrier_model=7104  saved_vs_barrier=96
CASE cfg=2 stride=2 P=17 Cin=32 Cout=13 tiles=6 cycles=42074 dw=13824 pw_tokens=192 transfer_wait=0 barrier_model=14208 saved_vs_barrier=192
PASS tb_ds_block_tile_engine_partialk cases=3 outputs=6 checks=357
```

There were 357 non-zero signed lane/reference comparisons, all matching.  The
stimulus is a deterministic varied (pseudo-random-looking) pattern over ACT,
DW weights, biases, and PW weights rather than a constant-value smoke test.
The test also checks exactly one token per tile/channel (`32`, `96`, and `192`),
tail masks (`P=17`, `Cout=13`), stride metadata, randomized output
backpressure, and output stability while stalled.  `transfer_wait=0` in these
runs; this is not evidence that the production storage system is wait-free.

The existing shared `pw_systolic_array_8x8.v` still contains its independent
simulation protocol monitor and optional `TRACE_PW_PARTIAL` plus-arg.  It was
not modified or enabled by this slice.  The new DS wrapper itself has no
`TRACE_DSPK*`/`TRACE_CFG` debug prints after the final cleanup.

## Same-shape arithmetic schedule comparison

The `barrier_model` is an explicit same-shape schedule model, not a claim that
the old production engine was measured through this new wrapper.  It models a
hard DW-to-PW fence as `DW issue cycles + 2 * PW token issue cycles`; partial-K
allows the lower-half PW issue to overlap the following DW work, so the model
subtracts exactly one PW issue cycle per token.  The wrapper's `perf_total_cycles`
also includes tile setup, the three-state DW pipeline, PW drain, output handoff,
and backpressure, so it must not be compared directly to `barrier_model`.

| Shape | Tiles | DW issue cycles | PW tokens | Hard-fence model | Partial-K arithmetic model | Model saving |
|---|---:|---:|---:|---:|---:|---:|
| P=1, Cin=32, Cout=8 | 1 | 2,304 | 32 | 2,368 | 2,336 | 32 |
| P=8, Cin=48, Cout=16 | 2 | 6,912 | 96 | 7,104 | 7,008 | 96 |
| P=17, Cin=32, Cout=13 | 6 | 13,824 | 192 | 14,208 | 14,016 | 192 |

Measured wrapper totals are respectively `7,012`, `21,032`, and `42,074`
cycles.  The savings therefore validate the intended fence schedule only;
they do not approach the complete-network requirement of approximately
274,407 cycles at 0.234 W for 20 GOPS/W.

One instrumentation limitation is material: `perf_dw_cycles` increments only
in `ST_DW_READ`, while the worker uses `ST_DW_READ -> ST_DW_MUL -> ST_DW_ACC`.
Thus the reported `dw` column is a read-state counter, not the full elapsed DW
worker occupancy.  A future performance report must correct this before using
the prototype as a cycle model.

## Fresh 8 ns XC7Z020 OOC post-route

The flow was run with Vivado 2025.2, part `xc7z020clg400-1`, and an 8.000 ns
clock.  The exact script and artifacts are:

* Script: `scripts/vivado_ds_block_tile_engine_partialk_ooc_20260830.tcl`
* Vivado log: `build/vivado_ds_block_tile_engine_partialk_ooc_20260830.log`
* Timing: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/timing_summary_post_route.txt`
* Max paths: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/reg_to_reg_maxpaths.txt`
* Utilization: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/utilization_post_route.txt`
* Power: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/power_post_route.txt`
* Route status: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/route_status_post_route.txt`
* Routed checkpoint: `build/reports/vivado_ds_block_tile_engine_partialk_ooc_20260830/ds_block_tile_engine_partialk_ooc_post_route.dcp`

| Metric | Fresh post-route result |
|---|---:|
| WNS | -7.328 ns |
| TNS | -2,138.096 ns |
| Setup failing endpoints | 2,305 |
| WHS | +0.053 ns |
| THS | 0 ns; 0 failing endpoints |
| LUT | 4,794 (9.01%) |
| FF | 5,684 (5.34%) |
| DSP | 33 (15.00%) |
| BRAM | 0 (0.00%) |
| Total on-chip power | 0.201 W |
| Route errors | 0 |

The prototype is therefore resource-light and hold-clean, but fails the OOC
setup gate by a large margin and cannot be integrated into the full top.

## Timing diagnosis

The worst routed setup path is:

```text
pixel_base_reg[4]/C -> act_reg_reg[2]/D
Slack              -7.328 ns
Data path          15.275 ns
Logic               8.387 ns (54.907%)
Routing             6.888 ns (45.093%)
Logic levels        13: CARRY4=5, DSP48E1=1, LUT2=1, LUT6=3,
                       MUXF7=1, MUXF8=1, RAMD64E=1
```

The path is not an abstract timing artifact.  In
`rtl/cnn/ds_block_tile_engine_partialk.v`, the relevant sources are:

* Lines 87-90: all four logical memories are explicitly `ram_style =
  "distributed"`; the ACT memory alone maps to 3,172 distributed-RAM LUTs.
* Lines 154-160: `act_addr` is declared as an unconstrained `integer`, making
  the address datapath much wider than the bounded logical address requires.
* Lines 288-296: `pixel_base + pixel_slot`, tap arithmetic, the wide address
  mux, dynamic `act_mem[act_addr]` read, and dynamic DW-weight read are all
  selected in one read state.
* In the routed path, the carry/DSP address logic drives the ACT RAM address
  with fanout 1,035; the RAM output then traverses LUT6/MUXF7/MUXF8 into the
  `act_reg` destination.

A separate repeated PW control family is:

```text
u_pw/capture_output_pending_reg/C -> u_pw/psum_out_reg[723]/CE
Data path          10.931 ns
Logic               0.518 ns (4.739%)
Routing            10.413 ns (95.261%)
Net fanout          2,049
Slack              -3.220 ns
```

This second family is predominantly a control-distribution/placement problem,
not a multiplier problem.  `capture_output_pending` is used to enable the
wide PW output register in `rtl/cnn/pw_systolic_array_8x8.v` around lines
263-270; one global CE net reaches roughly 2,049 loads after mapping.

### Remediation classification

Likely code/netlist-remediable portions are the unconstrained integer address,
the same-cycle address arithmetic plus distributed-RAM read, and the global PW
capture enable.  A BRAM-shaped ACT window store with a narrow registered
address, followed by a registered RAM-data stage, can remove the carry/DSP ->
RAM -> mux chain from one cycle.  Local row/column enables or registered CE
islands can reduce the 2,049-load PW control net.

The remaining service-rate limitation is architectural: this prototype has one
DW producer performing one 3x3 channel reduction through three FSM states per
tap, then serially issuing one 8-pixel DW vector per K.  BRAM/register cuts
alone will not produce the required approximately 3.7x full-network speedup.
The DW producer, storage bandwidth, PW partial-sum residency, and tile
commit/fence must be redesigned together.  This is why no local timing patch
or production integration is justified by this result.

## Next action

Keep this prototype as a functional contract/reference only.  The next viable
candidate should use BRAM-backed window storage, narrow address/data pipelines,
and a local DW producer, then repeat the same differential checks.  Only a
candidate that passes the 8 ns OOC gate and demonstrates a meaningful
full-network cycle reduction should proceed to dual-bank DW/commit overlap and
the authoritative full-top Explore post-route run.
