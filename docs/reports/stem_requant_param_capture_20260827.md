# Stem channel-local requant parameter capture

Date: 2026-08-27  
Device: `xc7z020clg400-1`, Vivado 2025.2, 8 ns clock

## Candidate

`rtl/cnn/conv3x3_stem_engine_new.v` now captures the channel-indexed
multiplier and shift in `ST_RQ_SUM`. `ST_RQ_PRODUCT` multiplies the registered
`rq_sum_reg` by `rq_multiplier_reg`, so `channel_idx` no longer selects the
distributed multiplier RAM in the cycle writing the wide DSP product. The
requantization arithmetic, signed-64 product, Q31 away-from-zero rounding,
post-shift, zero-point offset, int8 saturation, activation clamp, ordering,
ready/busy semantics, and image dimensions are unchanged. This adds no state
or cycle beyond the existing `ST_RQ_SUM` stage.

The stem cursor split had an accidental second `state <= ST_MAC` assignment
after the cursor update; removing that assignment is required for
`ST_OPERAND` to execute on every tap and preserves the intended non-zero MAC
behavior. It does not add a cycle relative to the intended cursor-split
implementation.

## Functional evidence

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_addr_split` | PASS, 16 writes, 354 cycles |
| `tb_conv3x3_stem_engine_new_requant` | PASS, 16 writes, 354 cycles |
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |
| `tb_cnn_top_backpressure` | PASS, 768 checks |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, 10/10 checks, 1,089,117 cycles |

Commands:

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_addr_split
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_conv3x3_stem_engine_new_requant
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_cnn_top_tiled_stem_datapath
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_cnn_top_sram_stem_dsblock_datapath
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_cnn_top_backpressure
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath
```

## Fresh isolated OOC evidence

The reproducible flow is `scripts/vivado_stem_requant_param_capture_20260827.tcl`.
The post-route DCP and reports are under
`build/reports/vivado_stem_requant_param_capture_20260827/`. The comparison
is the immediately preceding same-flow cursor-split OOC run in
`build/reports/vivado_stem_addr_cursor_split_20260827/`, before parameter
capture.

| Metric | Cursor split | Parameter capture | Delta |
| --- | ---: | ---: | ---: |
| WNS | -6.520 ns | -4.787 ns | +1.733 ns |
| TNS | -3986.121 ns | -3538.646 ns | +447.475 ns |
| WHS | +0.131 ns | +0.113 ns | -0.018 ns |
| THS | 0 | 0 | 0 |
| Slice LUTs | 11,085 | 11,192 | +107 |
| Slice registers | 2,873 | 2,908 | +35 |
| DSPs | 10 | 10 | 0 |
| Fully routed nets | 10,301 | 10,576 | +275 |

Both runs completed routing with zero routing errors/unrouted nets. The prior
worst path was `channel_idx_reg[2]_replica/C` to
`rq_product_reg_reg__0/C[2]`, 12.735 ns data delay (8.112 ns logic,
4.623 ns route). The candidate's dynamic post-route audit
(`scripts/inspect_stem_requant_param_dcp_20260827.tcl`) found no timing path
from `channel_idx_reg[*]/Q` to `rq_product_reg_reg__0/C[*]`. The new isolated
worst path is `input_mem_reg[211][6]/C` to `product_sum_reg_reg[17]/D`,
12.765 ns (4.817 ns logic, 7.948 ns route), WNS -4.787 ns. Thus the target
channel-index-to-requant-product cone was actually removed, while overall
8 ns OOC setup remains negative and is not timing closure.

No complete `cnn_top` route was run for this local candidate.

## Complete top-level integration run

After the local gate passed, a fresh serial top-level Explore run was executed
with the current worktree:

```text
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
```

Run directory:
`build/reports/vivado_cnn_top_impl/runs/20260827T033637249-33380/`.
The design routed with zero routing errors, but the wrapper correctly reported
`FAILED_TIMING_CLOSURE`.

| Metric | Previous Stem-cursor top | Parameter capture top | Delta |
| --- | ---: | ---: | ---: |
| WNS | -5.037 ns | -4.612 ns | +0.425 ns |
| TNS | -11991.382 ns | -11521.474 ns | +469.908 ns |
| WHS | +0.096 ns | +0.089 ns | -0.007 ns |
| THS | 0 | 0 | 0 |
| Slice LUTs | 33,251 | 33,738 | +487 |
| Slice registers | 35,101 | 35,150 | +49 |
| BRAM tiles | 48 | 48 | 0 |
| DSPs | 69 | 69 | 0 |
| Total on-chip power | 0.254 W | 0.248 W | -0.006 W |
| Fully routed nets | 61,698 | 62,346 | +648 |

The current top-level first-20 setup paths are grouped as follows:

| Family | Ranks | Slack range |
| --- | --- | ---: |
| `stride_reg -> tiled_input_index_next` | 1, 10, 18 | -4.612 to -4.385 ns |
| `tile_h_start_reg -> tiled_store_addr_current` | 2, 4-6, 8-9, 12-13, 15-17, 20 | -4.608 to -4.173 ns |
| `store_idx_reg -> u_out_buffer/.../ENBWREN` | 3, 7, 11, 14 | -4.575 to -4.353 ns |
| `stride_reg -> aux_cfg_index` | 19 | -4.218 ns |

The output-buffer chain is therefore still present at ranks 3/7/11/14; its
worst path is `store_idx_reg[2]/C -> ...mem_reg_3/ENBWREN`, 14.048 ns data
delay (7.010 ns logic, 7.038 ns route). The tile-store address family is
closer to the top at rank 2, with 14.633 ns data delay.

Neither `u_stem_engine`, `input_mem`, `product_sum`, nor `rq_product` occurs in
the top-level first-20 report. A post-route 200-path audit under
`.../audit_8x4/` also found no Stem path in its 200 paths. The new local
`input_mem -> product_sum` path is consequently not the top-level dominant
cone; top-level dominance remains runner address/control and output-buffer
write-enable logic. Negative WNS remains and must not be described as closure.
