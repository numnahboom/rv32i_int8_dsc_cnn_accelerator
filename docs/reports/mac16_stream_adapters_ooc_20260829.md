# MAC16 stream core and operand adapters: isolated OOC evidence

This is an isolated implementation screen for `mac16_stream_core`,
`mac16_stem_adapter`, and `mac16_dw_adapter` through
`mac16_stream_adapters_ooc_wrapper`. It is not a `cnn_top` integration or
full-network timing result.

## Functional evidence

`bash scripts/run_mac16_stream_adapters_sim.sh` passed with Verilator 5.020:

```text
PASS tb_mac16_stream_adapters shared_core cases=5 checks=240
```

The cases cover alternating Stem and DW transactions, bubbles, full and tail
masks, sparse masks, signed extrema, output backpressure, token tags, and
masked-lane zero results. A directed attempted DW mode change while a Stem
transaction is active is held in the adapter and flagged once by the
simulation-only mode-lock assertion; the core's token sequencing counter
reported no errors.

## XC7Z020 post-route screen

Command: Vivado 2025.2, `xc7z020clg400-1`, `general.maxThreads=2`,
`RuntimeOptimized` synthesis, 8.000 ns clock, place and route.

Reports: `build/reports/vivado_mac16_stream_adapters_ooc_20260829/`.

| Metric | Post-route result |
|---|---:|
| Setup WNS / TNS | +0.154 ns / 0.000 ns |
| Hold WHS / THS | +0.132 ns / 0.000 ns |
| Setup failing endpoints | 0 |
| Slice LUTs | 1,600 (3.01%) |
| Slice registers | 1,532 (1.44%) |
| DSPs | 16 (7.27%) |
| BRAM | 0 |
| Total on-chip power | 0.163 W |
| Routing errors | 0 |

The design contains one reusable 16-lane core. The Stem and DW adapters are
registered operand-ingress stages; a mode selector locks to the first token
accepted and holds that mode through `last_token`, while core output metadata
routes the completed result back to the corresponding client. Vivado mapped
the 16 int8 multipliers to 16 DSPs. The critical setup paths are the registered
product/accumulation control cone; the routed result has 0.154 ns setup and
0.132 ns hold margin at the 8 ns screen clock.

The OOC result has positive timing margin but is only a standalone gate; it
does not establish full-top timing closure, network cycles, or board power.
