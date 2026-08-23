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

Vivado routed timing was not run in this worker, so WNS/TNS improvement is not
claimed. Baseline for comparison remains WNS -9.761 ns, TNS -38841.840 ns;
the loader address-generation cone remains a separate bottleneck.
