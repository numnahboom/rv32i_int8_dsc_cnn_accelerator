# Unified64 Stem runner audit — 2026-08-31

## Source identity

The audit was run in `D:/Stuff/Project` at Git `3dcd01293ab97786e43ace3f2c38bc86b32a6209`.
The tracked-diff SHA-1 recorded by the implementation manifest is
`a3a1b7e9b19495eb01ef4d5643df8be0c7192cd2`.
Relevant file SHA-256 values are:

| file | SHA-256 |
|---|---|
| `rtl/cnn/cnn_layer_runner.v` | `1CEBAFDAFF2D340B512060FC8916CDE004084FCCE32AF419870B5ABC59A9E1B0` |
| `rtl/cnn/cnn_top.v` | `9BD99D1059B16C0AAE5A47733C063B6740AF0D075C5A93B6CCE9E31B87B1BE56` |
| `rtl/cnn/stem_unified64_streaming.v` | `5908469D2E1347A6B479E9FBF7E49CCDD2DF508DCEFA9C91D421A9320671CA9C` |
| `sim/tb_cnn_top_fullnet_sram_datapath.v` | `307E6AB941F858156285B363F049BEF4B53BF3C2FF60F80953E6DBFB23C0CC14` |
| `sim/tb_cnn_layer_runner_unified64_ds.v` | `55405C921F48A5E84282CB68E6C6FD982471BF3F2B3E743C8AF3115D0ED74E15` |
| `sim/filelist_cnn_current.f` | `668D7EAC638E2BD94FBD89D5D5FEA5C62C9B5E8D4B641E8853ECFF45A0B30CC6` |

## Directed and fullnet verification

Directed runner command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_cnn_layer_runner_unified64_ds_sim.sh'
```

Result: `PASS tb_cnn_layer_runner_unified64_ds cases=2`; case 0 was 5,651
cycles / 984 reads / 512 writes, and case 1 was 5,166 cycles / 1,792 reads /
256 writes, with `error=0`.

The fullnet command for the required Stem-only flag is:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_cnn_fullnet_unified64_stem_verilator.sh'
```

The four compile-time combinations all passed 10/10 exact logits (`errors=0`):

| `USE_UNIFIED64_DS` | `USE_UNIFIED64_STEM` | cycles | external reads | writes |
|---:|---:|---:|---:|---:|
| 0 | 0 | 873,289 | 78,890 | 10 |
| 1 | 0 | 931,402 | 78,890 | 10 |
| 0 | 1 | 654,205 | 77,630 | 10 |
| 1 | 1 | 712,318 | 77,630 | 10 |

The Stem-only run has `MAC=5,136,896`, `mem_reads=77,630`,
`mem_writes=10`, `desc_reads=288`, and `status=09fb7d82`. Its per-layer ledger
is:

| layer | cycles | mem reads | SRAM scalar reads | SRAM word reads | SRAM writes |
|---:|---:|---:|---:|---:|---:|
| 0 Stem | 57,950 | 3,552 | 0 | 0 | 16,384 |
| 1 | 98,701 | 800 | 13,392 | 2,428 | 8,192 |
| 2 | 98,949 | 2,624 | 25,600 | 2,312 | 4,096 |
| 3 | 111,229 | 5,056 | 20,160 | 144 | 4,096 |
| 4 | 74,350 | 9,344 | 16,384 | 0 | 2,048 |
| 5 | 93,518 | 18,304 | 8,192 | 0 | 2,048 |
| 6 | 104,110 | 35,072 | 8,192 | 0 | 1,024 |
| 7 | 8,720 | 0 | 4,096 | 0 | 256 |
| 8 FC | 5,795 | 2,590 | 256 | 0 | 0 |

For the DS+Stem combination, the same layers are 57,950 / 101,933 /
106,385 / 126,857 / 82,161 / 109,521 / 112,113 / 8,720 / 5,795 cycles,
totalling 712,318 cycles. The ready-stall proof was also previously rerun for
Stem-only: exact logits, `errors=0`, 680,533 cycles.

## OOC timing and resource evidence

The current static row-bank Stem OOC is:

`build/reports/vivado_stem_static_window_banks_ooc_20260831/`

This is the `stem_static_window_banks` top from
`scripts/vivado_stem_static_window_banks_ooc_20260831.tcl`, not the older
`stem_unified64_streaming` top. Fresh XC7Z020 8 ns post-route results:

| metric | result |
|---|---:|
| WNS / TNS | +0.529 ns / 0 |
| setup failing endpoints | 0 / 24,516 |
| WHS / THS | +0.098 ns / 0 |
| hold failing endpoints | 0 / 24,516 |
| LUT | 5,925 (11.14%) |
| FF | 10,041 (9.44%) |
| DSP | 80 (36.36%) |
| BRAM | 0 |
| total on-chip power | 0.311 W |
| routed nets / route errors | 15,496 / 0 |

The older report
`build/reports/vivado_stem_unified64_streaming_ooc_20260831/` is a different
top and remains a negative result (`WNS=-10.537 ns`, `WHS=+0.123 ns`). It must
not be substituted for the static row-bank result or combined with it.

## Full-top status

There is no valid unified-Stem full-top post-route result. The original output
directory only contains a `RUNNING` manifest and no timing, utilization, power,
or route report. A fresh attempt was run with:

```text
$env:VIVADO_IMPL_OUT_DIR_OVERRIDE='D:\Stuff\Project\build\reports\vivado_cnn_top_unified64_stem_8ns_fresh_20260831'
$env:VIVADO_IMPL_RUN_ID_OVERRIDE='20260831_unified64_stem_8ns_fresh_mt2'
./scripts/run_cnn_top_unified64_stem_8ns_impl.ps1
```

It used Vivado 2025.2, `xc7z020clg400-1`, Explore, 8 ns, and
`VIVADO_IMPL_MAX_THREADS=2`. It failed during synthesis with Windows exit
`-1073740940`; the log also reports `ERROR: [Common 17-1257] Failed to create
directory 'C'.` The fresh manifest is therefore still `status: RUNNING` because
the Tcl process terminated before its failure finalizer. No post-route metrics
are claimable. The two orphaned synthesis worker processes from this failed
attempt were terminated after confirming that no top-level Vivado process or
implementation artifacts remained.

## Decision

Functionality and runner integration are reproducible, and the positive OOC
number is specifically the static row-bank Stem result (+0.529/+0.098 ns).
The full-top timing/resource/power interaction is still unproven; the next
full-top attempt should use a repaired synthesis path or a physically reduced
Stem integration, and must emit complete post-route timing, route, utilization,
and power reports before being treated as evidence.
