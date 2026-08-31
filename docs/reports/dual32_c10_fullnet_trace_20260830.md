# dual32 C10 full-network schedule trace — 2026-08-30

## Scope

This is a deterministic tick-level model at the standalone
`dual32_mac_local_island` port boundary. It does not modify or instantiate
`cnn_top`, `cnn_layer_runner`, SRAM, or the physical pipeline. It uses the
real C10 shapes and the macro's fixed 32-bit source/parameter and 4-byte
commit contract. `baseline` is backpressure-free; `stress` repeats the
measured testbench bubble/output-stall pattern and is not full-top evidence.

## Reproduction

```text
python scripts/model_dual32_c10_trace_20260830.py
```

It writes `build/reports/dual32_c10_fullnet_trace_20260830.csv`, the
per-block tick trace `build/reports/dual32_c10_fullnet_block_trace_20260830.csv`, and this
report. The macro calibration command was:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_dual32_mac_local_island_sim_nobp.sh > build/dual32_mac_local_island_sim_nobp_20260830.log 2>&1'
```

The measured stressed command was `scripts/run_dual32_mac_local_island_sim.sh`.

## Macro calibration

The model decomposes a block as `K` accumulator issue cycles + fixed
result/RQ latency + fixed 4-byte FIFO/drain commits. The formula matches
both no-backpressure and measured stressed traces:

| probe | no-BP measured/model | stressed measured/model | error |
|---|---:|---:|---:|
| Stem k=3 | 25/25 | 30/30 | 0 cycles |
| PW DS1 k=16 | 37/37 | 44/44 | 0 cycles |
| PW DS6 k=128 | 149/149 | 168/168 | 0 cycles |
| DW k=9 | 22/22 | 26/26 | 0 cycles |
| PW tails 6xk=16 | 222/222 | 260/260 | 0 cycles |

The no-BP run itself finished `PASS`, 152 commits, 592 total simulation
cycles (including test setup), with 519 cycles across the five case bodies.
The per-case measured no-BP values were Stem 25, PW16 37, PW128 149, DW9
22, and six PW tail blocks 222. The stressed run was 30, 44, 168, 26,
and 260 respectively. All 152 commits and 445 active output bytes matched
the independent reference; there were no input-ready stalls.

## Per-stage ledger

`config_records`/`config_cycles` are also explicit: PW/STEM require 64
narrow cfg transactions per output-channel tile (32 lanes per island,
serialized across two islands), while DW requires 32 on island 0.
`descriptor_words=32` and `descriptor_cycles=32` are explicit model charges
for one legal 32-word descriptor operation. `fence_stall_cycles=1` is the
modeled busy-low observation before the next descriptor. No extra block fence
is hidden: the old q2 ready chain makes each block serial, and its output
drain is already charged in `fifo_drain_cycles`.
The companion block CSV has 3,330 legal macro-block rows with absolute
baseline/stress start and end ticks, pixel/channel bases, masks, traffic,
and active/capacity MAC; this is the replayable tick-level schedule trace.

| stage | shape/mode | blocks | source | param | cfg rec/cyc | acc | RQ/result | FIFO/drain | fence | commits | active/cap MAC | util | baseline interval | stress interval |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Stem | P1024, Cin3, Cout16, K27, s1 STEM | 256 | 6912 | 27648 | 64/64 | 6912 | 1536 | 4096 | 1 | 4096 | 442368/442368 | 100.0% | 0-12641 (12641) | 0-14689 (14689) |
| DS1 DW | P1024, Cin16, Cout16, K9, s1 DW | 512 | 4608 | 9216 | 64/64 | 4608 | 2560 | 4096 | 1 | 4096 | 147456/147456 | 100.0% | 12641-24002 (11361) | 14689-28098 (13409) |
| DS1 PW | P1024, Cin16, Cout32, K16, s1 PW | 512 | 16384 | 16384 | 256/256 | 8192 | 2560 | 8192 | 1 | 8192 | 524288/524288 | 100.0% | 24002-43235 (19233) | 28098-50915 (22817) |
| DS2 DW | P256, Cin32, Cout32, K9, s2 DW | 256 | 2304 | 4608 | 128/128 | 2304 | 1280 | 2048 | 1 | 2048 | 73728/73728 | 100.0% | 43235-49028 (5793) | 50915-57732 (6817) |
| DS2 PW | P256, Cin32, Cout64, K32, s2 PW | 256 | 16384 | 16384 | 512/512 | 8192 | 1280 | 4096 | 1 | 4096 | 524288/524288 | 100.0% | 49028-63141 (14113) | 57732-74149 (16417) |
| DS3 DW | P256, Cin64, Cout64, K9, s1 DW | 512 | 4608 | 9216 | 256/256 | 4608 | 2560 | 4096 | 1 | 4096 | 147456/147456 | 100.0% | 63141-74694 (11553) | 74149-87750 (13601) |
| DS3 PW | P256, Cin64, Cout64, K64, s1 PW | 256 | 32768 | 32768 | 512/512 | 16384 | 1280 | 4096 | 1 | 4096 | 1048576/1048576 | 100.0% | 74694-96999 (22305) | 87750-113127 (25377) |
| DS4 DW | P64, Cin64, Cout64, K9, s2 DW | 128 | 1152 | 2304 | 256/256 | 1152 | 640 | 1024 | 1 | 1024 | 36864/36864 | 100.0% | 96999-100104 (3105) | 113127-116744 (3617) |
| DS4 PW | P64, Cin64, Cout128, K64, s2 PW | 128 | 16384 | 16384 | 1024/1024 | 8192 | 640 | 2048 | 1 | 2048 | 524288/524288 | 100.0% | 100104-112041 (11937) | 116744-130217 (13473) |
| DS5 DW | P64, Cin128, Cout128, K9, s1 DW | 256 | 2304 | 4608 | 512/512 | 2304 | 1280 | 2048 | 1 | 2048 | 73728/73728 | 100.0% | 112041-118218 (6177) | 130217-137418 (7201) |
| DS5 PW | P64, Cin128, Cout128, K128, s1 PW | 128 | 32768 | 32768 | 1024/1024 | 16384 | 640 | 2048 | 1 | 2048 | 1048576/1048576 | 100.0% | 118218-138347 (20129) | 137418-159979 (22561) |
| DS6 DW | P16, Cin128, Cout128, K9, s2 DW | 64 | 576 | 1152 | 512/512 | 576 | 320 | 512 | 1 | 512 | 18432/18432 | 100.0% | 138347-140300 (1953) | 159979-162188 (2209) |
| DS6 PW | P16, Cin128, Cout256, K128, s2 PW | 64 | 16384 | 16384 | 2048/2048 | 8192 | 320 | 1024 | 1 | 1024 | 524288/524288 | 100.0% | 140300-151917 (11617) | 162188-175021 (12833) |
| FC | P1, Cin256, Cout10, K256, s1 PW | 2 | 1024 | 1024 | 128/128 | 512 | 10 | 32 | 1 | 32 | 2560/32768 | 7.8% | 151917-152632 (715) | 175021-175802 (781) |
| **total** | 14 macro ops | 3330 | 154560 | 190848 | 7296/7296 | 88512 | 16906 | 39456 | 14 | 39456 | 5136896/5167104 | 99.4% | 152632 | 175802 |

Valid output bytes (after masks) are not equal to fixed commit words:
the model produces 157706 valid bytes and 39456 four-byte commits.
The deterministic stress projection adds 9976 input-bubble cycles
and 13194 output-backpressure cycles over the baseline.

## Projection and promotion decision

The arithmetic total is 5,136,896 MAC, including FC=2,560 MAC, matching the
project target. At 125 MHz and an explicitly conservative 0.39 W projected
power charge, baseline completion is **152632 cycles**, so
`Cprojected*0.39 = 59526.48` and projected energy is
`21.57 GOPS/W`. The stressed projection is
**175802 cycles**, `68562.78` cycle-watts, and
`18.73 GOPS/W`.
The baseline service rate is 33.66 active MAC/cycle
(stress 29.22); a 135k-cycle screen requires
38.05 active MAC/cycle.

The baseline clears the hard 155k screen and misses the 57,790 cycle-watt screen (margin to 155k: 2368 cycles; margin to 57,790: -1736.48).
It misses the preferred 145k screen by 7632 cycles. This is a macro-boundary
schedule result, not a full-top acceptance result: descriptor/SRAM latency,
real DW window production, address generation, and runner fences are not
credited beyond the explicit descriptor/fence charges.

## q2-ready chain and legal overlap

The macro's `ready_in` is deasserted while `drain_active` is set, and the
final output is selected by a priority mux. Therefore a legal next block
cannot issue until the previous block's fixed 4-byte commits have drained;
there is no block overlap in this model. `q2_ready -> qf_ready -> q1_ready
-> q0_ready` can absorb output backpressure only inside the current block;
it cannot provide a second block context or hide the drain. The stress view
therefore charges output stalls directly and does not claim overlap.

## Coverage limits

- Stem is modeled at the requested full spatial shape P=1024, K=27, Cout=16.
- Each DS layer uses the real C10 P/Cin/Cout/stride shape; DW uses K=9 and
  PW uses K=Cin. Stride affects P through the supplied output shape.
- Source/parameter words are macro-port transfers, so PW repeats the 8-pixel
  source window per output-channel tile as the current contract requires.
- There is no RTL measurement of this complete schedule, no fullnet logits
  run, and no full-top post-route result for this macro. Promotion must wait
  for an integrated implementation or a separately validated producer/consumer
  contract.
