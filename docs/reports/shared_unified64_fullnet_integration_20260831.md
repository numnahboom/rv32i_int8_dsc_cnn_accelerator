# Shared unified64 Stem/DS full-network integration (2026-08-31)

This slice validates the compile-time `USE_SHARED_UNIFIED64=1` path: one
64-product MAC island and one four-lane requant island are selected at runtime
for the mutually exclusive Stem and DS layers.  It is functional/resource
evidence only; no shared-array full-top post-route result is claimed here.

## Reproduction

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_cnn_fullnet_shared_unified64_verilator.sh"
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_cnn_top_shared_unified64_synth_probe_20260831.tcl
```

## Verilator fullnet

```text
PERF tb_cnn_top_fullnet_sram_datapath case=0 hw_cycles=713086 checks=10 errors=0 status=0ae17e82 mem_reads=77630 mem_writes=10
SHARED_METRIC stem_tok=6912 stem_mac=442368 stem_commit=256 ds_tok=65536 ds_mac=4194304 ds_commit=1344 total_tok=72448 total_commit=1600
PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10
```

The hardware and expected logits both have SHA256
`9AE481448D028A5774406C6B73FF3CCCDB820DA8F4A2EB0ACDBF79AA76251260`.
The cycle ledger remains exact at every existing layer boundary; the Stem
layer is 58,718 cycles and the complete run is 713,086 cycles.  The mode
counters account for all 442,368 Stem MACs and 4,194,304 PW MACs; DW and FC
remain in their existing front ends.

## Timeout diagnosis and fix

The initial shared run reached the ten-million-cycle watchdog with status
`0x98967f01`: runner state `ST_TILED_ENGINE_WAIT` (16), layer 0, Stem idle,
and zero shared tokens.  The descriptor retains the historical tiled flag,
but `tiled_spatial_mode` was taken directly from that flag even when the
unified Stem was selected.  The runner therefore waited for the never-started
tiled Stem engine.  The minimal fix masks the tiled FSM for unified Stem:

```verilog
assign tiled_spatial_mode = op_is_tiled_reg && !unified_stem_mode;
```

The testbench's expected scalar-read count was also made aware of the shared
Stem (`3552` reads rather than the legacy `4812`).

## Shared synthesis probe

`build/reports/vivado_cnn_top_shared_unified64_synth_probe_20260831/` completed
with zero synthesis errors at `xc7z020clg400-1`, 8 ns constraint, one Vivado
thread:

| resource | used | device utilization |
|---|---:|---:|
| Slice LUT | 29,364 | 55.20% |
| FF | 37,868 | 35.59% |
| BRAM36 | 50 | 35.71% |
| DSP48E1 | 123 | 55.91% |

The shared compute hierarchy uses 80 DSPs (64 MAC + 16 requant), while the
remaining 43 DSPs are DW, FC, and runner logic.  This is synthesis-only and
does not establish full-top routing/timing/power closure.
