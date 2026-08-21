# Vivado Synthesis Summary

- Date: 2026-08-18
- Tool: Vivado 2021.2 at `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Part: `xck26-sfvc784-2LV-c`
- Mode: out-of-context synthesis, `-flatten_hierarchy none`
- Top: `cnn_top`
- Result: PASS, 0 errors and 0 critical warnings

## Full-Top Result

Numbers below are from Vivado `report_utilization`, not static estimates.

| Metric | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 30451 | 117120 | 26.00% |
| LUT as logic | 28887 | 117120 | 24.66% |
| LUT as memory | 1564 | 57600 | 2.72% |
| CLB registers | 18558 | 234240 | 7.92% |
| Block RAM tiles | 46 | 144 | 31.94% |
| DSP blocks | 65 | 1248 | 5.21% |

Relative to the 2026-07-17 pre-lookahead/LUTRAM-output-buffer snapshot (45830
CLB LUT), this exact tree uses 15379 fewer LUTs (33.56%).  The four extra BRAM
tiles are the deliberately synchronous XPM output buffer; it eliminates the
old 3398-LUT asynchronous output buffer.  The 446272-LUT DS-only integration
result remains a much older intermediate design, not this RTL.

## Main Hierarchy

| Instance | LUT | FF | RAMB36 | DSP | Interpretation |
| --- | ---: | ---: | ---: | ---: | --- |
| `u_layer_runner` total | 29119 | 17328 | 30 | 65 | Includes all compute engines and BRAM output buffer |
| runner self | 2344 | 1151 | 0 | 31 | Control, loaders, address generation |
| `u_ds_block_engine` | 24307 | 15653 | 26 | 14 | Active streaming/BRAM DSBlock |
| `u_stem_engine` | 1452 | 134 | 0 | 10 | Three reused int8 MACs plus requant |
| `u_gap_unit` | 115 | 2 | 0 | 0 | Accumulates while input is loaded |
| `u_fc_unit` | 826 | 377 | 0 | 10 | Sequential weight-load accumulation |
| `u_out_buffer` | 6 | 0 | 4 | 0 | 16 KB synchronous XPM BRAM |
| `u_feature_sram` | 67 | 23 | 16 | 0 | Two 32 KB XPM BRAM banks |

The intended memory mapping is visible in the hierarchy:

- DS input tile: 16 RAMB36
- PW weights: 8 RAMB36
- DW output tile: 2 RAMB36
- Two feature SRAM banks: 16 RAMB36

## Timing Caveat

The installed K26 part reports:

```text
ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device
```

Therefore this result establishes synthesis resource feasibility only. It does
not establish WNS, Fmax, congestion, power, or post-route closure.

## Reproduction

```powershell
& D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat `
  -mode batch `
  -source scripts\vivado_cnn_top_synth.tcl `
  -tclargs cnn_top xck26-sfvc784-2LV-c
```

Primary artifacts:

- `docs/reports/synthesis_vivado_initial.md`
- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `docs/reports/synthesis_vivado_ds_block_tile_engine_new.md`

## Next Synthesis Work

1. Run implementation with timing-capable device support and real XDC.
2. Use routed timing and real layer-cycle profiles to tune DW/PW LUT-vs-DSP
   mapping, requant pipelining, and Stem parallelism.
