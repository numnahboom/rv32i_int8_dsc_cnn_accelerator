# Post-fix regression and routed timing evidence (2026-08-23)

This report records fresh evidence at HEAD `d5e4c6f063a4d1520fe8c529b1a0170d941f8c93`, after the portable DW MAC fix. The worktree was already dirty; the implementation run recorded the pre-existing dirty-tree hashes and no existing user path was modified.

## Functional regression

Fresh Vivado 2021.2 XSim, compiling all 27 RTL files and running the selected
16-test gate:

```text
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1
PASS cnn_xsim_regression tests=16
```

Evidence: `build/reports/cnn_xsim_postfix_20260823_195010.log`. The fullnet
test passed 10/10 logits; the generated performance summary reports 993,869
hardware cycles, 5,136,896 MACs, and a 343.50x RV32I estimate.

Fresh WSL Verilator batch (no `SIM_RESUME`, 40 tests, fresh output directory):

```text
SIM_LOG_DIR=build/reports/verilator_postfix_20260823_195240 \
  SIM_CONTINUE_ON_FAIL=1 ./scripts/run_all_sims.sh
all selected simulations passed
```

The batch summary is `build/reports/verilator_postfix_20260823_195240/summary.csv`;
all 40 rows are `PASS`. Verilator emitted existing lint warnings (blocking
assignments and large replication), but no simulation failed.

## Routed OOC timing

Vivado 2025.2, `xc7z020clg400-1`, `cnn_top`, `RuntimeOptimized`, unique run
`20260823T200305828-24020`:

```text
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_impl.ps1 \
  -Vivado D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat \
  -Part xc7z020clg400-1 -Top cnn_top -Directive RuntimeOptimized
```

Implementation, physical optimization, routing, timing reporting, power
reporting, and checkpoint writing completed. The route report proves
46,434/46,434 routable nets fully routed and zero routing errors.

| Metric | Fresh routed result | Prior documented `keep` candidate |
|---|---:|---:|
| WNS | -8.999 ns | -8.920 ns |
| WHS | +0.081 ns | +0.089 ns |
| THS | 0.000 ns | 0.000 ns |
| TNS | negative paths present | negative paths present |
| Routable nets | 46,434 | documented as fully routed |

The worst setup path is `u_layer_runner/u_fc_unit/product_reg_reg__0/CLK` to
`u_layer_runner/u_fc_unit/requant_reg_reg[5]/D`: 18.946 ns data delay, 44
logic levels, and -8.999 ns slack at the 10 ns generic OOC clock. The timing
summary reports zero unconstrained internal endpoints. It reports 102 input
ports and 98 output ports without I/O delay, expected for this OOC constraint;
the implementation manifest conservatively records the unconstrained-path
check as `NONZERO_OR_UNPARSEABLE` because those unconstrained I/O ports remain.

The run status is `FAILED_TIMING_CLOSURE`: this is fully routed FPGA-fabric
evidence and a timing diagnosis, not 100 MHz timing closure, board I/O/clock
closure, hardware validation, or measured power. No RTL modification was
warranted by this regression.

Primary artifacts are under
`build/reports/vivado_cnn_top_impl/runs/20260823T200305828-24020/`:
`manifest.txt`, `timing_summary.txt`, `timing_maxpaths.txt`, `route_status.txt`,
`utilization_post_route.txt`, and `cnn_top_impl.dcp`.
