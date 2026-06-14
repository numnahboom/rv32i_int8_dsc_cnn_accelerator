# Vivado cnn_top Synthesis Attempt

- Date: 2026-06-14
- Tool: Vivado 2021.2
- Top module: `cnn_top`
- Installed part used: `xck26-sfvc784-2LV-c`
- Status: stopped after a long-running synthesis attempt

## Result

Vivado successfully started `cnn_top` synthesis and progressed through:

- `cnn_top`
- `cnn_top_ctrl`
- `descriptor_fetch`
- `cnn_layer_runner`
- `conv3x3_stem_engine`
- `ds_block_tile_engine`
- `dw_tile_fusion_engine`
- `dw_mac_lanes`

It then reached `dw_tile_buffer` and emitted:

```text
WARNING: [Synth 8-5856] 3D RAM bank_mem_reg for this pattern/configuration is not supported. This will most likely be implemented in registers
```

After more than 30 minutes with no further log progress, the Vivado process was stopped manually. This is a real synthesis attempt and a useful result: the full top cannot yet be treated as a clean FPGA synthesis target because `dw_tile_buffer` is not written in a BRAM-friendly form.

## Implication

Before expecting meaningful full-accelerator LUT/FF/BRAM/DSP numbers, the buffer/SRAM structures should be rewritten or wrapped so Vivado infers BRAM/LUTRAM intentionally:

- Replace multidimensional RAM arrays with explicit bank modules or vendor RAM wrappers.
- Split `dw_tile_buffer` into pixel/channel banks with one read/write access per physical memory per cycle.
- Add RAM style attributes only after the access pattern is compatible with the intended RAM primitive.
- Re-run `scripts/run_synthesis_vivado.ps1 -Top cnn_top`.

See `docs/synthesis_vivado_summary.md` for successful Vivado OOC synthesis of representative submodules.

