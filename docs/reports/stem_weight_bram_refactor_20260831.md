# Stem packed-weight BRAM/XPM refactor — 2026-08-31

## Scope

This slice owns only the packed two-bank Stem weight store and its validation.
`runner`, `cnn_top`, and their integration sources were not modified here.
The external configuration ABI remains `cfg_index = cout * 27 + k`; each bank
stores eight output-channel bytes in one 64-bit row and exposes one registered
64-bit read per `k` group.

## Implementation

`rtl/cnn/stem_weight_store_packed64.v` now has matching simulation and
synthesis models:

- Verilator uses two 32-row x 64-bit registered-read arrays and performs the
  previously disabled byte writes.
- Vivado uses two `xpm_memory_sdpram` instances, each with an 8-bit write /
  64-bit read geometry, `READ_LATENCY_B=1`, block-memory primitive, and the
  same packed address mapping.
- The byte address is explicitly widened to eight bits, avoiding the prior
  XPM `addra` width warning.

## Functional evidence

Command (run twice independently):

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_stem_unified64_streaming_sim.sh'
```

Both runs exited 0. Each testbench run contains two complete 32x32x3 Stem
transactions at epochs `3` and `c`, with deterministic source-request bubbles
and output backpressure. Each transaction passed 4,096 output commits,
768 source requests/responses, 6,912 tokens, 442,368 MACs, and 6,912 compute
cycles. The final line was:

```text
PASS tb_stem_unified64_streaming runs=2 outputs=8192 commits=8192
```

Logs: `build/reports/stem_weight_sim_run1_20260831.log` and
`build/reports/stem_weight_sim_run2_20260831.log`.

## XPM child synthesis probe

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -notrace -source scripts/vivado_stem_weight_store_xpm_probe_20260831.tcl
```

Vivado 2025.2 / XC7Z020 / `general.maxThreads=1` completed synthesis with
zero errors. The generated netlist has 2 RAMB36E1, 16 CARRY4, and 0 black
boxes; peak Vivado memory was 1,824.801 MB. Reports are under
`build/reports/vivado_stem_weight_store_xpm_probe_20260831/`.

## 8 ns OOC implementation

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -notrace -source scripts/vivado_stem_weight_bram_refactor_ooc_20260831.tcl
```

The routed OOC result completed with zero route errors:

| Metric | Result |
| --- | ---: |
| WNS / TNS | +0.362 ns / 0 |
| WHS / THS | +0.096 ns / 0 |
| Setup / hold failing endpoints | 0 / 0 |
| LUT | 3,587 (6.74%) |
| FF | 6,736 (6.33%) |
| DSP | 80 (36.36%) |
| BRAM36 | 2 (1.43%) |
| Total on-chip power | 0.303 W |
| Routed nets / routing errors | 11,261 / 0 |
| Peak Vivado memory | 4,921.293 MB |

Reports are under
`build/reports/vivado_stem_weight_bram_refactor_ooc_20260831/`.
An `AggressiveExplore` rerun reproduced the same +0.362 ns WNS; this slice
does not claim the stronger +0.5 ns candidate margin.

## Full-top synthesis-only probe

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -notrace -source scripts/vivado_cnn_top_unified64_stem_synth_probe_mt1_20260831.tcl
```

The full `cnn_top` with `USE_UNIFIED64_STEM=1` completed synthesis at
`general.maxThreads=1`, with zero synthesis errors. Peak memory was
5,104.434 MB; elapsed synthesis was about 3m40s. Synthesis site counts were:

| Metric | Result |
| --- | ---: |
| Slice LUTs | 28,245 (53.09%) |
| Slice Registers | 36,820 (34.61%) |
| BRAM36 | 50 (35.71%) |
| DSP48E1 | 203 (92.27%) |

This is synthesis-only evidence and is not a post-route timing result. Reports
and checkpoint are under
`build/reports/vivado_cnn_top_unified64_stem_synth_probe_mt1_20260831/`.
