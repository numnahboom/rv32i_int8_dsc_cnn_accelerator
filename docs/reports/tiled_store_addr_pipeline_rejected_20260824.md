# Tiled store address pipeline experiment (2026-08-24)

## Candidate

The task-local experiment inserted `ST_TILED_STORE_ADDR` between
`ST_TILED_STORE_SETUP` and `ST_TILED_STORE_PREFETCH` in
`rtl/cnn/cnn_layer_runner.v`.  It moved the first tiled output address and
row/column jump products into a separate cycle, targeting the
`in_w_reg -> tiled_store_addr_current_reg` setup path.  The change was then
reverted after implementation because it failed the dual timing gate.

## Functional evidence

- Verilator 5.020 tiled Stem: PASS, 16,384 checks.
- Verilator 5.020 tiled DSBlock: PASS, 2 cases, 2,256 checks.
- Vivado XSim 2021.2 tiled Stem: PASS, 16,384 checks.
- Vivado XSim 2021.2 tiled DSBlock: PASS, 2,256 checks.
- Fullnet retained the known pre-existing single mismatch at output address
  `0004d410` (`expected=2`, `actual=x` in XSim; `actual=0` in Verilator), with
  no additional output mismatch.  Candidate fullnet cycles were `995263`.

## Routed OOC Explore evidence

Command:

```text
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
```

Candidate run: `build/reports/vivado_cnn_top_impl/runs/20260824T183750799-28140/`.
The route completed with zero unrouted nets and clean hold, but setup TNS
regressed relative to the descriptor-local baseline:

| result | WNS | TNS | WHS | THS | route |
|---|---:|---:|---:|---:|---|
| candidate | -6.864 ns | -27421.453 ns | +0.038 ns | 0.000 ns | 0 unrouted |
| descriptor-local baseline | -6.997 ns | -26365.537 ns | +0.061 ns | 0.000 ns | 0 unrouted |

WNS improved by `+0.133 ns`, but TNS worsened by `-1055.916 ns`; this fails
the required simultaneous WNS/TNS improvement gate.  The candidate's first
path family moved to FC `class_idx` -> `product_reg` endpoints, while the
targeted tiled-store path remained among the next paths.  Post-route
resources were 30,263 LUT (56.89%), 19,257 FF (18.10%), 56 DSP (25.45%), and
46 BRAM (32.86%).  Vectorless estimated total on-chip power was `0.247 W`.

## Decision

Reject and revert the RTL change.  This report is retained as negative
evidence; no candidate RTL from this experiment remains in the working tree.
