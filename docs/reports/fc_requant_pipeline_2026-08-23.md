# FC requant pipeline improvement

## Change

`fc_unit_new` now drives the shared product through `requant_product_pipeline`,
a five-stage, one-result-per-cycle pipeline modeled on the existing activation
pipeline. The class tag is delayed with the data, and the FC drain is extended
to cover the pipeline latency. Arithmetic remains Q31 half-away-from-zero,
post-multiply shift, zero-point addition, int8 saturation, then activation
clamp.

## Verification

- `tb_requant_product_pipeline`: PASS, 12 vectors including zero, positive and
  negative products, extrema, shifts, clamp and ordered tags.
- Existing `tb_requant_activation_pipeline`: PASS, 100 vectors.
- `GENERATE_TEST_VECTORS=0 SIM_RESUME=1 ./scripts/run_all_sims.sh`: PASS, all
  selected 41 simulations (reused PASS markers where unchanged).

## Routed STA

Fresh Vivado 2025.2 routed OOC run completed with a unique run directory:

`build/reports/vivado_cnn_top_impl/runs/20260823T211510240-24108/`

The wrapper returned `FAILED_TIMING_CLOSURE` because setup is still negative,
but implementation and routing completed successfully. Route status is
46,846/46,846 routable nets fully routed with zero routing errors. The clock
summary is:

| Metric | Result |
|---|---:|
| WNS | -8.900 ns |
| TNS | -36,509.522 ns |
| Setup failing endpoints | 12,775 |
| WHS | +0.077 ns |
| THS | 0.000 ns |
| Hold failing endpoints | 0 |

Against the pre-change baseline (WNS -9.761 ns, TNS -38,841.840 ns), WNS
improved by 0.861 ns and TNS by 2,332.318 ns. The worst path is now the
independent loader cone `stride_reg -> mem_req_addr_reg[22]` (-8.900 ns,
18.897 ns data delay, 23 logic levels); the prior FC
`product_reg -> requant_reg` path is no longer the top path. The run has zero
unconstrained internal endpoints, with expected missing I/O delays in OOC.
