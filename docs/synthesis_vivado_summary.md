# Vivado Synthesis Summary

- Date: 2026-06-16
- Tool: Vivado 2021.2 at `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Installed devices found: `xck26-sfvc784-2LV-c`, `xck26-sfvc784-2LVI-i`
- Part used for these runs: `xck26-sfvc784-2LV-c`
- Mode: out-of-context synthesis

## Full Top Attempt

`cnn_top` synthesis was attempted with the K26 part after the memory-pattern fixes below. Vivado now gets past the previous `dw_tile_buffer` 3D RAM failure and through front-end synthesis, but the complete top did not finish within the 1 hour local run limit.

Current limiting warnings are large-pin-count cones from simulation-friendly packed payload buffers in `cnn_layer_runner` and the synthesis-only staging registers used to make the DW/DSBlock engines acceptable to Vivado:

```text
WARNING: [Synth 8-5402] Detected an instance with large pin count ...
```

Conclusion: the hard RTL inference blockers have moved from "unsupported memory pattern" to "full top is too large for a quick local OOC run". A full-top result should wait until the packed payload buffers in `cnn_layer_runner` are replaced by real SRAM/loader interfaces or until hierarchical synthesis checkpoints are used.

## Successful Representative Modules

Numbers below are from `report_utilization` Site Type tables after synthesis.

| Module | CLB LUTs | CLB Registers | BRAM Tiles | DSPs | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `requant_activation_unit` | 494 | 294 | 0 | 10 | Q31 multiply maps to DSP48E2 cascade |
| `pw_systolic_array_8x8` | 5957 | 4098 | 0 | 0 | 8-bit PE multipliers mapped to LUT/CARRY |
| `dw_mac_lanes` | 9759 | 3367 | 0 | 0 | 16 DW lanes mapped to LUT/CARRY |
| `feature_sram_bank` | 6791 | 9 | 0 | 0 | 5120 LUTs are distributed RAM, not BRAM |
| `dw_tile_buffer` | 46131 | 64 | 0 | 0 | 3D RAM issue resolved; maps mostly to LUT/LUTRAM |
| `dw_tile_fusion_engine` | 170408 | 296388 | 0 | 10 | OOC synthesis passes after input staging |
| `ds_block_tile_engine` | 389253 | 565654 | 0 | 20 | OOC synthesis passes after PW weight staging |

## Timing Caveat

The installed K26 part library reports timing as unavailable:

```text
ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device
```

Therefore these are synthesis utilization results only. They are not timing closure or post-place-and-route results.

## Artifacts

- `docs/synthesis_verification_report.md`
- `docs/synthesis_vivado_initial.md`
- `docs/synthesis_vivado_requant_activation_unit.md`
- `docs/synthesis_vivado_pw_systolic_array_8x8.md`
- `docs/synthesis_vivado_dw_mac_lanes.md`
- `docs/synthesis_vivado_feature_sram_bank.md`
- `docs/synthesis_vivado_dw_tile_buffer.md`
- `docs/synthesis_vivado_dw_tile_fusion_engine.md`
- `docs/synthesis_vivado_ds_block_tile_engine.md`
- `build/reports/vivado_requant_activation_unit/utilization.txt`
- `build/reports/vivado_pw_systolic_array_8x8/utilization.txt`
- `build/reports/vivado_dw_mac_lanes/utilization.txt`
- `build/reports/vivado_feature_sram_bank/utilization.txt`
- `build/reports/vivado_dw_tile_buffer/utilization.txt`
- `build/reports/vivado_dw_tile_fusion_engine/utilization.txt`
- `build/reports/vivado_ds_block_tile_engine/utilization.txt`

## Next Synthesis Fixes

1. Replace `cnn_layer_runner` packed payload vectors (`ds_input_tile`, `pw_weight`, etc.) with SRAM/loader style interfaces.
2. Decide whether `feature_sram_bank` should be BRAM or LUTRAM, then force or wrap accordingly.
3. Keep the current high-cost staging implementation as a synthesis proof only; optimize DW/DSBlock storage later.
4. Re-run `cnn_top` after the layer-runner payload buffers are made memory-oriented or after setting up hierarchical synthesis.
