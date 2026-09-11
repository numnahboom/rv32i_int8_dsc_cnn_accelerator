# cnn_top retained-only DS physical envelope (2026-09-01)

## Scope

This is a physical go/no-go screen only.  `cnn_top` was synthesized with
`USE_DS1_RETAINED_ORCHESTRATOR=1` and `USE_RETAINED_ONLY_DS=1`; the latter is an
elaboration-time generate selector that excludes the legacy
`u_ds_block_engine`.  The exact retained DS1 descriptor is the only DS shape
supported by this variant.  Other DS descriptors are intentionally
non-functional in this screen and this result must not be used as a fullnet
functional result.  The default production configuration remains
`USE_RETAINED_ONLY_DS=0`.

## Run configuration

- Vivado 2025.2, device `xc7z020clg400-1`
- 8.000 ns core clock (125 MHz target)
- `general.maxThreads=8`
- Normal top-level synthesis (`synth_design` without `-mode out_of_context`)
- Implementation directive `Explore`
- Run directory: `build/reports/vivado_cnn_top_retained_only_ds_full_impl/runs/20260901T110855613-39700`

The place log confirms `Multithreading enabled for place_design using a maximum
of 8 CPUs`.

## Result: NO-GO / placement infeasible

Synthesis and `opt_design` passed, but placement did not start beyond IO
placement.  Vivado reported:

```
[Place 30-58] IO placement is infeasible. Number of unplaced IO Ports (201)
is greater than number of available pins (125).
```

Therefore there is no valid placed or routed design, and post-route WNS/TNS,
WHS/THS and estimated post-implementation power are unavailable.  This is a
top-level package-pin feasibility blocker, not a timing failure.

## Synthesis resource envelope

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| Slice LUTs | 40,906 | 53,200 | 76.89% |
| Slice registers | 48,197 | 106,400 | 45.30% |
| Block RAM tiles | 64 | 140 | 45.71% |
| DSPs | 126 | 220 | 57.27% |
| Bonded IOB | 202 | 125 | 161.60% |

The synthesis LUT count already exceeds the requested `<70%` screen; the
post-opt/post-route count cannot be established because IO placement failed.

## Hierarchy proof

The elaborated/synthesized hierarchy was queried for
`*u_ds_block_engine*` and returned `legacy_instance_count=0`:

- [synthesis hierarchy proof](../../build/reports/vivado_cnn_top_retained_only_ds_full_impl/runs/20260901T110855613-39700/hierarchy_synth.txt)
- [manifest](../../build/reports/vivado_cnn_top_retained_only_ds_full_impl/runs/20260901T110855613-39700/manifest.txt)
- [synthesis utilization](../../build/reports/vivado_cnn_top_retained_only_ds_full_impl/runs/20260901T110855613-39700/utilization_synth.txt)

The physical hierarchy proof cannot be produced because no placed/routed
physical design exists.  The next blocker to resolve for a true full-top
physical screen is a valid board/package IO contract or a physically justified
small-pin wrapper; after that, LUT utilization is the next immediate resource
gate.
