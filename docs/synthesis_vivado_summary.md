# Vivado Synthesis Summary

- Date: 2026-06-14
- Tool: Vivado 2021.2 at `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`
- Installed devices found: `xck26-sfvc784-2LV-c`, `xck26-sfvc784-2LVI-i`
- Part used for these runs: `xck26-sfvc784-2LV-c`
- Mode: out-of-context synthesis

## Full Top Attempt

`cnn_top` synthesis was attempted with the K26 part. It reached `dw_tile_buffer`, then Vivado warned that the 3D RAM pattern is unsupported and will likely become registers. The run continued for more than 30 minutes without further progress and was stopped.

Key warning:

```text
WARNING: [Synth 8-5856] 3D RAM bank_mem_reg for this pattern/configuration is not supported. This will most likely be implemented in registers
```

This confirms the current top-level synthesis blocker: buffer/SRAM RTL must be made BRAM-friendly before full-top resource numbers are meaningful.

## Successful Representative Modules

Numbers below are from `report_utilization` Site Type tables after synthesis.

| Module | CLB LUTs | CLB Registers | BRAM Tiles | DSPs | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| `requant_activation_unit` | 494 | 294 | 0 | 10 | Q31 multiply maps to DSP48E2 cascade |
| `pw_systolic_array_8x8` | 5957 | 4098 | 0 | 0 | 8-bit PE multipliers mapped to LUT/CARRY |
| `dw_mac_lanes` | 9759 | 3367 | 0 | 0 | 16 DW lanes mapped to LUT/CARRY |
| `feature_sram_bank` | 6791 | 9 | 0 | 0 | 5120 LUTs are distributed RAM, not BRAM |

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
- `build/reports/vivado_requant_activation_unit/utilization.txt`
- `build/reports/vivado_pw_systolic_array_8x8/utilization.txt`
- `build/reports/vivado_dw_mac_lanes/utilization.txt`
- `build/reports/vivado_feature_sram_bank/utilization.txt`

## Next Synthesis Fixes

1. Rewrite `dw_tile_buffer` into explicit banks instead of a 3D RAM array.
2. Decide whether `feature_sram_bank` should be BRAM or LUTRAM, then force or wrap accordingly.
3. Consider `(* use_dsp = "yes" *)` only if PW/DW should intentionally consume DSPs; current Vivado mapping keeps int8 MACs in LUTs.
4. Re-run `cnn_top` after memory refactoring.
