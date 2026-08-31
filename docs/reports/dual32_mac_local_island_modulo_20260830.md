# dual32 local-island modulo FIFO update (2026-08-30)

## RTL changes

`rtl/cnn/dual32_mac_local_island.v` now places each completed 32-MAC block in
a local two-entry result FIFO.  FIFO entries retain all 32 accumulator sums,
block metadata, and quantization limits.  The accumulator writes the completed
sum and may capture the next block's first token at the same clock boundary.
The drain side copies one FIFO entry into local registers, then uses registered
input, product, fixed-point round/shift, and output stages.  `ready_out` is not
used by `ready_in`; only local FIFO fullness and the one-token stage boundary
can stop admission.  The wrapper's single external commit port still has its
required island-0 priority arbitration.

## Validation

```text
scripts/run_dual32_mac_local_island_sim_nobp.sh
PASS dual32_local_island commits=152 cycles=529 source_words=492 param_words=510

scripts/run_dual32_mac_local_island_sim.sh
PASS dual32_local_island commits=152 cycles=601 source_words=492 param_words=510
```

All STEM, PW K16/K128, DW K9, and P17/C13 tail cases passed.  The stress run
included bubbles and output stalls and checked 445 valid output bytes.

The dedicated FIFO test holds `ready_out=0` and accepts exactly three one-token
blocks before the two local result slots and the in-flight block are occupied:

```text
scripts/run_dual32_mac_local_island_fifo_sim.sh
PASS dual32_local_island_fifo accepted=3 first_cycles=67,69,71 busy=1
```

Measured contiguous block II with output ready:

```text
scripts/run_dual32_mac_local_island_ii_sim.sh
II_CASE mode=0 K=16  accepted=32  first=67  second=84  II=17
II_CASE mode=0 K=128 accepted=256 first=122 second=251 II=129
II_CASE mode=1 K=27  accepted=54  first=401 second=429 II=28
II_CASE mode=2 K=9   accepted=18  first=478 second=488 II=10
PASS dual32_local_island_ii
```

The C10 trace model was rerun unchanged because this macro is not integrated
under `cnn_layer_runner`:

```text
PASS dual32_c10_trace stages=14 mac=5136896 baseline_cycles=152632 stress_cycles=175802 source_words=154560 param_words=190848 commits=39456
STRESS input_bubbles=9976 output_stalls=13194
```

These model cycles are projection evidence, not full-top RTL evidence.

## OOC result

Fresh Vivado 2025.2 XC7Z020 8 ns post-route completed successfully, with no
route/DRC errors, but it fails the OOC gate:

```text
WNS -2.091 ns, TNS -3040.911 ns, setup failing endpoints 2901
WHS -0.502 ns, THS -1719.278 ns, hold failing endpoints 5324
LUT 7556 (14.20%), FF 13322 (12.52%), DSP 96 (43.64%), BRAM 0, power 0.404 W
```

The worst setup path is `u_island0/q0_acc_reg[1][0]/C` to
`u_island0/q1_prod_reg[1]/C[42]`: 8.306 ns data delay, 5.958 ns logic
(71.728%) and 2.348 ns route (28.272%), with nine CARRY4s, one DSP48E1 and
one LUT2.  The next paths are the same accumulator-to-DSP product cone.
The largest non-clock fanouts are island-1/island-0 `q2_valid` nets at 4703/
4689, followed by FIFO accumulator write enables at 1024 each.  The wrapper's
unassociated OOC clock net is reported at fanout 13417, so its skew is not a
full-top clock-tree estimate.  The result is
therefore a precise negative OOC result: the FIFO/modulo function is correct,
but this implementation still has a long accumulator carry-to-DSP cone and
large output-valid/control fanout.  It must not be integrated into full-top.
