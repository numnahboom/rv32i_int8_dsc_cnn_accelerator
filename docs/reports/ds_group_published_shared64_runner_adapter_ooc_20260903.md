# Group-published shared64 runner adapter routed OOC screen (2026-09-03)

## Boundary

This is an isolated OOC implementation of the current packed-memory
`ds_group_published_shared64_runner_adapter` bridge on
`xc7z020clg400-1`, Vivado 2025.2, with an 8.000 ns clock (125 MHz). It is
not `cnn_top` or full-top closure. The routed design was opened from the
current packed-memory synth checkpoint:

```text
build/reports/vivado_ds_group_published_shared64_runner_adapter_synth_20260903/
  ds_group_published_shared64_runner_adapter_synth.dcp
```

The route script performed `opt_design`, `place_design -directive Explore`,
`phys_opt_design -directive Explore`, and `route_design -directive Explore`,
then generated post-route timing, utilization, route-status, congestion,
fanout, clock, power, DRC, and checkpoint artifacts. Run settings are in
`build/reports/vivado_ds_group_published_shared64_runner_adapter_route_20260903/run_settings.txt`.

## Authoritative routed evidence

| Item | Post-route result | Decision |
|---|---:|---|
| Clock | 8.000 ns / 125.000 MHz | specified correctly |
| WNS | **-41.387 ns** | NO-GO |
| TNS | **-41,741.602 ns**, 15,585 failing / 77,238 endpoints | NO-GO |
| WHS | +0.084 ns | passes hold |
| THS | 0.000 ns, 0 failing / 77,238 endpoints | passes hold |
| Route status | 46,119/46,119 routable nets fully routed; 0 routing errors | passes routing |
| LUT | 13,640 / 53,200 = 25.64% | under 70% |
| FF | 31,901 / 106,400 = 29.98% | under 70% |
| BRAM | 38.5 / 140 = 27.50% | under 70% |
| DSP | 122 / 220 = 55.45% | under 70% |
| Total on-chip power | **0.324 W** (dynamic 0.216 W, static 0.108 W) | below 3 W, but fails energy gate |

Primary artifacts:

```text
build/reports/vivado_ds_group_published_shared64_runner_adapter_route_20260903/
  timing_summary_post_route.txt
  reg_to_reg_maxpaths.txt
  reg_to_reg_minpaths.txt
  critical_paths_max.txt
  utilization_post_route.txt
  utilization_post_route_hier.txt
  route_status_post_route.txt
  high_fanout_post_route.txt
  clock_utilization_post_route.txt
  power_post_route.txt
  drc_post_route.txt
  ds_group_published_shared64_runner_adapter_ooc_post_route.dcp
```

## Timing and critical-cone diagnosis

The worst setup path is in the same source-address/producer-fill cone:

```text
source:      u_source_adapter/footprint_width_reg_reg[4]_replica/C
destination: u_producer/u_4x8/u_producer/u_window_shell/u_fill/
             desc_quarter_reg[4][1]/CE
path group:  clk
data delay:  49.098 ns (logic 29.493 ns, route 19.605 ns)
logic:       101 levels (74 CARRY4, 2 LUT2, 2 LUT3, 18 LUT4, 2 LUT5, 3 LUT6)
```

The top fanout contributors are the shared requant reset net (12,140 loads),
another shared requant reset net (2,735), top-level `rst_n` (1,475), four
producer local-requant nets (1,369 each), and shared bank multiplier/bias nets
(715/689). The hierarchy resource/power report attributes 7,214 LUT and
17,798 FF/81 DSP to `u_sweep`, 5,036 LUT and 11,448 FF/33 DSP to `u_producer`,
and 988 LUT/133 FF/4 DSP to `u_source_adapter`; `u_sweep` consumes 0.134 W,
the producer 0.034 W, and the source adapter 0.018 W in the vectorless power
estimate.

## Energy interpretation and decision

The six-shape bridge simulation reports 8,388,608 semantic operations and
156,554 adapter `start`-to-`done` cycles. At 125 MHz and 0.324 W, that
isolated number would be 6.698 GOPS and 20.672 GOPS/W. It is not an
end-to-end inference number: the preceding runner configuration phase has
35,072 scalar writes, which must be counted. With those writes included,
the lower-bound ledger is 191,626 cycles, 5.472 GOPS, and **16.889 GOPS/W**.
The 20 GOPS/W hard gate at 0.324 W permits at most 161,817 total cycles.

The projected full C0 cycle is not proven by this bridge OOC; the previously
circulated 243,605-cycle projection would also be below 20 GOPS/W at this
power. No logits/full-network claim is made here.

**Decision: NO-GO.** Routing and all resource limits pass, but setup timing
fails catastrophically (`WNS=-41.387 ns`) and the configuration-inclusive
energy ledger fails the 20 GOPS/W gate. This remains bridge-only OOC evidence;
do not promote it to `cnn_top` or call it full-top closure. No RTL, testbench,
adapter, runner, or CNN-top file was changed for this routed screen.
