# M1.1-A PW64 BRAM-to-DSP operand pipeline

Date: 2026-09-07
Status: `PW_OPERAND_PIPELINE_PASS` for the standalone PW BRAM-to-DSP setup
slice. Functional, structural, and XC7Z020 OOC post-route gates pass. This is
standalone M1.1-A evidence only; it is not `cnn_layer_runner`/`cnn_top` or
full-top evidence.

## Scope and baseline

The owned RTL change is limited to
[`rtl/cnn/m11a_pw64_shared_core.v`](../../rtl/cnn/m11a_pw64_shared_core.v),
with cadence monitors in
[`sim/tb_m11a_runtime_dw_pw_core.v`](../../sim/tb_m11a_runtime_dw_pw_core.v),
summary formatting in
[`scripts/run_m11a_runtime_dw_pw_core_sim.sh`](../../scripts/run_m11a_runtime_dw_pw_core_sim.sh),
and the read-only post-route query in
[`scripts/query_m11a_pw_operand_20260907.tcl`](../../scripts/query_m11a_pw_operand_20260907.tcl).

Previously, `process_fire` enabled the 64 PW MAC cells with the pending
activation metadata and the synchronous BRAM output `pw_row_rd_data` directly.
The repair adds an explicit request-to-operand boundary: the BRAM response,
activation, weight row, bank ID, and all token-boundary metadata are captured
in `operand_*` registers, and the DSP MAC enable is `operand_valid`. A row
response and the next token request may overlap on one edge. The first token of
a tile still requires a free result bank; continuation tokens use the active
bank. Final-K metadata is copied into independent `dsp_drain_*` registers so a
same-edge successor cannot overwrite the result being committed. The external
interface, arithmetic width, bank ownership, and output metadata contract are
unchanged.

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

The four latest non-zero fixture logs under
`build/m11a_runtime_dw_pw_core/` all report
`mismatches=0 protocol_errors=0 error=0`. The testbench checks output bytes,
address/context/owner/epoch/last metadata, config count, DW/PW MAC and token
ledgers, input reads, and the new token cadence counters.

| Case | Cycles | Outputs | DW vectors / MAC | PW tokens / MAC | PW rows / overlap | PW max gap / run | Input reads | Stalls |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| DS1, no backpressure | 93,261 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 8,192 / 7,808 | 390 / 32 | 3,008 | 0 |
| DS1, randomized backpressure | 98,683 | 8,192 | 1,024 / 147,456 | 8,192 / 524,288 | 8,192 / 7,808 | 456 / 32 | 3,008 | 8,156 |
| DS2, no backpressure | 197,693 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 8,192 / 7,968 | 5,163 / 64 | 48,128 | 0 |
| DS2, randomized backpressure | 245,704 | 4,096 | 512 / 73,728 | 8,192 / 524,288 | 8,192 / 7,968 | 6,702 / 64 | 48,128 | 4,102 |

The `pw_rows / overlap` column records row captures and same-cycle request
overlap. The maximum continuous PW token runs are 32 for DS1 and 64 for DS2;
the randomized cases preserve exact ledgers under memory/output backpressure.

## XC7Z020 post-route OOC

The standalone source set was implemented with Vivado 2025.2 for
`xc7z020clg400-1` and an 8.000 ns clock (125 MHz), using
`scripts/vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl`:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_m11a_runtime_dw_pw_core_ooc_8ns.tcl
```

The source manifest is
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/source_manifest.txt`. The
post-route checkpoint and reports are in
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/`.

Post-route evidence:

- Setup WNS `+0.015 ns`, TNS `0`, and `0 / 52,056` failing setup endpoints.
- Hold WHS `+0.070 ns`, THS `0`, and no hold violation.
- Route status: `34,057 / 34,057` routable nets fully routed; routing errors
  `0`.
- Utilization: 13,907 LUT (26.14%), 19,890 FF (18.69%), 1 RAMB36 (0.71%),
  and 112 DSP48E1 (50.91%).
- The final batch log reports `0 Errors encountered`; synthesis, placement,
  physical optimization, and routing completed successfully. DRC has no
  error-severity violation; the remaining warnings/advisories are the
  expected DSP input/MREG pipelining checks, one no-routable-load check, the
  OOC PS7 check, and DSP input-configuration advisories.

The post-route structure query reports:

```text
DSP_COUNT=112
DSP_PARTITION dw_mac=16 pw_mac=64 dw_rq4=16 pw_rq4=16 total=112
PW_MAC_MODULE_COUNT=64 PW_MAC_DSP_DESCENDANTS=64 PW_MAC_CARRY4=0 PW_MAC_LUT=64
```

The targeted timing query is in
`build/reports/m11a_runtime_dw_pw_core_ooc_8ns/pw_bram_to_operand_weight_timing.rpt`.
It finds the registered PW boundary from
`cfg_store/pw_row_mem_reg/CLKARDCLK` to
`pw64/operand_weight_reg[6]/D` with slack `+3.687 ns` and data delay
`4.261 ns`; the activation query finds no direct BRAM-to-activation path
because activation is already held in the request metadata. The worst
registered operand-to-PW-DSP-B path is
`pw64/operand_weight_reg[23]/C` to
`pw64/GEN_PW64_MAC[10].u_mac/u_dsp48e1/u_dsp48e1_int8_accum/B[11]`, with
slack `+0.333 ns` and data delay `3.874 ns`. The former BRAM-to-DSP setup
exposure is therefore cut by the operand register; the current global worst
path is an unrelated cfg-preparation cone at `+0.015 ns`.

## Evidence boundary

This repair proves the standalone PW64 request/operand/DSP alignment,
non-zero functional ledgers, token cadence under backpressure, structural DSP
partition, and standalone XC7Z020 125 MHz OOC post-route timing. It does not
prove production-top integration, full-network cycles, power, energy
efficiency, or full-top post-route closure. No Git commit was made, and
unrelated worktree changes were preserved.
