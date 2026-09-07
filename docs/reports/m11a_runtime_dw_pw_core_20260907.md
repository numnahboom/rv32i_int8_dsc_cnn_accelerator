# M1.1-A runtime DW16 -> PW64 candidate

Date: 2026-09-07
Status: standalone candidate evidence complete; not integrated into `cnn_layer_runner`/`cnn_top`

## Scope and boundary

This checkpoint covers the independent `m11a_` path only. It does not modify or
replace the existing M0/M1 consumer, adapter, top-level, configuration, or
activation-store paths. The five RTL sources used by the OOC run are recorded in
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/source_manifest.txt`.

Implemented artifacts:

- [`m11a_runtime_cfg_store.v`](../../rtl/cnn/m11a_runtime_cfg_store.v): DS1/DS2 packed configuration store and `{cout_tile,k}` 64-bit PW row store.
- [`m11a_dw16_shared_line.v`](../../rtl/cnn/m11a_dw16_shared_line.v): one DW16 engine, three 128-bit line memories, SAME halo handling, stride 1/2.
- [`m11a_context_packer.v`](../../rtl/cnn/m11a_context_packer.v): eight-pixel context transpose/packer.
- [`m11a_pw64_shared_core.v`](../../rtl/cnn/m11a_pw64_shared_core.v): one 64-lane PW MAC, synchronous row prefetch, two result banks, PWRQ4 drain.
- [`m11a_runtime_dw_pw_core.v`](../../rtl/cnn/m11a_runtime_dw_pw_core.v): independent runtime top.
- [`tb_m11a_runtime_dw_pw_core.v`](../../sim/tb_m11a_runtime_dw_pw_core.v), [`run_m11a_runtime_dw_pw_core_sim.sh`](../../scripts/run_m11a_runtime_dw_pw_core_sim.sh), and [`audit_m11a_runtime_dw_pw_structure.ps1`](../../scripts/audit_m11a_runtime_dw_pw_structure.ps1): direct validation and structural checks.

## Structural audit

Command:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/audit_m11a_runtime_dw_pw_structure.ps1
```

Result:

```text
M11A_STRUCTURE_PASS unique_dw16=1 unique_pw64=1 pw_mac_lanes=64 shared_3line=1 pw_row_bram=1 old_consumer_refs=0
```

The audit proves the intended topology and disjointness only; it is not a
full-top integration or timing-closure proof.

## Direct C0 stream validation

The final run was made after regenerating the reference package and rebuilding
the Verilator binary:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_m11a_runtime_dw_pw_core_sim.sh'
```

The latest non-zero fixture run ended with
`M11A_RUNTIME_DW_PW_NONZERO_FIXTURE_PASS`. All four cases had
`mismatches=0`, `protocol_errors=0`, `error=0`, and the expected output/MAC
ledgers:

| Case | Cycles | Config words | Output words | DW vectors / MAC | PW tokens / MAC | Input reads | Pad taps | Payload stalls |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| DS1, no backpressure | 33,142 | 308 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 380 | 0 |
| DS1, random backpressure | 36,631 | 308 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 380 | 7,958 |
| DS2, no backpressure | 163,620 | 872 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 95 | 0 |
| DS2, random backpressure | 208,274 | 872 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 48,128 | 95 | 4,014 |

The per-case logs are in [`build/m11a_runtime_dw_pw_core/`](../../build/m11a_runtime_dw_pw_core/).

The DS2 `input_reads=25568` value is consistent with the implemented shared
line-store schedule, not with a frame-buffer read estimate. DS2 has 16 output
rows with stride-2 centers `0,2,...,30`; only the top row loses one halo line.
The single line store is reused by the two sequential 16-channel groups, so
the second group reloads its three source rows for each output column. The
resulting count is:

```text
top row: 64 + 16*64 = 1,088
15 remaining rows: 15*(96 + 16*96) = 24,480
total: 25,568 128-bit reads
```

This is a real traffic count and should be treated as a throughput/traffic
cost of the current single-store candidate, not as an acceptance target.

### Non-zero fixture gate

The independent fixture is generated from the checked-in firmware headers and
contains non-zero DS1/DS2 input and expected sink tensors. The RTL gate covers
both layers with and without randomized memory/output backpressure; every case
passes the sink bytes, address/context metadata, configuration count, DW/PW
ledger counts, and `error=0` checks. The detailed reference and RTL reports are
[`m11a_nonzero_fixture_20260907.md`](m11a_nonzero_fixture_20260907.md) and
[`m11a_nonzero_fixture_rtl_20260907.md`](m11a_nonzero_fixture_rtl_20260907.md).

This remains standalone M1.1-A evidence. It does not prove integration into
`cnn_layer_runner`/`cnn_top`, DSP48E1 mapping, or full-top timing closure.

## XC7Z020 post-route OOC evidence

The authorized Vivado 2025.2 OOC flow completed from
[`vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl`](../../scripts/vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl):

- Part: `xc7z020clg400-1`, Vivado 2025.2, clock constraint 8.000 ns (125 MHz).
- Route status: 39,501 routable nets, all fully routed, 0 routing errors.
- Post-route DRC: 0 errors; 146 warning checks (DSP input/output pipelining,
  one no-routable-load check, and the expected OOC PS7 check).
- Logged route-finalize congestion snapshot: north 80.1802%, south 83.7838%,
  east 76.4706%, west 85.2941%; the west direction had one bounded tile
  hotspot (`INT_R_X13Y42`).
- Utilization: 22,618 LUTs (42.52%), 17,789 FFs (16.72%), 9,200 slices
  (69.17%), 1,478 LUTRAMs, 1 RAMB36 (0.71%), and 32 DSP48E1 (14.55%).
- Hierarchical highlights: `cfg_store` 2,489 LUT / 9,236 FF / 1 RAMB36;
  `dw16` 7,061 LUT / 1,211 FF / 16 DSP; `packer` 344 LUT / 620 FF;
  `pw64` 12,718 LUT / 6,719 FF / 16 DSP.
- Post-route checkpoint query: `DSP_COUNT=32`, with `dw16=16`, `pw64=16`,
  and `other=0`; `PW_MAC_MODULE_COUNT=64`, `PW_MAC_DSP_DESCENDANTS=0`,
  `PW_MAC_CARRY4=1792`, and `PW_MAC_LUT=10752`.

Timing is not closed and must not be reported as a pass:

- Setup WNS: `-29.285 ns`.
- Setup TNS: `-127023.680 ns`, 29,470 failing endpoints out of 42,530.
- Hold worst slack: `+0.087 ns` (hold is met in this OOC run).
- Worst max-delay path: `dw16/rq_group_reg[0]_rep__5/C` to
  `dw16/dw_data_r_reg[5]/D`, 37.232 ns data-path delay and 75 logic levels
  (CARRY4=56, DSP48E1=2).
- The timing report also records the OOC `HD.CLK_SRC`/partial-port limitations;
  this is not full-top timing closure.

The full evidence set is under
[`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/`](../../build/reports/m11a_runtime_dw_pw_core_ooc_8ns/), including the post-route DCP,
utilization, timing max/min/summary, route status, high-fanout, DRC, and source
manifest reports.

## Versioning / handoff

The `m11a_` RTL, direct testbench/scripts, reproducible fixture generator, and
the reports in this section are maintained as one scoped checkpoint. Generated
Vivado/Verilator outputs and waveform databases remain outside version control;
unrelated dirty paths on the branch are preserved. This checkpoint must not be
presented as production integration, DSP closure, or full-top timing closure.
