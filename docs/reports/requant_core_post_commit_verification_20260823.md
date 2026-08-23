# Requant core post-commit verification (2026-08-23)

This is fresh evidence at commit `0d561c5` (`rtl: reuse requant core in FC
tail`). Existing user dirty paths were preserved; this report is the only
tracked documentation added by this verification pass.

## Functional regressions

Vivado 2025.2 XSim rebuilt 28 RTL files and ran the selected 16-test gate:

```text
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin
PASS cnn_xsim_regression tests=16
```

Evidence: `build/reports/cnn_xsim_requant_20260823_203936.log`. Fullnet was
10/10 logits, 993869 hardware cycles, 5136896 MACs, and 343.50x RV32I
estimate.

The WSL Verilator run used `GENERATE_TEST_VECTORS=0`, `SIM_CONTINUE_ON_FAIL=1`,
and a new non-resumed output directory. The repository's current list contains
41 tests (the historical “40-test” description is one short); all 41 passed:

```text
GENERATE_TEST_VECTORS=0 SIM_LOG_DIR=build/reports/verilator_requant_20260823_204558 \
  SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
all selected simulations passed
```

Evidence: `build/reports/verilator_requant_20260823_204558/summary.csv` (41
PASS rows). No stale resumed result was used. Existing Verilator lint warnings
and GNU make clock-skew warnings did not cause a test failure.

## Fresh routed OOC implementation

Vivado 2025.2, `xc7z020clg400-1`, `cnn_top`, `RuntimeOptimized`, run
`20260823T204840470-31892` completed synthesis, placement, routing, timing and
power reporting. The route report proves 46,409/46,409 routable nets fully
routed and zero routing errors. Artifacts are under
`build/reports/vivado_cnn_top_impl/runs/20260823T204840470-31892/`.

| Metric | Fresh `0d561c5` | Prior `98782b8` run | Delta |
|---|---:|---:|---:|
| WNS | -9.761 ns | -8.999 ns | -0.762 ns |
| TNS | -38841.840 ns | -43900.801 ns | +5058.961 ns |
| WHS | +0.093 ns | +0.081 ns | +0.012 ns |
| THS | 0.000 ns | 0.000 ns | 0 |
| Setup failing endpoints | 15858 / 54617 | 17469 / 54823 | improved |
| Slice LUTs | 29900 (56.20%) | 29799 (56.01%) | +101 |
| Slice registers | 18267 (17.17%) | 18370 (17.27%) | -103 |
| BRAM tiles | 46 (32.86%) | 46 (32.86%) | 0 |
| DSPs | 55 (25.00%) | 55 (25.00%) | 0 |

The worst setup path is
`u_layer_runner/u_fc_unit/product_reg_reg__0/CLK` to
`u_layer_runner/u_fc_unit/requant_reg_reg[3]/D`: 19.754 ns data delay, 39
logic levels, and -9.761 ns slack at the generic 100 MHz OOC clock. Timing
reports show zero unconstrained internal endpoints, while 102 input and 98
output ports lack I/O delay constraints as expected for this OOC wrapper.

The implementation status is `FAILED_TIMING_CLOSURE`. The shared core is
functionally clean, but its wide combinational requant path remains the timing
bottleneck; this run does not establish 100 MHz closure, board I/O/clock
closure, hardware validation, or measured power.
