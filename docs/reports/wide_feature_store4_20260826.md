# Wide feature-store4 verification report (2026-08-26)

## Scope and semantic boundary

This change widens the internal feature SRAM and `cnn_out_buffer` storage to
32-bit words with four independent byte enables.  Addresses remain byte
addresses; the low two address bits select the byte lane, and word writes use
little-endian lanes `[7:0]`, `[15:8]`, `[23:16]`, and `[31:24]`.

The legacy scalar read/write behavior, one-cycle synchronous SRAM read
contract, host arbitration, external memory request ABI, descriptor format,
and logits format are unchanged.  DSBlock output stores use an aligned,
four-consecutive-channel transaction when eligible; unaligned, partial, and
tail cases retain scalar writes.  Stem and GAP stores remain scalar.

## Files

- RTL: `rtl/cnn/cnn_layer_runner.v`, `rtl/cnn/cnn_top.v`,
  `rtl/cnn/feature_sram_bank.v`, `rtl/cnn/feature_sram_pingpong.v`
- Verification: `sim/tb_feature_sram_bank_word.v`,
  `sim/tb_cnn_top_fullnet_sram_datapath.v`
- Regression/OOC: `scripts/run_all_sims.sh`,
  `scripts/vivado_feature_sram_bank_wide_ooc_20260826.tcl`,
  `scripts/vivado_cnn_out_buffer_wide_ooc_20260826.tcl`

## Functional and performance verification

XSim randomized SRAM semantic check:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_feature_sram_bank_word
```

Result: `PASS`, 354 checks, including partial byte enables, all byte lanes,
same-cycle scalar read/write, and scalar-over-word write priority.

XSim DS/tiled/backpressure/fullnet check:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_feature_sram_bank,tb_feature_sram_pingpong,tb_cnn_top_dsblock_datapath,tb_cnn_top_backpressure,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath
```

Result: all 6 tests passed.  The final XSim fullnet run also passed 10/10
logits exactly.

The standalone XSim fullnet command was:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_top_fullnet_sram_datapath
```

Verilator regression:

```bash
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_feature_sram_bank_word tb_feature_sram_bank tb_feature_sram_pingpong tb_cnn_top_dsblock_datapath tb_cnn_top_backpressure tb_cnn_top_tiled_dsblock_datapath tb_cnn_top_sram_tiled_dsblock_datapath tb_cnn_top_fullnet_sram_datapath" SIM_CONTINUE_ON_FAIL=1 SIM_LOG_DIR=build/reports/verilator_wide_feature_20260826 bash scripts/run_all_sims.sh
```

Result: all 8 selected tests passed.  Fullnet was bit-exact, with
`858,576 cycles`, `5,136,896 MACs`, external memory reads/writes
`78,890/10`, and feature-SRAM write transactions `38,144` total.  The DS
vector4 portion accounts for `21,504` four-byte transactions; scalar Stem/GAP
stores account for the remainder.

Compared with the retained `949,792-cycle` baseline, the final fullnet result
is `91,216 cycles` lower, an improvement of `9.604%`.

## 8 ns OOC results

The isolated post-route OOC runs used `xc7z020clg400-1`, Vivado 2025.2, and an
8.000 ns clock.  Reports are under:

- `build/reports/vivado_feature_sram_bank_wide_ooc_20260826/`
- `build/reports/vivado_cnn_out_buffer_wide_ooc_20260826/`

They were launched with:

```powershell
vivado.bat -mode batch -notrace -source scripts/vivado_feature_sram_bank_wide_ooc_20260826.tcl
vivado.bat -mode batch -notrace -source scripts/vivado_cnn_out_buffer_wide_ooc_20260826.tcl
```

`feature_sram_bank`: 83 LUT, 12 FF, 8 RAMB36, 0 DSP, zero route errors.
WNS/WHS are `NA` because this isolated memory primitive has no reportable
internal register-to-register setup/hold data path; the 8 ns clock and pulse
width checks are present and passing.

`cnn_out_buffer`: 59 LUT, 3 FF, 4 RAMB36, 0 DSP, zero route errors; WNS
`+6.513 ns`, TNS `0`, WHS `+0.228 ns`, THS `0`.

The full `cnn_top` Explore routed OOC was not rerun after this vector4
integration.  Therefore this report does not claim post-route top-level
125 MHz timing closure or a new top-level WNS/Fmax result.

`git diff --check` passed.
