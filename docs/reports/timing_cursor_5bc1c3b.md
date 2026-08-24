# Tiled SRAM store cursor timing candidate

Candidate commit: `5bc1c3b` (`Optimize tiled SRAM store address cursor`).

Fresh Vivado 2025.2 routed OOC implementation used:

```text
part: xc7z020clg400-1
directive: RuntimeOptimized
run id: cursor-5bc1c3b-20260824
evidence: build/reports/vivado_cnn_top_impl_cursor_20260824/
status: FAILED_TIMING_CLOSURE (routed; no route errors)
```

| Metric | b665a74 baseline | cursor candidate | Delta |
|---|---:|---:|---:|
| WNS | -8.246 ns | -8.114 ns | +0.132 ns |
| TNS | -37008.645 ns | -36158.195 ns | +850.450 ns |
| WHS | not retained | +0.067 ns | no new hold failure |
| THS | 0.000 ns | 0.000 ns | 0 |

The route status reports 47,113/47,113 routable nets fully routed with zero
routing errors. The candidate satisfies the acceptance gate: WNS improves and
TNS improves by more than 250 ns. The internal SRAM tiled-store path now uses
a registered initial cursor and registered column/row jumps; the external
registered byte-address path and memory-request protocol are unchanged.

Focused XSim and matching Verilator address/backpressure regressions passed
(5/5 each). The detailed Vivado evidence is in `timing_summary.txt`,
`timing_maxpaths.txt`, `route_status.txt`, `manifest.txt`, and the routed
checkpoint under the evidence directory above.
