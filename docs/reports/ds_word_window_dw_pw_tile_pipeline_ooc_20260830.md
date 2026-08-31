# DW/PW word-window tile pipeline OOC screen (2026-08-30)

## Scope

This is a non-production physical screen for
`ds_word_window_dw_pw_tile_pipeline`.  The RTL is not integrated into
`cnn_top` or the production runner.  The functional candidate was already
validated with Verilator under source-memory stalls, output backpressure,
tail masks, and alternating bank/epoch ownership: 1,245 outputs, 352 PW
reads, 14,775 cycles, and zero mismatches.  This report records the physical
validation boundary and its negative timing/resource result.

## 8 ns XC7Z020 OOC post-route

The full-generic OOC script is:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_pw_tile_pipeline_ooc_20260829.tcl
```

Vivado 2025.2 targeted `xc7z020clg400-1`, `general.maxThreads=1`,
`flatten_hierarchy none`, explicit XPM source loading, and an 8.000 ns clock.
The full-generic attempt (`MAX_CIN=16`, `MAX_COUT=16`, 10x10, FIFO depth 2)
completed synthesis with zero errors but exited with code 1 immediately after
part/timing loading, before `place_design`; therefore it produced no valid
16/16 post-route result.

To establish a bounded physical result, the reduced-generic screen used:

```text
MAX_CIN=8, MAX_COUT=8, MAX_IN_H=10, MAX_IN_W=10, FIFO_DEPTH=2
```

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_pw_tile_pipeline_ooc_20260830_8x8.tcl
```

Run directory:
`build/reports/vivado_ds_word_window_dw_pw_tile_pipeline_ooc_20260830_8x8/`

| Metric | Post-route result |
|---|---:|
| Clock / frequency | 8.000 ns / 125.000 MHz |
| WNS / setup failures | -0.803 ns / 513 |
| TNS | -133.573 ns |
| WHS / hold failures | +0.073 ns / 0 |
| Pulse-width slack / failures | +2.750 ns / 0 |
| Routing errors / unrouted nets | 0 / 0 |
| Slice LUTs | 20,525 / 53,200 (38.58%) |
| Slice registers | 42,504 / 106,400 (39.95%) |
| DSP48E1 | 160 / 220 (72.73%) |
| Block RAM tiles | 40 / 140 (28.57%) |
| Estimated total on-chip power | 0.268 W |

The screen therefore fails the 8 ns timing gate and the `<70%` DSP limit.
It is not evidence of full-generic acceptance, full-top timing closure, or
20 GOPS/W.

## Timing diagnosis

The 200 reported reg-to-reg setup paths are strongly routing dominated: total
delay averages 8.125 ns (7.631--8.751 ns), with logic averaging 1.650 ns and
routing 6.476 ns (79.7% of total; every sampled path has route delay greater
than logic delay).  The worst path is:

```text
u_scratch1/epoch_reg[3]_replica/C
  -> u_dw/prefetch_addr_reg[0]/D
```

with 8.751 ns data delay, 1.944 ns logic, 6.807 ns route, and -0.803 ns
slack.  The path crosses scratch-bank ready logic, the DW sink ready chain,
and DW emit/prefetch address control.  Of the 200 paths, 180 start at the
replicated `u_scratch1/epoch_reg[3]` source (reported fanout 43,603), 16 at
`u_scratch1/write_seen_reg[144]`, three at scratch0 configuration, and one at
PW requant issue control.  Destinations are dominated by DW control (137)
and DW requant sink (43); only 16 are outside those groups.  This identifies
global bank/ready/epoch control fanout and routing, rather than the PW MAC
array alone, as the primary physical limit.

The design routed with no failed nets, but the final router report shows
localized congestion: maximum global congestion was 91.89% south, 94.12%
east, and 92.65% west.  DRC reported no errors; warnings are primarily
expected OOC input/output pipelining and DSP PREG/MREG recommendations, plus
the OOC PS7/route-status checks.

## Decision

Do not integrate this exploratory pipeline into the full top.  The bounded
screen demonstrates legal placement/routing and confirms the functional
protocol, but its setup deficit, route-dominated control paths, high DSP use,
and unresolved 16/16 physical run make it unsuitable as the next production
candidate.  Future work should reduce replicated/global control fanout and
DSP cost before another full-generic OOC attempt; the existing partial-K
output-stationary direction remains the architectural path for cycle and
energy objectives.
