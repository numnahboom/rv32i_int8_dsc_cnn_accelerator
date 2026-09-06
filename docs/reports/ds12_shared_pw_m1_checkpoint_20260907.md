# DS12 shared-PW M1 checkpoint — 2026-09-07

Status: `BLOCKED` for promotion. RTL and synthesis evidence pass their local gates; routed OOC evidence is still in progress and currently reports congestion.

## Scope

The checkpoint contains `ds12_shared_pw_two_layer_top` and its single shared pointwise service. The service owns one 64-lane MAC generate, one active pointwise/request storage path, and two result-lifecycle banks. DS1 uses the rolling-row BRAM endpoint; the legacy DS1/DS2 pointwise consumers are not instantiated by this top.

The version record is intentionally scoped to the M1 shared-PW files, their testbench/filelist, run/audit scripts, Vivado scripts, and this report. Existing unrelated dirty paths are not included.

## Validation evidence

| Gate | Result | Evidence |
| --- | --- | --- |
| Structure audit | PASS | `SHARED_STRUCTURE_PASS`; one service instance, one 64-lane MAC generate site, zero forbidden old PW consumers |
| RTL, no backpressure | PASS | `SHARED_PW_PASS`, 22,238 cycles, cfg 1,180, outputs 8,192/4,096, DW 147,456/73,728, PW 524,288/524,288, mismatches 0, errors 0 |
| RTL, independent random backpressure | PASS | `SHARED_PW_PASS`, 31,865 cycles, same exact counts, mismatches 0, errors 0 |
| Vivado synth-only | PASS as a synthesis run | Vivado 2025.2, `xc7z020clg400-1`, 8.000 ns clock, exit 0; source manifest is in `build/reports/ds12_shared_pw_two_layer_top_synth_20260906/source_manifest.txt` |
| Synth timing estimate | FAIL for promotion | WNS `-27.179 ns`, TNS `-77360.078 ns`, 19,599 failing endpoints; this is not routed timing |
| Vivado routed OOC | PENDING/BLOCKED | The run is in route Global Iteration 1; the latest log reports congestion and overlaps reduced from 89,511 to 39,001 to 17,108 to 8,714 |

The latest synth log no longer contains the retired `feature_reg` warning. It reports the smaller rolling-row `row_mem_reg` (12,288 registers) and `result_accum_reg` (32,768 registers), which remain implementation risks to review.

## Promotion rule

Do not call this top timing-closed or promote it until the routed OOC report exists and meets the project gate: WNS at least `+0.5 ns` and WHS at least `0 ns`, with route status complete. A routed failure should be recorded with its worst endpoints rather than hidden behind the synthesis estimate.

## Reproduction

From WSL:

```bash
cd /mnt/d/Stuff/Project
bash scripts/run_ds12_shared_pw_two_layer_top.sh
```

The run script translates the checkout path for Windows Python when NumPy is available only in the Windows environment. Vivado gates are launched with the dated TCL scripts under `scripts/`.
