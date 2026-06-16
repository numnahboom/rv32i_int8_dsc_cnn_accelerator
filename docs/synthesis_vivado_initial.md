# Vivado Initial Synthesis Report

- Date: 2026-06-16
- Tool: Vivado 2021.2
- Top module: `cnn_top`
- Part: `xck26-sfvc784-2LV-c`
- Clock constraint: 10.000 ns
- Status: INCOMPLETE

## Result

`cnn_top` no longer stops at the original `dw_tile_buffer` 3D RAM pattern. Vivado front-end synthesis reaches the complete hierarchy, including `cnn_layer_runner`, `dw_tile_fusion_engine`, and `ds_block_tile_engine`.

The local full-top OOC run did not finish within the 1 hour run limit. The latest log shows large-pin-count warnings from the remaining simulation-oriented packed payload buffers in `cnn_layer_runner` and from the current synthesis-proof staging logic in the DW/DSBlock engines.

## Current Evidence

The following OOC module syntheses pass with Vivado 2021.2:

| Top | Status | LUT primitive cells | FF/latch primitive cells | DSP primitive cells |
| --- | --- | ---: | ---: | ---: |
| `dw_tile_buffer` | PASSED | 50272 | 64 | 0 |
| `dw_tile_fusion_engine` | PASSED | 307455 | 296388 | 10 |
| `ds_block_tile_engine` | PASSED | 645195 | 565654 | 20 |

These numbers are intentionally not optimized. They prove Vivado accepts the RTL after the staging/banking fixes.

## Remaining Full-Top Blocker

Full `cnn_top` still needs a memory/interface pass:

- Replace `cnn_layer_runner` packed vectors such as `ds_input_tile` and `pw_weight` with SRAM/loader interfaces.
- Keep current DW/DSBlock staging only as a temporary synthesis-proof fallback.
- Re-run full top after payload storage is no longer represented as huge packed vectors.

Timing reports still fail on the installed K26 part with:

```text
ERROR: [Common 17-577] Internal error: Cannot run timing on a non-timing device
```
