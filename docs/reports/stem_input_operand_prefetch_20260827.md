# Stem input/weight operand prefetch

Date: 2026-08-27  
Device: `xc7z020clg400-1`, Vivado 2025.2, 8 ns clock

## Candidate

`rtl/cnn/conv3x3_stem_engine_new.v` now separates asynchronous distributed-RAM
reads from product formation. `ST_OPERAND` captures the three input bytes and
three weight bytes into six signed 8-bit registers. `ST_PRODUCT` then forms the
three signed 8x8 products and their 18-bit sum from those registered operands;
`ST_MAC` consumes the registered `product_sum_reg` as before. The FSM state is
the per-tap valid tag, so cursor, operands, product sum, and accumulator remain
aligned. MAC arithmetic, signed precision, requantization, output order,
dimensions, and ready/busy behavior are unchanged.

This adds one cycle per tap relative to the retained cursor split: the direct
1x1/16-channel check increased from 354 to 498 cycles (+144 cycles, 9 taps x
16 output channels). It does not change the number of DSPs or the memory
layout.

## Functional evidence

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_addr_split` | PASS, 16 writes, 498 cycles |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 writes, 498 cycles |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_backpressure` | PASS, 768 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10/10 exact logits, 1,236,702 cycles, 78,890 reads, 10 writes, 0 errors |

Commands:

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_addr_split
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_requant
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_cnn_top_tiled_stem_datapath tb_cnn_top_sram_stem_dsblock_datapath tb_cnn_top_backpressure" ./scripts/run_all_sims.sh
GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" ./scripts/run_all_sims.sh
```

## Fresh isolated OOC evidence

The reproducible flow is
`scripts/vivado_stem_input_operand_prefetch_20260827.tcl`. Reports and the
routed DCP are under
`build/reports/vivado_stem_input_operand_prefetch_20260827/`. The comparison
is the immediately preceding same-device stem parameter-capture run in
`build/reports/vivado_stem_requant_param_capture_20260827/`.

| Metric | Parameter capture | Operand prefetch | Delta |
| --- | ---: | ---: | ---: |
| WNS | -4.787 ns | -4.386 ns | +0.401 ns |
| TNS | -3538.646 ns | -1182.377 ns | +2356.269 ns |
| WHS | +0.113 ns | +0.159 ns | +0.046 ns |
| THS | 0 ns | 0 ns | 0 ns |
| Slice LUTs | 11,192 | 10,756 | -436 |
| Slice registers | 2,908 | 2,931 | +23 |
| DSPs | 10 | 10 | 0 |
| Fully routed nets | 10,576 | 10,490 | -86 |

Routing completed with zero routing errors and zero unrouted nets. The direct
`input_mem_q -> product_sum_d` audit reports `No timing paths found`; the
corresponding prefetch path is `input_mem_q -> operand_d`, with worst setup
slack +0.456 ns and 7.489 ns data delay. The registered
`operand_q -> product_sum_d` path is the new local limiting cone, with worst
setup slack -0.647 ns and 8.625 ns data delay. The registered
`product_sum_q -> acc_d` path is +3.043 ns. Weight RAM outputs are captured in
the same `ST_OPERAND` valid stage; Vivado exposes those LUTRAM outputs as
`DOA..DOD` data pins rather than clocked launch pins, so the direct weight
source query has no timing startpoint, while the registered operand cone is
fully reported.

The candidate materially improves the isolated setup summary, but WNS remains
negative and this is not timing closure. No complete top-level route was run.

