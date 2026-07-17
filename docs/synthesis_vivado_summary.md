# Vivado Synthesis Summary

- Date: 2026-07-17
- Tool: Vivado 2021.2 at `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Part: `xck26-sfvc784-2LV-c`
- Mode: out-of-context synthesis, `-flatten_hierarchy none`
- Top: `cnn_top`
- Result: PASS, 0 errors and 0 critical warnings

## Full-Top Result

Numbers below are from Vivado `report_utilization`, not static estimates.

| Metric | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| CLB LUT | 45830 | 117120 | 39.13% |
| LUT as logic | 41946 | 117120 | 35.81% |
| LUT as memory | 3884 | 57600 | 6.74% |
| CLB registers | 18387 | 234240 | 7.85% |
| RAMB36 tiles | 42 | 144 | 29.17% |
| DSP blocks | 60 | 1248 | 4.81% |

This is a major reduction from the intermediate DS-only integration result of
446272 CLB LUT. That intermediate design still contained runner-owned packed
Stem/GAP/FC payloads and is not the current RTL.

## Main Hierarchy

| Instance | LUT | FF | RAMB36 | DSP | Interpretation |
| --- | ---: | ---: | ---: | ---: | --- |
| `u_layer_runner` total | 44503 | 17158 | 26 | 60 | Includes all compute engines and output buffer |
| runner self | 14812 | 1011 | 0 | 26 | Control, loaders, address generation |
| `u_ds_block_engine` | 24283 | 15630 | 26 | 14 | Active streaming/BRAM DSBlock |
| `u_stem_engine` | 1000 | 127 | 0 | 10 | One reused int8 MAC plus requant |
| `u_gap_unit` | 115 | 2 | 0 | 0 | Accumulates while input is loaded |
| `u_fc_unit` | 826 | 377 | 0 | 10 | Sequential weight-load accumulation |
| `u_out_buffer` | 3398 | 0 | 0 | 0 | 16 KB asynchronous LUTRAM |
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

- `docs/synthesis_vivado_initial.md`
- `build/reports/vivado_cnn_top/utilization.txt`
- `build/reports/vivado_cnn_top/utilization_hierarchical.txt`
- `docs/synthesis_vivado_ds_block_tile_engine_new.md`

## Next Synthesis Work

1. Run implementation with timing-capable device support and real XDC.
2. Convert the 16 KB asynchronous `cnn_out_buffer` to synchronous BRAM with an
   explicit read-prefetch state.
3. Use routed timing and real layer-cycle profiles to tune DW/PW LUT-vs-DSP
   mapping, requant pipelining, and Stem parallelism.
