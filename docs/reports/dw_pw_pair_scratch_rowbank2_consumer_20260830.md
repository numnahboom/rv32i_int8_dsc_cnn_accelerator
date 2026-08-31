# Paired-half scratch row-bank consumer validation (2026-08-30)

## Scope

This is an isolated validation of `dw_pw_pair_scratch_rowbank2_consumer`. It
does not modify the production layer runner, DS engine, or full-network
configuration. The test retains the earlier zero-weight smoke and adds an
independent signed reference for the complete DW-half write, paired-bank
commit, PW full-K reduction, exact requantization, and narrow output drain.

## Functional evidence

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_dw_pw_pair_scratch_rowbank2_consumer_sim.sh'
```

Verilator 5.020 completed successfully:

```text
PASS retained zero-weight smoke outputs=32
PASS pair_rowbank_consumer differential jobs=4 outputs/job=32 cycles=6558
```

The four jobs cover:

* retained zero-weight 8x8 smoke (Cin=8, one group);
* signed Cin=16, P=17, Cout=13, full spatial block and channel block;
* signed Cin=48, P=17 one-pixel tail and Cout=13 five-channel tail, reverse
  group order and alternating half order;
* signed Cin=16 reuse with a new session/epoch, reverse groups, and a spatial
  and channel tail.

The reference checks all 32 row/two-lane output records per job, including
row/beat/pixel/channel tags and valid-lane masks. It exercises deterministic
input bubbles, output backpressure, output stability while stalled, paired
half order variation, commit/release, and bank reuse. Signed dot products,
bias, Q31 symmetric rounding, post-multiply shift, zero-point, int8 clamp,
and activation clamp are computed independently from the DUT.

## 8 ns XC7Z020 OOC result

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_dw_pw_pair_scratch_rowbank2_consumer_ooc_20260830.tcl
```

The run used XC7Z020 `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`,
8.000 ns clock, out-of-context synthesis, placement, and routing. The
consumer was elaborated with `MAX_CIN=48`, `MAX_COUT=16`, and
`MAX_GROUPS=16`; `MAX_GROUPS=16` is required by the current XPM scratch RAM
configuration (`MEMORY_SIZE=4096` with 256-bit writes).

| Metric | Post-route result | Gate |
|---|---:|---:|
| WNS | **-4.247 ns** | >= +0.5 ns (FAIL) |
| TNS | -672.371 ns | 0 (FAIL) |
| Setup failing endpoints | 1073 | 0 (FAIL) |
| WHS | +0.098 ns | >= 0 (PASS) |
| Hold failing endpoints | 0 | 0 (PASS) |
| Slice LUTs | 6,073 / 53,200 (11.42%) | <70% (PASS) |
| Slice registers | 13,874 / 106,400 (13.04%) | <70% (PASS) |
| Block RAM tiles | 16 / 140 (11.43%) | <70% (PASS) |
| DSPs | 86 / 220 (39.09%) | <=72 (FAIL) |
| Total on-chip power | 0.224 W | <=3 W (PASS) |
| Routing errors | 0 | 0 (PASS) |

Reports are in
`build/reports/vivado_dw_pw_pair_scratch_rowbank2_consumer_ooc_20260830/`.

The setup critical path starts at the replicated `cout_base` register and
ends in the row-bank weight staging register. Its 12.195 ns data delay is
6.630 ns logic and 5.565 ns routing, including the dynamic weight-memory
address/mux and DSP path. The routed design therefore has an estimated
maximum frequency of about 81.65 MHz at this isolated ABI, and it fails the
required +0.5 ns OOC margin by 4.747 ns. This consumer is not eligible for
production integration or full-top implementation without a different local
weight/address organization.
