# Unified64 persistent data-plane hardening: final gate (2026-08-31)

## Snapshot and scope

This is an isolated `unified64_tile_engine_persistent_wrapper` OOC gate. It
does not modify or prove `cnn_top`, `cnn_layer_runner`, Stem, full-network
logits, end-to-end cycles, or board power. The final RTL snapshot includes the
single-bit `row_psum[137]` hold buffer and the existing q0 requant hold buffer.

Files in the implementation snapshot are:

- `rtl/cnn/unified64_tile_engine_experiment.v`
- `rtl/cnn/ds_persistent_feed_contract_bram.v`
- `rtl/cnn/requant_activation_unit.v`
- `scripts/vivado_unified64_tile_engine_hardened_ooc_20260831.tcl`

## Functional evidence

Raw Verilator command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_unified64_tile_engine_experiment_sim.sh'
```

Result: `PASS unified64 blocks=25 commits=400 tokens=1344 masked_macs=69248 stalls=24 overlap=192 peak_occ=2 cycles=2718`.

Persistent smoke command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_unified64_tile_engine_persistent_sim.sh'
```

Result: `PASS persistent jobs=2 outputs=32 feed_tokens=32 source_words=4096 param_words=128 local_reads=96/32 reuse=0 commits=32 stalls=1 overlap=0`.

The final randomized contract test is
`sim/tb_unified64_tile_engine_persistent_random.v`, driven by
`scripts/run_unified64_tile_engine_persistent_random_sim.sh`. It uses
independent LFSR request and output backpressure, 40 random jobs with
changing pixel/channel masks, repeated bases, an invalid epoch/session job,
and a token-level arithmetic scoreboard. Result:

`PASS persistent_random jobs=40 tokens=640 outputs=640 stale=6 source_req=4096 param_req=128 stalls=202 reuse=20 cycles=14035`.

Every odd job deliberately reused the preceding job's source pixel base while
changing the cout tile and masks. `reuse=20` and the unchanged
`source_req=4096` loader count prove that the reused jobs did not reissue
external source requests. The token-level scoreboard still matched all 640
outputs under the randomized output stalls; the six stale epoch/session
attempts produced no accepted token.

## Fresh XC7Z020 post-route result

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\Stuff\Project\scripts\vivado_unified64_tile_engine_hardened_ooc_20260831.tcl
```

Reports: `build/reports/vivado_unified64_tile_engine_hardened_ooc_20260831/`

| Metric | Result | Gate |
|---|---:|---:|
| Clock / Fmax | 8.000 ns / 125.000 MHz | 125 MHz |
| WNS / TNS / setup fails | +0.634 ns / 0 / 0 | WNS >= 0 |
| WHS / THS / hold fails | +0.098 ns / 0 / 0 | WHS >= 0 |
| LUT | 6,843 (12.86%) | <70% |
| FF | 16,910 (15.89%) | old 15,982 +10% = 17,580 |
| DSP | 80 (36.36%) | 80 |
| BRAM36 | 12 (8.57%) | <=36 |
| On-chip power | 0.280 W | <=0.30 W |
| Max reported fanout | 569 | <1,000 |
| Route errors | 0 | 0 |
| Congestion | no windows above level 5 | clean |

The worst setup path is `cut_act_reg[30]/C` to
`u_engine/in_stage_act_reg[3][1][6]/D`, 7.361 ns total (0.580 ns logic,
6.781 ns routing). The worst hold path is
`u_engine/u_rq/gen_rq[3].u_core/shifted_high_s7_reg[21]/C` to
`.../zp_added_s8_reg[21]/D`, 0.195 ns data delay (0.141 ns logic,
0.054 ns routing), with +0.098 ns slack.

The first 20 setup paths are dominated by the `cut_act` to local engine input
register routes (P1-P3, P5-P10, P12-P13, P15-P16, P19), followed by
`job_k`/`bank_live1` to parameter-BRAM address paths (P4, P11, P14, P17,
P18, P20). The first three setup slacks are +0.634, +0.666, and +0.672 ns;
all 20 are positive. Routing is 81-92% of the delay on those paths.

## Gate decision

`DONE` for the actual user hard data-plane gate: timing (WNS/WHS >= 0),
resource utilization (<70%), DSP, BRAM, power, fanout, congestion and routing
all pass, and the randomized persistent-feed scoreboard proves the reuse
contract. The optional engineering margin gate of WNS >= +0.5 ns, WHS >= +0.1
ns and old-baseline LUT +10% is not met (hold misses by 0.002 ns and LUT is
6,843 versus 6,088), so those margins should not be reported as achieved.
This remains an isolated data-plane OOC result: runner integration, fullnet
exact logits/cycles and full-top post-route are still required before claiming
the complete CNN target.
