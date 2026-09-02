# D4 hardware-mapping parallel screen

This is an independent, read-only architecture screen for the frozen D4
workload.  It does not modify C0, the D4 network definition, committed D4 RTL,
or production runner files.  No overlap is credited unless a later RTL test
measures it.

## Fixed workload and evidence boundary

The fixed deployment workload is D4: **11,645,440 semantic MAC** (23,290,880
operations), 204,090 parameters, INT8 activations/weights, INT32 accumulators
and biases.  Its operator ledger is 442,368 dense 3x3 MAC (3.80%), 10,223,616
PW MAC (87.79%), and 976,896 DW 3x3 MAC (8.39%).  The software INT8 result is
91.46%; this screen does not change the network or quality protocol.

Authoritative inputs:

- `docs/reports/edgembconv_hwacandidate_d4_cycle_model_20260902.md`
- `docs/reports/edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v5_20260902.md`
- `docs/reports/edgembconv_hwacandidate_d4_mb16_controller_report_20260902.md`
- `rtl/cnn/edgembconv_hwacandidate_d4_composite_datapath.v`

The guarded composite has fresh XC7Z020 post-route OOC evidence at 125 MHz:
WNS +0.616 ns, WHS +0.096 ns, 146/220 DSP (66.36%), 34.71% LUT, 21.86% FF,
0 BRAM, 0.506 W vectorless estimated power, and zero route errors.  This is
local OOC evidence only, not full-top closure.

## Common hard bounds

At frequency `f` MHz and power `P` W, the 20 GOPS/W requirement is:

`cycles * P <= 23,290,880 * f / 20,000 = 1,164,544 * f / 1,000`.

Therefore the cycle budget is 116,454 cycles at 100 MHz and 145,568 cycles at
125 MHz for 1 W.  At representative full-top powers:

| power | max cycles @100 MHz | max cycles @125 MHz |
|---:|---:|---:|
| 0.5 W | 232,908 | 291,136 |
| 1.0 W | 116,454 | 145,568 |
| 2.0 W | 58,227 | 72,784 |
| 3.0 W | 38,818 | 48,523 |

The 2.0M-cycle latency limit is weaker than this energy limit for every power
case above.  The numbers are bounds, not predicted results.

For the representative `mb16_down` block (860,160 MAC = 786,432 PW plus
73,728 DW), the 128-lane PW and existing 16-lane DW compute floors are 6,144
and 4,608 issue cycles respectively.  A four-lane RQ path must also consume at
least 4,096 result groups for the two PW outputs.  Thus a no-overlap,
II=1-RQ block floor is about **14,848 cycles**, before line-buffer fill,
weights, scratch ownership, fences, tails, and output writes.  The measured
transaction-controller result is 280,901 cycles; it is a rejected baseline,
not a bound on a new stream design.

## Candidate screen

| candidate | fixed physical organization | conservative static status | key bottleneck/risk | minimum decision experiment |
|---|---|---|---|---|
| A: persistent PW128 + DW16 | Existing 112 PW DSP + 16-DSP PW/RQ pool + 16 DW DSP + 2 schedule DSP; line-buffered persistent stream; RQ II=1 | **Static feasible, unproven**. It preserves the validated 146-DSP composition and the DW/PW story. | End-to-end ownership and RQ throughput, not multiply count. The old controller's 12-cycle RQ start interval and 280,901-cycle block cannot be carried forward. | Implement one independent `mb16_down` stream test using the II=1 elastic RQ pool, line buffer, and two-bank scratch. Require exact 8,192 bytes under stalls and measured cycles <=25,000 with no credited overlap. Then run the same pair on a 32x32 stride-1 block. |
| B: time-multiplex wider DW | Keep PW128 and 16-DSP exact RQ semantics; during DW phase reconfigure otherwise idle PW DSPs to 32/64/128 DW lanes; no additional DSP | **Static feasible only as a time-multiplexing hypothesis; high integration risk**. The DSP count can remain 146, but routing, channel grouping, line-buffer read bandwidth, and DW-to-RQ packing are not proven. | If A's RQ or scratch/fence path is the limiter, widening DW gives little benefit. It can also create a new timing/congestion hotspot while preserving the same 66.36% DSP utilization. | Starting from the passing A datapath, compare 32/64/128 DW lane modes on the same vectors and stalls. Require exact results, measured DW service II near 1, no extra DSP, and report width-vs-cycle slope. Do not build all three widths before 32-lane proves a measurable gain. |
| C: existing C0/directPW/DS route | Reuse C0/directPW/DS dataflow and its known route evidence as a control; D4 arithmetic must still be executed if it is claimed as a D4 mapping | **Comparator only; D4 feasibility unproven**. C0 evidence is for a different 5,136,896-MAC workload and cannot be relabeled as D4. | C0's measured full-top 1,003,577 cycles and WNS -0.799 ns are useful route/dataflow anchors, but its 66.16% INT8 quality and lower MAC count cannot establish D4 accuracy, latency, or energy. | Build only a D4-shaped directPW/DS adapter if A/B fail. Reuse the C0 runner contract, then require D4 exact logits, full-top post-route timing/resources/power, and a cycle count from the unchanged 11,645,440-MAC ledger. |

## Cycle targets without assumed overlap

The algebraic compute floors are useful for scale, but are not acceptance
claims.  With one shared 128-product PW issue slot, the D4 PW+dense semantic
work is at least 83,328 issue cycles (10,665,984/128); with 16 DW lanes, the
DW work is at least 61,056 cycles.  A full design also pays RQ, line-buffer,
weight, scratch, residual, tail, GAP and FC service.  Consequently:

- A should first demonstrate a complete block at <=25k measured cycles and a
  full-network projection from measured block/service rates below 145,568
  cycles at 125 MHz and the measured full-top power.  A projection is a
  triage gate, not final proof.
- B is worth prototyping only if A's measured trace identifies DW service as
  the dominant remaining term.  Its ideal DW compute term changes from
  61,056 cycles to 30,528 / 15,264 / 7,632 for 32 / 64 / 128 lanes, but these
  values deliberately exclude all memory and control overhead.  If RQ or
  scratch dominates, the theoretical reduction is irrelevant.
- C has no D4 cycle floor from current evidence and must not be ranked as a
  winner until it executes the fixed D4 workload.

At 0.506 W, the 125-MHz energy ceiling is approximately 287,882 cycles; at a
realistic full-top 1 W it is 145,568 cycles.  The existing 280,901-cycle
`mb16_down` measurement therefore leaves essentially no budget at 0.5 W and
already exceeds the 1-W full-network budget before other blocks.  This is why
RQ II=1 and measured streaming ownership are mandatory for A and B.

## Recommendation and stop rules

Prototype **A and B in parallel only at the interface/trace level**, with A as
the reference implementation and B initially as a 32-lane mode layered on the
same time-multiplexed datapath.  This avoids two conflicting scratch/runner
implementations.  Do not prototype C concurrently; it is a control path and
would consume the same integration boundary without fixed-D4 evidence.

The next判决 is deliberately small: exact `mb16_down` A trace, then the same
trace with B's 32-lane DW mode.  Record accepted PW/RQ/DW tokens, scratch
read/write ownership, actual overlap (expected to be zero until measured),
cycle count, and protocol errors.  A/B are **not** winners from this static
screen.  A measured full-network cycle count plus full-top post-route WNS/WHS,
resource, power, and exact-logit evidence are still required for the original
objective.
