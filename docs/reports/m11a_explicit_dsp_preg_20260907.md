# M1.1-A explicit DSP/PREG datapath result

Date: 2026-09-07
Status: `NEGATIVE_RESULT` for the physical timing acceptance gate; the
non-zero functional and DSP-mapping gates pass.  The current routed 8 ns
result improves setup WNS from the prior `-24.341 ns` result to `-1.796 ns`,
but it is still not timing closure.

## Baseline and scope

The implementation starts from functional checkpoint `b7e0188`.  The prior
standalone OOC snapshot used inferred arithmetic and reported 32 DSPs, no PW
MAC DSP descendants, and WNS `-29.285 ns`.  This change is isolated to the
`m11a_` path, its direct testbench/scripts, and its OOC/report artifacts; M0,
M1, `cnn_layer_runner`, `cnn_top`, and unrelated dirty paths were not changed.

## Physical datapath produced

- `rtl/cnn/m11a_dsp48e1_wrappers.v` adds explicit `DSP48E1` synthesis shells
  and cycle-matched Verilator models.  INT8 MAC wrappers use internal PREG
  feedback (`OPMODE=0000101` for clear and `0100001` for M+P), so the K
  recurrence is not cut by an ordinary external accumulator register.
- `m11a_dw16_shared_line.v` has 16 explicit DW MAC DSPs.  DWRQ4 is a
  four-lane, four-partial-product 33x32 signed requantizer (16 DSPs) reused
  across the 16-byte DW vector with held valid/data under backpressure.
- `m11a_pw64_shared_core.v` has 64 explicit PW MAC DSPs.  The final K
  product is committed through an explicit one-edge PREG drain without
  reducing the 64-MAC token or changing the K recurrence cadence.  PWRQ4 is
  another registered four-lane/16-DSP requantizer with stable ready/valid
  metadata.

Structural audit:

```text
M11A_STRUCTURE_PASS unique_dw16=1 unique_pw64=1 pw_mac_lanes=64 shared_3line=1 pw_row_bram=1 explicit_dsp_accum=1 rq4_instances=2 old_consumer_refs=0
```

## Functional gate

The current direct run regenerated the independent non-zero fixture and
passed all four required streams.  Every row has `mismatches=0`,
`protocol_errors=0`, `error=0`, exact output/address/context/owner/epoch/last
metadata, and exact MAC/token/output ledgers.

| Case | Cycles | DW vectors/MAC | PW tokens/MAC | Input reads | Stalls |
|---|---:|---:|---:|---:|---:|
| DS1, no backpressure | 96,061 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 0 |
| DS1, random backpressure | 100,615 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 7,984 |
| DS2, no backpressure | 199,133 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 0 |
| DS2, random backpressure | 246,909 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 4,079 |

Evidence: `scripts/run_m11a_runtime_dw_pw_core_sim.sh`,
`docs/reports/m11a_nonzero_fixture_rtl_20260907.md`, and the four logs under
`build/m11a_runtime_dw_pw_core/`.

## Current-source XC7Z020 OOC

The final run used Vivado 2025.2, part `xc7z020clg400-1`, 8.000 ns clock, and
the source manifest in
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/source_manifest.txt`.  The
source paths are unchanged in checkpoint `09e5a8c`.

| Partition / resource | Actual post-route count |
|---|---:|
| DW MAC (`GEN_DW16_MAC`) | 16 DSP48E1 |
| PW MAC (`GEN_PW64_MAC`) | 64 DSP48E1; 64 `m11a_pw_mac_cell` descendants |
| DWRQ4 | 16 DSP48E1 |
| PWRQ4 | 16 DSP48E1 |
| Total DSP48E1 | 112 |
| Slice LUTs | 14,139 |
| Slice registers | 19,592 |
| RAMB36 | 1 |

The route status is 34,064/34,064 fully routed nets with 0 routing errors.
Post-route DRC has no error-severity violation; it contains 224
input-pipelining, 2 PREG-output-pipelining, 32 MREG-output-pipelining, one
no-load, and one OOC PS7 warning.

Timing is the first failed acceptance condition:

- setup WNS `-1.796 ns`, TNS `-1,771.989 ns`, 3,627 failing endpoints;
- hold WHS `+0.040 ns`, no hold violation;
- worst setup path:
  `cfg_store/prep_cout_reg[3]_replica_3/C` ->
  `cfg_store/prep_pw_byte_reg[4]/CE`, 9.543 ns data delay, 12 logic levels
  (`5 CARRY4`, four LUT6), with 58.484% routing delay;
- the registered RQ4 repair removed the former RQ assembly long path, but the
  configuration-store preparation cone is now the timing limiter.  Exact RQ
  arithmetic and metadata remain functionally correct; the 8 ns timing gate
  does not pass.

This result must not be presented as timing closure or a completed M1.1-A
physical acceptance.  Any next repair must target the `cfg_store` preparation
cone while preserving the verified DSP count, PW descendant mapping, and
non-zero fixture semantics.
