# D4 shared DSP pool: registered requant pipeline

This is an isolated D4 hardware-aware candidate artifact.  It does not alter
C0, its training outputs, RTL, reports, or checkpoint paths.

## Implementation change

`rtl/cnn/edgembconv_hwacandidate_d4_dsp_pool.v` keeps exactly sixteen
DSP48E1s shared by PW and RQ transactions.  The DSP output now uses `PREG=1`
and the behavioral model has the same one-cycle capture latency.  RQ is split
into explicit registered stages:

1. DSP partial-product capture;
2. two pairwise 64-bit partial sums;
3. final 64-bit product;
4. magnitude extraction;
5. nearest-away half-LSB addition;
6. variable right shift;
7. sign restoration;
8. zero-point addition;
9. int8 saturation;
10. output commit.

The interface remains ready/valid and accepts a mode change only at an empty
transaction boundary.  The output register is held under `ready_out=0`.
PW remains exact signed INT8×INT8; RQ remains exact signed INT32×INT32 with
per-lane shift, zero point, activation limits, nearest-away rounding, and
saturation.  Saturation uses a sign-extension range test before the activation
clamp, reducing the critical 64-bit comparator cone without changing the
valid int8 activation contract.

## Functional evidence

Command (WSL, using the generated real-vector directory):

```text
verilator --binary --timing --Wall --Wno-fatal --top-module tb_edgembconv_hwacandidate_d4_dsp_pool -f sim/filelist_edgembconv_hwacandidate_d4_dsp_pool.f
```

Observed result:

```text
D4_DSP_POOL_PW n=0 latency_cycles=1 output_stall=0
D4_DSP_POOL_PW n=1 latency_cycles=1 output_stall=0
D4_DSP_POOL_RQ n=0 latency_cycles=10 output_stall=1
D4_DSP_POOL_PW n=2 latency_cycles=1 output_stall=0
D4_DSP_POOL_RQ n=1 latency_cycles=10 output_stall=1
D4_DSP_POOL_RQ n=2 latency_cycles=10 output_stall=0
D4_DSP_POOL_RQ n=3 latency_cycles=10 output_stall=0
D4_DSP_POOL_RQ n=4 latency_cycles=10 output_stall=0
PASS edgembconv_hwacandidate_d4_dsp_pool physical_dsp_contract=16 pw_records=3 rq_records=5 random_backpressure=checked
```

The vectors include real D4 dense/DW deployment data, signed INT8 boundary
products, signed INT32 extrema, real per-channel multipliers (shift 31), and
the audited mb32 residual coefficients (shift 30).  The testbench uses a
deterministic xorshift choice of output stalls, checks data/metadata stability
while blocked, and alternates PW/RQ modes across transaction boundaries.

## Fresh XC7Z020 post-route OOC evidence

Script:

```text
scripts/run_edgembconv_hwacandidate_d4_dsp_pool_ooc_threads8_20260902.ps1
```

Device `xc7z020clg400-1`, 8.000 ns clock, Vivado 2025.2,
`general.maxThreads=8`, `RuntimeOptimized` synthesis, Explore place/phys-opt/
route:

| Metric | Post-route result |
|---|---:|
| WNS | +0.988 ns |
| WHS | +0.124 ns |
| TNS / THS | 0 / 0 ns |
| routed nets with errors | 0 |
| LUT | 2,818 |
| FF | 3,533 |
| DSP48E1 | 16 |
| RAMB36 / RAMB18 | 0 / 0 |
| estimated total on-chip power | 0.140 W |

Reports are under
`build/reports/vivado_edgembconv_hwacandidate_d4_dsp_pool_ooc_threads8_20260902/`.
The DRC report has no AVAL error after explicitly matching `BREG=0` and
`BCASCREG=0`; remaining entries are input/output pipelining warnings and
normal OOC PS7/advisory warnings.  This is primitive OOC evidence, not a
full-top timing or end-to-end inference claim.

## Risk / next use

The RQ path now has a measured 10-cycle input-to-visible-output latency and is
intentionally single-entry at this isolated contract.  A consuming dataflow
must account for this latency and must not infer two-beat RQ throughput from
the four-lane output width.  Full-network cycle and bit-exact evidence still
belongs to the D4 integration stage.
