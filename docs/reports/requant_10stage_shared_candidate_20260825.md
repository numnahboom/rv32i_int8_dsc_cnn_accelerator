# Ten-stage shared requant candidate evidence (2026-08-25)

## Scope and decision

This report records the retained ten-stage implementation of
`rtl/cnn/requant_activation_unit.v` and its DS-block tag/descriptor integration
in `rtl/cnn/ds_block_tile_engine_new.v`.  The candidate preserves the existing
single-outstanding ready/valid interface and the network's arithmetic and
cycle-level functional contract.  No burst, tagged-bus, or multi-outstanding
architecture was introduced.

The implementation is retained as a functionally verified and physically
promising candidate.  It is **not timing closure**: the full `cnn_top` routed
OOC run still has substantially negative setup slack.

## RTL architecture and semantic boundary

The requant unit is a throughput-one, globally stalled ten-stage elastic
pipeline.  `v[9:0]` is the valid pipeline and
`advance = !v[9] || ready_out`; when the output is blocked, all data and
metadata stages freeze together.  The ten registered stages are:

1. signed accumulator plus bias and multiplier/parameter capture;
2. four explicitly widened partial products (`17x16`, `17x16`, `16x16`,
   `16x16`);
3. two carry-save compressor levels;
4. low 32-bit carry-propagate add and carry extraction;
5. high-word carry-propagate add, with the low word explicitly delayed by
   `low_s4` to preserve alignment under continuous traffic;
6. signed Q31 rounding/fixed-point reconstruction;
7. low shift amount application;
8. high shift amount application;
9. output-zero-point addition;
10. int8 saturation and activation clamp.

The Q31 rounding path uses slice/sign folding rather than a 65-bit negate
carry chain.  The implementation retains the prior signed rounding behavior,
including `INT64_MIN` and near-extrema cases.  Parameter registers are pipelined
with the data.  DS-block tags advance on `rq_ready_in` and use the final tag
stage at the output, keeping descriptor operands, data, and tags aligned.

## Functional verification

The following completed checks passed:

| Check | Result |
| --- | --- |
| `tb_requant_activation_unit` golden vectors | 100/100 PASS |
| Temporary randomized ready/valid checker | 100 inputs, 100 outputs PASS |
| `tb_ds_block_tile_engine_new` | 7 cases, 2191 checks PASS |
| Stem requant regression | PASS |
| Tiled DSBlock top datapath | PASS |
| Full-network exact-logit regression | 10/10 PASS, 1,021,031 cycles |

These are simulation/regression results; they do not constitute board or
hardware validation.

## Isolated 8 ns routed OOC screen

The wrapper and flow are:

- `rtl/cnn/requant_activation_unit_ooc_wrapper.v`
- `scripts/vivado_requant_unit_ooc_20260825.tcl`
- Vivado 2025.2, `xc7z020clg400-1`, out-of-context, 8.000 ns clock

Post-route results under
`build/reports/vivado_requant_unit_ooc_20260825/`:

| Metric | Result |
| --- | ---: |
| WNS | +1.425 ns |
| WHS | +0.098 ns |
| Unrouted nets | 0 |
| DSP48E1 | 4 |
| LUT | 391 |
| FF | 1505 |
| BRAM | 0 |
| Worst register-to-register datapath | 0.612 ns |
| Register-to-register paths over 8 ns | 0 |
| Maximum CARRY4/path depth observed | 9 |
| Vectorless total on-chip power | 0.143 W |

The strict structural gate passed.  This is isolated wrapper evidence only;
it excludes full-top fanout, placement interaction, I/O timing, and board
behavior.

## Full `cnn_top` routed OOC Explore

Run manifest:
`build/reports/vivado_cnn_top_impl_requant_20260825/manifest.txt`

Configuration: Vivado 2025.2, `xc7z020clg400-1`, `Explore`, 10 ns clock,
post-route OOC core-clock check.  Synthesis, placement, physical optimization,
route, reports, and checkpoint all completed.  Route status was 47,592/47,592
routable nets fully routed with zero routing errors.

| Run | WNS (ns) | TNS (ns) | WHS (ns) | Setup failing endpoints | LUT | FF | BRAM | DSP | Power (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| runner-area control | -5.583 | -15493.366 | +0.016 | 9312 | 30306 | 19301 | 46 | 50 | 0.220 |
| pw-desc control | -5.656 | -16894.836 | +0.077 | 9731 | 30366 | 19268 | 46 | 50 | 0.262 |
| ten-stage shared requant | **-5.664** | **-14885.386** | **+0.086** | **10433** | **30242** | **20345** | **46** | **44** | **0.223** |

Relative to runner-area, the candidate improves WNS by 0.081 ns, TNS by
607.980 ns, and WHS by 0.070 ns while reducing LUTs by 64 and DSPs by 6;
FFs increase by 1044 and estimated power increases by 0.003 W.  Relative to
the pw-desc control, WNS is 0.008 ns worse, but TNS improves by 2009.450 ns,
WHS improves by 0.009 ns, and DSP usage falls by 6.  The larger failing-endpoint
count is reported explicitly and is not treated as a universal metric win.

The worst setup path migrated away from the requant cone to the runner control
cone:

`u_layer_runner/stride_reg_reg[5]/C` ->
`u_layer_runner/tiled_load_count_reg[8]/D`, WNS `-5.664 ns`, 15.661 ns data
delay (7.339 ns logic, 8.322 ns route, 14 logic levels).

Authoritative reports include `timing_summary.txt`, `timing_maxpaths.txt`,
`route_status.txt`, `utilization_post_route.txt`, `power.txt`, and
`cnn_top_impl.dcp` in the run directory.  The manifest status is
`FAILED_TIMING_CLOSURE`; hold timing passes (`WHS +0.086 ns`, `THS 0`) but
setup timing does not (`WNS -5.664 ns`, `TNS -14885.386 ns`).  Consequently
this candidate is suitable for the next bounded structural investigation, but
cannot be called timing-closed or hardware-validated.
