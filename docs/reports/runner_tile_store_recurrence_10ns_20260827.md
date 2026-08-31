# Tiled-store recurrence at 10 ns (2026-08-27)

## Scope

This runner-only screen validates the retained tiled-store base recurrence in
`rtl/cnn/cnn_layer_runner.v` against the 10 ns constraint. It does not rebuild
`cnn_top` and does not claim full-top timing closure.

## Timing result

Command:

```text
$env:RUNNER_OOC_OUT = "vivado_cnn_layer_runner_tiled_store_recurrence_10ns_20260827"
$env:RUNNER_OOC_PERIOD = "10.000"
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -notrace -source scripts/vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl
```

The `xc7z020clg400-1` runner-only design routed with zero routing errors and
zero unrouted nets. The explicit query for the target cone reported:

```text
from_count=5 to_count=32
clock_period_ns=10.000
path_count=0
```

Thus no `tile_h_start_reg -> tiled_store_addr_current_reg` timing paths remain
in this fresh 10 ns netlist. The new runner-wide worst setup path is instead
`store_idx_reg[5]/C -> u_out_buffer/.../ADDRBWRADDR[7]`, with 12.827 ns data
delay (6.411 ns logic, 6.416 ns route) and 22 logic levels.

| Metric | 10 ns runner result |
|---|---:|
| WNS | -3.354 ns |
| TNS | -4674.572 ns |
| Setup failing endpoints | 6137 / 82199 |
| WHS | +0.096 ns |
| THS | 0.000 ns |
| Slice LUTs | 33,242 (62.48%) |
| Slice registers | 34,385 (32.32%) |
| BRAM tiles | 32 |
| DSPs | 70 |
| Total on-chip power estimate | 0.293 W |

The negative runner-wide WNS means this evidence is not timing closure. The
target cone result is still useful for routing: further work on that exact
tile-height-to-address recurrence is not justified by the current netlist;
the active bottleneck is the output-buffer read/address control cone.

Reports are retained under
`build/reports/vivado_cnn_layer_runner_tiled_store_recurrence_10ns_20260827/`.
