# Initial Synthesis Report

- Date: 2026-06-14T14:14:06+08:00
- Top module: `cnn_top`
- Script: `scripts/yosys_cnn_top.ys`

## Status

`yosys` was checked on this machine before reporting:

- Windows PATH: `yosys` not found.
- WSL PATH: `yosys: command not found`.

Therefore no Yosys cell/resource/timing numbers were produced on this machine.

Vivado 2021.2 was later found at `D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat`. See `docs/synthesis_vivado_summary.md` for the Vivado run results.

This is a real tool-run attempt, not a fabricated synthesis result. Install Yosys, then rerun:

```bash
cd /mnt/d/Stuff/Project
./scripts/run_synthesis_yosys.sh
```

Expected outputs after a successful run:

- `build/reports/synthesis_initial.md`
- `build/reports/yosys_cnn_top.log`
- `build/reports/yosys_cnn_top_stat.txt`
- `build/reports/cnn_top_yosys.json`

## Reproducibility

The Yosys script reads the current `rtl/common` and `rtl/cnn` Verilog sources, sets `cnn_top` as the top module, runs hierarchy/proc/opt/fsm/memory passes, then emits generic synthesis statistics.

If the first real synthesis fails, likely fixes are:

- Replace or guard testbench-only constructs if any are pulled into the file list.
- Add memory inference pragmas or wrappers for SRAM-like arrays.
- Split very large buffers before `synth` if Yosys maps them into registers.
- Run vendor Vivado synthesis for final LUT/FF/BRAM/DSP/timing numbers.
