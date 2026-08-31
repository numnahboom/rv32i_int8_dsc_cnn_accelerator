# Unified 64-MAC tile-engine hard-decision experiment (2026-08-31)

## Scope and boundary

This is an isolated experiment. It does not modify or instantiate `cnn_top` or
`cnn_layer_runner` in the production path. The new tile engine uses a fixed
8x8 output-stationary array (64 instances of the already validated
`pw_rowbank_mac_cell`), two fixed result banks, and a four-byte commit stream.
The persistent wrapper instantiates `ds_persistent_feed_contract_bram` with
fixed-address BRAM storage and maps its real token stream into the array.

The array accepts one K token per cycle after the one-entry ingress stage. A
completed bank can be committed while the other bank accepts the next block.
Rows are selected as 256-bit local row registers; there is no dynamic
2048-bit bank mux. The four exact requant lanes follow the elastic
`requant_activation_stream4` contract and widen only the observable tags for
large-P/256-channel jobs.

## Functional evidence

Commands (run in WSL with Verilator 5.020):

```text
bash scripts/run_unified64_tile_engine_experiment_sim.sh
bash scripts/run_unified64_tile_engine_persistent_sim.sh
```

The raw-array differential regression passed:

```text
PASS unified64 blocks=25 commits=400 tokens=1344 masked_macs=69248 stalls=24 overlap=192 peak_occ=2 cycles=2718
```

It covered PW K=16/64/128, a complete K=27 stream, P tails 1/8/17/64,
Cout tails 8/13/16, signed exact requant, bubbles, output backpressure and
double-bank overlap. `overlap=192` and `peak_occ=2` show compute admissions
while a prior bank was draining.

The persistent-feed composition passed with non-zero source and parameter
tokens, two jobs, a spatial/channel tail, output backpressure, and stale
epoch/session rejection:

```text
PASS persistent jobs=2 outputs=32 feed_tokens=32 source_words=4096 param_words=128 local_reads=96/32 reuse=0 commits=32 stalls=1 overlap=0
```

`metric_nonzero_token_count=32` and `metric_masked_mac_count=1408` were both
non-zero. The persistent-feed look-ahead cursor was registered so the next
parameter row is issued at II=1 without using `job_k_reg` in the BRAM address
cone. This change is confined to the untracked BRAM proof vehicle, not the
production runner.

## Measured OOC result

The final fresh run used Vivado 2025.2, `xc7z020clg400-1`, 8.000 ns clock,
`general.maxThreads=2`, Explore placement/physical optimization/route:

| Metric | Result | Hard gate | Result |
|---|---:|---:|---|
| WNS | +0.284 ns | >= +0.500 ns | **FAIL** |
| TNS / setup failing endpoints | 0.000 ns / 0 | 0 | PASS |
| WHS / THS | +0.098 ns / 0.000 ns | >= +0.100 ns / 0 | **FAIL (0.002 ns)** |
| LUT | 5,535 (10.40%) | <=10,000 | PASS |
| FF | 15,982 (15.02%) | <=24,000 | PASS |
| DSP | 80 (36.36%) | <=96 | PASS |
| BRAM36 tiles | 12 (8.57%) | <=32 | PASS |
| Total on-chip power | 0.318 W | <=0.36 W | PASS |
| Routed nets / route errors | 21,350 / 0 | 0 errors | PASS |
| Maximum reported non-clock fanout | 8,608 | <1,000 | **FAIL** |

The authoritative files are under
`build/reports/vivado_unified64_tile_engine_experiment_ooc_20260831/`:
`timing_summary_post_route.txt`, `utilization_post_route.txt`,
`power_post_route.txt`, `route_status_post_route.txt`,
`high_fanout_post_route.txt`, and `congestion_post_route.txt`.

The worst setup path is a requant multiplier register to a requant DSP input:
data delay 7.182 ns, of which 6.726 ns (93.65%) is routing. The hard OOC
experiment therefore fails on physical locality/fanout, not on DSP, BRAM,
LUT, FF, power, or arithmetic correctness. The highest fanout nets are
`u_feed/source_base_reg[0]` (8,608), `u_engine/in_stage_last` (5,187), and
the two bank row nets (2,048 each). This also explains why a narrower counter
implementation and per-column activation replication improved basic WNS but
did not meet the +0.5 ns and <1k locality gates. The congestion report contains
no level-5-above window, but does not emit a numeric global maximum below the
requested 80% threshold; congestion <80% is consequently not claimed.

## Cycle projection

Using the measured raw-array block service (`2718/400 = 6.795` cycles per
four-byte commit beat, including the measured backpressure pattern), the three
PW stages project as follows:

| Stage | PW blocks | K tokens | 4-byte commits |
|---|---:|---:|---:|
| DS1: P=1024, Cin=16, Cout=32 | 512 | 8,192 | 8,192 |
| DS3: P=256, Cin=64, Cout=64 | 256 | 16,384 | 4,096 |
| DS6: P=16, Cin=128, Cout=256 | 64 | 8,192 | 1,024 |
| Total | 832 | 32,768 | 13,312 |

The measured commit-dominated estimate is 90,455 cycles. A 32-valid-MAC/cycle
DW stream for the corresponding 313,344 DW MACs adds 9,792 cycles, and one
cycle per block for bank/fence turnaround adds 832 cycles. The resulting
compute/commit projection is approximately **101,079 cycles**. Adding the
measured independent persistent-load service estimate (18,048 external words
with the observed source/parameter ready patterns, approximately 20,350
cycles) gives an upper-bound **121,429 cycles**, below the requested 150k
tile/DS projection when feed loading is overlapped or amortized. This is a
projection of the isolated DS tile dataflow, not a full-network result: it does
not prove the stem, FC, runner integration, fullnet logits, or full-top route.

## Hard decision

**NEGATIVE_RESULT for the requested OOC gate.** The architecture is functionally
complete at the tile-contract level and has sufficient DSP/BRAM/power and a
promising measured II, but the integrated persistent-feed implementation fails
the explicit WNS margin, WHS margin, and maximum-fanout gates. The dominant
failure is route delay in a physically separated requant island plus the
persistent-feed/global control nets; it is not justified to integrate this
snapshot into the production runner or claim fullnet/full-top completion.

Changed experiment files:

- `rtl/cnn/unified64_tile_engine_experiment.v`
- `rtl/cnn/ds_persistent_feed_contract_bram.v` (registered parameter look-ahead cursor)
- `sim/tb_unified64_tile_engine_experiment.v`
- `sim/tb_unified64_tile_engine_persistent.v`
- `sim/filelist_unified64_tile_engine_experiment.f`
- `sim/filelist_unified64_tile_engine_persistent.f`
- `scripts/run_unified64_tile_engine_experiment_sim.sh`
- `scripts/run_unified64_tile_engine_persistent_sim.sh`
- `scripts/vivado_unified64_tile_engine_experiment_ooc_20260831.tcl`
