# Feature-tile vector16 ping-pong shell (2026-08-29)

This is a standalone integration shell, not a CNN runner change.  It combines
`feature_tile_pingpong_ctrl` with two `feature_tile_vector16_bank` instances.
Word writes carry an explicit bank selector and are accepted only while that
bank is `FILLING`; vector requests have no bank selector and are accepted only
while a bank is `ACTIVE`.  The selected read bank is registered with the
request, preserving the response mux across consume/release and a subsequent
bank swap.

## Functional validation

`scripts/run_feature_tile_vector16_pingpong_shell_sim.sh` uses Verilator 5.020
and `sim/tb_feature_tile_vector16_pingpong_shell.v`.  It instantiates both
10x10x48 (three channel groups) and 10x10x3 (tail group) shells.  The test
exercises masked and unaligned word writes, all group/address forms, random
lane masks, tagged reads, response stalls, invalid FREE-state write/read
backpressure, stale descriptor rejection, and two-bank fill/acquire/consume/
release swaps.  Result:

```
feature_tile_vector16_pingpong_shell PASS checks=520 writes=2554 reads=520 overlap_cycles=260
```

The scoreboard compares every returned lane and metadata against a byte-level
reference; the overlap counter observes ACTIVE/FILLING ownership concurrently.

## Physical screen

The OOC script is
`scripts/vivado_feature_tile_vector16_pingpong_shell_ooc_20260829.tcl`.
It is intended to be run with Vivado 2025.2 for `xc7z020clg400-1` at 8 ns,
`general.maxThreads=2`, and emits timing/utilization/power/route/DRC reports
under `build/reports/vivado_feature_tile_vector16_pingpong_shell_ooc_20260829/`.
The shell is only a reusable data-path candidate; it is not integrated into
the full CNN and therefore carries no full-top cycle or energy claim.

The completed routed OOC result is WNS **+0.619 ns**, TNS **0**, WHS
**+0.183 ns**, THS **0**, with 1,751 timing endpoints.  Route status is 4,237
of 4,237 routable nets fully routed and zero routing errors.  Utilization is
3,799 LUT (7.14%), 571 FF (0.54%), 32 RAMB18 (11.43%), and 0 DSP; estimated
total on-chip power is 0.140 W.  This clears the requested standalone 8 ns
screen (WNS >= +0.5 ns, no setup/hold failures), but remains OOC evidence only.
