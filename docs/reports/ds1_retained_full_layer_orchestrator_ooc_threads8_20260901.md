# DS1 retained full-layer orchestrator: 8-thread routed OOC screen

This is a fresh, dedicated post-route OOC screen for the current prefill-overlap
`ds1_retained_full_layer_orchestrator`. It contains RTL dependencies only; no
testbench is read by the implementation script. The OOC result is not full-top
timing closure or a complete-network throughput result.

## Run contract

The run used Vivado 2025.2, part `xc7z020clg400-1`, an 8.000 ns clock
(125 MHz), and `set_param general.maxThreads 8`. The route directive was
`Explore`. The script verifies the parameter after setting it and writes the
effective value to `run_settings.txt`; the Vivado log also reports
`Multithreading enabled for route_design using a maximum of 8 CPUs`.

Script: `scripts/vivado_ds1_retained_full_layer_orchestrator_ooc_threads8_20260901.tcl`

## Post-route evidence

| Metric | Result |
|---|---:|
| WNS | +0.040 ns |
| TNS | 0.000 ns |
| WHS | +0.053 ns |
| THS | 0.000 ns |
| Clock | 8.000 ns / 125.000 MHz |
| Fully routed nets | 42,730 |
| Routing errors | 0 |
| Slice LUTs | 11,035 / 53,200 (20.74%) |
| Slice registers | 31,646 / 106,400 (29.74%) |
| Block RAM tiles | 24 / 140 (17.14%) |
| DSPs | 97 / 220 (44.09%) |
| Estimated total on-chip power | 0.414 W |

All user-specified timing constraints are met in this isolated OOC design.
The OOC DRC report has zero errors; Vivado notes that some connectivity checks
are omitted for an out-of-context design.

## Artifacts

Output directory:

`build/reports/vivado_ds1_retained_full_layer_orchestrator_ooc_threads8_20260901/`

The routed checkpoint is:

`build/reports/vivado_ds1_retained_full_layer_orchestrator_ooc_threads8_20260901/ds1_retained_full_layer_orchestrator_ooc_threads8_post_route.dcp`

The directory contains `run_settings.txt`, `vivado_threads8.log`, timing,
utilization, route-status, power, congestion, high-fanout, DRC reports, and
the routed DCP.

## Comparison with pre-overlap OOC

The pre-overlap OOC directory
`build/reports/vivado_ds1_retained_full_layer_orchestrator_ooc_20260901/`
also measured WNS **+0.040 ns**, TNS **0.000 ns**, WHS **+0.053 ns**, and
THS **0.000 ns**. The 8-thread rerun therefore produced no timing change at
the report precision; it confirms that using eight route threads does not
degrade this OOC result. Both measurements are isolated OOC evidence only and
must not be presented as `cnn_top` full-top closure.
