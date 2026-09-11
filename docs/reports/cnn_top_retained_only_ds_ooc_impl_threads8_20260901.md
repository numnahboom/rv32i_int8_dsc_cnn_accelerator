# `cnn_top` retained-only DS top-level OOC physical envelope (2026-09-01)

## Scope

This is an intentionally nonfunctional-other-DS physical envelope, not a
full-network functional or performance result.  The run elaborates
`USE_DS1_RETAINED_ORCHESTRATOR=1` and `USE_RETAINED_ONLY_DS=1`; descriptors
outside the exact retained DS1 shape are not claimed functional here.  The
normal production default remains unchanged (`USE_RETAINED_ONLY_DS=0`).

## Run configuration

- Vivado 2025.2, `xc7z020clg400-1`
- Core-clock constraint: 8.000 ns (125 MHz target)
- `general.maxThreads=8`
- Implementation directive: `Explore`
- Synthesis: top-level out-of-context (`synth_design -mode out_of_context`)
- Retained-only generic: `USE_DS1_RETAINED_ORCHESTRATOR=1 USE_RETAINED_ONLY_DS=1`
- Run directory: [OOC run](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8)

The authoritative settings are in [run_settings.txt](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/run_settings.txt).

## Route result

Routing completed and the implementation checkpoint was written.  The final
route report shows 79,309 routable nets, 79,309 fully routed nets, and 0 nets
with routing errors.  Both synthesis and post-route hierarchy proofs report
`legacy_instance_count=0` for `*u_ds_block_engine*`.

## Timing and power

| Metric | Result |
|---|---:|
| WNS | -3.186 ns |
| TNS | -11,746.716 ns |
| Failing setup endpoints | 16,531 / 115,185 |
| WHS | +0.053 ns |
| THS | 0.000 ns |
| Total on-chip power | 0.458 W |
| Dynamic / device static | 0.346 W / 0.112 W |

The worst setup path is
`u_layer_runner/tiled_load_channel_reg[2]/C` to
`u_layer_runner/FSM_onehot_state_reg[10]/CE`, with 10.897 ns data-path delay
(5.034 ns logic, 5.863 ns route), 18 logic levels, and -3.186 ns slack.
The timing summary's unconstrained-path table has no path group entries, but
the flow's conservative parser recorded `NONZERO_OR_UNPARSEABLE`; this is not
used to turn the failed timing result into a pass.

## Post-route resource envelope

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| Slice LUTs | 38,205 | 53,200 | 71.81% |
| Slice registers | 46,758 | 106,400 | 43.95% |
| Block RAM tiles | 64 | 140 | 45.71% |
| DSPs | 126 | 220 | 57.27% |

Slice occupancy is 13,088 / 13,300 (98.41%), also indicating a highly packed
physical design.

## Strict decision

**NO-GO.**  Route completion and power are valid, but the 125 MHz timing gate
fails (WNS/TNS negative) and the requested `<70%` Slice LUT gate fails at
71.81%.  This run is a physical screening result only; it does not establish
full-top functional correctness, full-network cycle count, or energy
efficiency.

## Evidence

- [manifest](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/manifest.txt)
- [route status](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/route_status.txt)
- [timing summary](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/timing_summary.txt)
- [worst paths](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/timing_maxpaths.txt)
- [post-route utilization](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/utilization_post_route.txt)
- [post-route power](../../build/reports/vivado_cnn_top_retained_only_ds_ooc_impl/runs/20260901T113500-retained-only-ooc8/power.txt)
