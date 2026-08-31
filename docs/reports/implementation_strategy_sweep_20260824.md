# Vivado implementation strategy sweep (2026-08-24)

This is a physical-flow comparison only: RTL, part (`xc7z020clg400-1`),
clock constraint, and out-of-context top were held constant. Vivado 2025.2
was used with post-route timing and route/hold checks.

| directive | WNS (ns) | TNS (ns) | WHS (ns) | setup failing endpoints | result |
| --- | ---: | ---: | ---: | ---: | --- |
| RuntimeOptimized | -7.788 | -32076.885 | 0.028 | 13767 | routed, setup fails |
| Explore | -7.376 | -27930.100 | 0.028 | 13767 | routed, setup fails |

The controlled baseline supplied for this sweep was WNS `-7.768 ns`, TNS
`-28665.969 ns`. Thus `Explore` improves WNS by `0.392 ns` and TNS by
`735.869 ns` versus that baseline, while preserving positive hold slack and a
fully routed result. It is the selected implementation directive. The runner
already defaults to `Explore`, so no RTL or constraint change is required.

The critical endpoint moved with the physical strategy. RuntimeOptimized's
worst path was `u_layer_runner/u_fc_unit/class_idx_reg[1]/C` to
`u_layer_runner/u_fc_unit/product_reg_reg/C[0]`, with 16.003 ns data delay and
14 logic levels. Explore's worst path moved to
`u_layer_runner/u_ds_block_engine/rq_scan_idx_reg[0]_rep__1/C` to
`u_layer_runner/u_ds_block_engine/u_pw_requant/product_s1_reg__0/C[1]`, with
15.591 ns data delay and 10 logic levels (6.161 ns routed, 9.430 ns logic).

Evidence is retained under
`build/reports/vivado_cnn_top_impl/runs/20260824T141831723-21380/` for
`Explore`; the RuntimeOptimized comparison is under the latest 2025.2 run
directory recorded in its manifest. Neither flow closes setup timing, so the
next structural target is the new DS-block/pw-requant critical cone rather
than another unbounded directive sweep.
