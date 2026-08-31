# Single 4x8 DW producer / paired scratch / PW rowbank screen (2026-08-30)

## Scope

`ds_word_window_dw_pw_single_producer_pipeline` is a non-production successor
to the two-producer paired-scratch shell.  It retains one shared stream4
requant island, the row-image BRAM transfer fence, and the packed PW rowbank
consumer, but instantiates exactly one
`ds_word_window_dw_producer_island` (`u_dw0`).  The compatibility `fill1` and
`dw1` boundary signals are tied off; upper/lower commands are serialized
through the same producer and shared requant path.  Production `cnn_top` and
`cnn_layer_runner` are untouched.

The shell is a screening successor, not a claim of complete 8x8 network
integration.  The current smoke test exercises the BRAM gather, paired
ownership fence, packed weight loader, PW arithmetic, output backpressure and
32 output beats.  A future dedicated test must drive two real producer jobs
with independent source fills and check the top/bottom numerical mapping and
DW-B/PW-A overlap before promotion.

## Functional evidence

Command:

```text
bash scripts/run_ds_word_window_dw_pw_single_producer_pipeline_sim.sh
```

Result:

```text
PASS single producer pipeline fence outputs=32 cycles=122 overlap=0 writes=0 reads=8
```

This is a fence/consumer smoke test.  It does not establish producer
throughput or overlap; `overlap=0` is explicitly recorded rather than hidden.

## 8 ns XC7Z020 OOC evidence

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_pw_single_producer_pipeline_ooc_20260830.tcl
```

Post-route reports are under
`build/reports/vivado_ds_word_window_dw_pw_single_producer_pipeline_ooc_20260830/`.

| metric | post-route | gate |
|---|---:|---:|
| WNS | +0.309 ns | >= +0.5 ns |
| TNS / setup failures | 0 ns / 0 | 0 / 0 |
| WHS / hold failures | +0.094 ns / 0 | >= 0 / 0 |
| LUT | 7,512 (14.12%) | <70% |
| FF | 24,609 (23.13%) | <70% |
| RAMB36 / RAMB18 | 34 / 12 (24.29% / 4.29%) | <70% |
| DSP48E1 | 104 | <=104 |
| estimated total on-chip power | 0.380 W | <=0.35 W screen |
| route status | 0 unrouted / 0 partial | clean |

Highest post-route fanout includes PW `bank_state` at 7,326 loads,
DW `out_pixel_idx[5]` at 2,541, and DW `cfg_fire` at 1,120.  Therefore this
candidate fails the requested +0.5 ns margin, the 0.35 W local screen, and
the locality/fanout screen despite clean routing and resource headroom.  It
must not be integrated into the production runner or full top.

## Decision

Keep the one-producer shell as protocol and cost evidence only.  Its useful
result is that removing the second DW producer reduces DSP to 104, but the
remaining shared PW control fanout dominates timing/power and the current
bench has no measured DW-B/PW-A overlap.  Next work should add a real
two-half source-fill differential bench or abandon this broad shell in favor
of a locally partitioned producer/consumer boundary; no full-top run is
justified by the present evidence.
