# M1.1-A DS2 group-banked DW16 line cache

Date: 2026-09-07
Status: `DS2_GROUP_BANKED_PASS` for the standalone M1.1-A DW16 slice.
The DS2 input-reuse, exactness, cadence, structural, and XC7Z020 OOC gates
pass. This is standalone evidence only; it is not `cnn_layer_runner`,
`cnn_top`, or full-top evidence.

## Scope and baseline

The owned implementation is
[`rtl/cnn/m11a_dw16_shared_line.v`](../../rtl/cnn/m11a_dw16_shared_line.v).
The direct fixture ledger check is in
[`sim/tb_m11a_runtime_dw_pw_core.v`](../../sim/tb_m11a_runtime_dw_pw_core.v),
and the static structure check is in
[`scripts/audit_m11a_runtime_dw_pw_structure.ps1`](../../scripts/audit_m11a_runtime_dw_pw_structure.ps1).
The existing standalone OOC Tcl source set was reused without changing the
production runner/top or the already-accepted PW operand pipeline.

Before this slice, one three-line store was reused for both DS2 input groups.
The control therefore loaded all three spatial rows for group 0 and then
reloaded the same rows for group 1 for every output column. The DS2 no-
backpressure baseline was 48,128 input reads and 197,693 cycles.

The repair gives group 0 and group 1 independent logical banks:

```text
line0_g0_mem, line1_g0_mem, line2_g0_mem
line0_g1_mem, line1_g1_mem, line2_g1_mem
```

At each output-row start, the loader walks all valid spatial rows for bank 0,
then bank 1. The compute loop then advances output columns using the resident
bank selected by `group_r`; only the transition to the next output row resets
`load_group`/`load_slot` and starts another load. DS1 keeps `group_count_r=1`
and only uses bank 0. The memory ABI remains 128-bit; DS2 group 1 still starts
at the fixed +16-byte half-pixel offset and subsequent pixels advance by 32
bytes. No frame buffer, tap, MAC, precision, or output protocol was removed.

## Functional and structural validation

Commands:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/audit_m11a_runtime_dw_pw_structure.ps1
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_m11a_runtime_dw_pw_core_sim.sh'
```

The structural audit passed:

```text
M11A_STRUCTURE_PASS unique_dw16=1 unique_pw64=1 pw_mac_lanes=64 shared_3line=1 dw_group_banks=6 pw_row_bram=1 explicit_dsp_accum=1 rq4_instances=2 old_consumer_refs=0
```

The testbench now derives and asserts the expected line-load count. For both
fixed 32x32 fixtures the expected count is 3,008 beats: DS1 has one group over
32 output rows, while DS2 has two groups over 16 output rows. All four fresh
logs report `input_reads=3008 expected_input_reads=3008`,
`mismatches=0 protocol_errors=0 error=0`, and exact output address, byte,
context, owner, epoch, last, DW/PW MAC, token, and output ledgers.

| Case | Cycles | Outputs | DW vectors / MAC | PW tokens / MAC | Input reads | PW max gap / run | Stalls |
|---|---:|---:|---:|---:|---:|---:|---:|
| DS1, no backpressure | 93,261 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 390 / 32 | 0 |
| DS1, randomized backpressure | 98,683 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 3,008 | 456 / 32 | 8,156 |
| DS2, no backpressure | 61,088 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 3,008 | 798 / 64 | 0 |
| DS2, randomized backpressure | 64,261 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 3,008 | 798 / 64 | 4,046 |

Relative to the DS2 no-backpressure baseline, the banked loader removes the
45,120 repeated input reads and saves 136,605 cycles (197,693 -> 61,088).
The randomized case saves 181,443 cycles (245,704 -> 64,261). DS1 remains
cycle- and read-count-identical to the baseline.

## XC7Z020 post-route OOC

The fresh standalone implementation used Vivado 2025.2,
`xc7z020clg400-1`, and an 8.000 ns clock (125 MHz):

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl
```

The source manifest is
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/source_manifest.txt`; the
post-route DCP and reports are in
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/`.

Post-route evidence:

- Setup WNS `+0.075 ns`, TNS `0`, and `0 / 52,056` failing setup endpoints.
- Hold WHS `+0.070 ns`, THS `0`, and no hold violation.
- Route status: `34,823 / 34,823` routable nets fully routed; routing errors
  `0`.
- Utilization: 14,510 LUT (27.27%), 19,893 FF (18.70%), 1 RAMB36 (0.71%),
  and 112 DSP48E1 (50.91%). Every reported resource remains below 70%.
- Post-route DSP structure remains `dw_mac=16`, `pw_mac=64`,
  `dw_rq4=16`, `pw_rq4=16`, total `112`; PW remains 64 MAC modules with 64
  DSP descendants and no PW MAC CARRY4 implementation.

The worst setup path is no longer in the DW line-cache/tap path. It is the
PW requantization control/data cone
`pw64/pwrq4/valid_r_reg/C` -> `pw64/pwrq4/x_r_reg[3][32]/D`, with data delay
`7.903 ns` and slack `+0.075 ns`. The routed high-fanout report shows the
banked DW load cursor and tap decode as positive-slack control/data nets; no
new global timing exception, multicycle path, or clock relaxation was used.

The batch log contains one transient Vivado Common 17-1257 message while
creating a synthesis bookkeeping directory named `C` (the Windows invocation
environment's home-path handling). Synthesis, optimization, placement,
physical optimization, routing, DRC, and checkpoint generation completed;
the final design reports show zero timing/route/DRC errors. This environment
message is retained as an evidence limitation, not treated as a design error.

## Evidence boundary

This slice proves DS2 group-banked spatial-row reuse, the 3,008-beat input
ledger, exact non-zero arithmetic and metadata under backpressure, unchanged
DSP partition, and standalone XC7Z020 125 MHz OOC post-route timing. It does
not prove production-top integration, full-network cycles, power, energy
efficiency, or full-top closure. No Git commit was made; unrelated dirty paths
were preserved.
