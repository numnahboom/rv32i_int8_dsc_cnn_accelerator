# M1.1-A DW16 operand-input pipeline

Date: 2026-09-07
Status: `NEGATIVE_RESULT` for the 125 MHz physical timing-closure gate;
functional and structural gates pass. This is standalone M1.1-A evidence only,
not `cnn_layer_runner`/`cnn_top` or full-top evidence.

## Scope and baseline

The owned RTL change is limited to
[`rtl/cnn/m11a_dw16_shared_line.v`](../../rtl/cnn/m11a_dw16_shared_line.v).
The previous candidate selected `tap_act`/`tap_wgt` combinationally from
`tap_idx`, line-memory reads, and the weight bus, and drove the 16 DW DSP A/B
inputs directly. The change inserts `tap_act_r[0:15]` and `tap_wgt_r[0:15]`
registers, a registered `tap_mac_valid`/`tap_mac_clear` pair, and
`ST_TAP_DRAIN`.

The nonblocking-assignment schedule is intentional: the first `ST_TAP` edge
captures tap 0 while the DSP CE is still low; each following `ST_TAP` edge
commits the operands captured on the preceding edge; `ST_TAP_DRAIN` commits
tap 8 while disabling CE for the next edge; only then does `ST_RQ` sample the
completed 16 accumulators. Thus all nine taps remain in the DSP recurrence,
the first tap is the clear term, and the existing 16-MAC vector ledger is not
changed. No interface, arithmetic precision, metadata, backpressure, or
production-top path was changed.

## Functional and structural validation

Commands:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/audit_m11a_runtime_dw_pw_structure.ps1
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_m11a_runtime_dw_pw_core_sim.sh'
```

The structural audit passed:

```text
M11A_STRUCTURE_PASS unique_dw16=1 unique_pw64=1 pw_mac_lanes=64 shared_3line=1 pw_row_bram=1 explicit_dsp_accum=1 rq4_instances=2 old_consumer_refs=0
```

The fresh non-zero fixture run passed all four cases. Every case had
`mismatches=0`, `protocol_errors=0`, `error=0`, and exact output/address/
context/owner/epoch/last metadata and MAC/token ledgers.

| Case | Cycles | Outputs | DW vectors / MAC | PW tokens / MAC | Input reads | Pad taps | Payload stalls |
|---|---:|---:|---:|---:|---:|---:|---:|
| DS1, no backpressure | 96,958 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 380 | 0 |
| DS1, randomized backpressure | 101,617 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 380 | 8,131 |
| DS2, no backpressure | 199,614 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 95 | 0 |
| DS2, randomized backpressure | 247,830 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 95 | 4,119 |

Authoritative raw logs are under
`build/m11a_runtime_dw_pw_core/layer*.log`; the generated summary is
[`m11a_nonzero_fixture_rtl_20260907.md`](m11a_nonzero_fixture_rtl_20260907.md).
The DS2 `input_reads=48,128` value above is the fresh RTL log result. An older
design note derives `25,568` for a different/shared-store schedule; that stale
derivation is not evidence for this candidate and is not used here.

## XC7Z020 post-route OOC

The current source set was implemented serially with Vivado 2025.2,
`xc7z020clg400-1`, and an 8.000 ns clock:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl *> build/reports/m11a_runtime_dw_pw_core_ooc_8ns/vivado_m11a_dw_operand_run.log
```

The source manifest is
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/source_manifest.txt`.
Post-route evidence:

- Route: 33,827 / 33,827 routable nets fully routed; 0 routing errors.
- DRC: 0 error-severity violations. Warnings are the expected DSP input/MREG
  pipelining checks (224/32), one no-routable-load check, and the OOC PS7
  check; 112 primitive advisory checks are also listed.
- Resources: 13,914 LUT (26.15%), 19,634 FF (18.45%), 1 RAMB36 (0.71%),
  112 DSP48E1 (50.91%). The post-route partition query reports
  `dw_mac=16`, `pw_mac=64`, `dw_rq4=16`, `pw_rq4=16`, total `112`.
- Setup: WNS `-0.402 ns`, TNS `-109.525 ns`, 817 failing endpoints.
- Hold: worst slack `+0.071 ns`; no hold violation (THS `0`).

The batch log also contains three transient Common 17-1257/17-354 messages
(`Failed to create directory 'C'` / `Could not open 'C' for writing`) during
Vivado synthesis path bookkeeping because this direct invocation did not set
the wrapper's `HOME` workaround. Synthesis, placement, phys_opt, and routing
all completed; the final log summary is `0 Errors encountered`, and every
post-route report and the DCP was generated. These messages are an invocation
environment issue, not a timing or RTL result.

The DW16 tap/input cone is no longer the limiting cone in the fresh report.
The first failing path is instead the untouched PW-side row BRAM output:
`cfg_store/pw_row_mem_reg/CLKARDCLK` ->
`pw64/GEN_PW64_MAC[31].u_mac/u_dsp48e1/u_dsp48e1_int8_accum/B[3]`, with
4.782 ns data delay (2.454 ns RAMB36 clock-to-out and 2.328 ns routing) and
slack `-0.402 ns`. This is a direct PW operand path outside this DW16 slice;
the candidate is therefore retained as the best attributable DW repair, but
the OOC 125 MHz timing gate remains open.

Reports: `timing_summary_post_route.rpt`, `timing_max.rpt`, `timing_min.rpt`,
`route_status_post_route.rpt`, `utilization_post_route.rpt`,
`utilization_post_route_hierarchical.rpt`, `drc_post_route.rpt`, and
`post_route_structure_query.txt` under
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/`.

## Evidence boundary

This change preserves the standalone M1.1-A interfaces and exact non-zero
functional ledgers, but it does not prove integration, full-network cycles,
power, energy efficiency, or full-top post-route closure. No Git commit was
made.
