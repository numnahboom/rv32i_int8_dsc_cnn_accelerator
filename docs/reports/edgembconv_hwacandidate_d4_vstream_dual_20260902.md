# D4 vstream shared PW/RQ pool

## Contract

The vstream candidate now exposes one shared 16-DSP pool with a transaction
mode bit. In PW mode, all sixteen DSPs perform independent signed INT8 × INT8
products. In RQ mode, the same sixteen DSPs are grouped as four lanes of four
16-bit partial products to reconstruct signed INT32 × INT32 products before
the existing requantization sequence. No old pool is instantiated alongside
this datapath, and no additional DSP or LUT multiplier is used.

PW and RQ data, metadata, and mode tags share the elastic valid/ready
pipeline. Same-mode transactions can issue at II=1. `mode_active` and the
pending-slot retirement rule form a fence: a different mode is not accepted
while an old-mode token remains in the pending slot or any elastic stage. An
idle source may change the mode while the old token drains; the old output
continues to hold its mode and data under `ready_out=0`. The new mode is
accepted only after the pipeline is empty.

## Functional evidence

Commands:

```text
bash scripts/run_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_sim.sh
bash scripts/run_edgembconv_hwacandidate_d4_vstream_dual_sim.sh
```

Both tests use the real D4 vector export in
`build/edgembconv_hwacandidate_d4_dsp_pool_vectors/`.

- Existing RQ regression: 16-transaction no-stall burst accepted in cycles
  4..19 (II=1), plus 32 transactions under random output backpressure; all 48
  products, requantized results, and metadata passed in order.
- Dual-mode regression: 16 PW transactions in an unstalled burst (II=1),
  32 RQ and 32 PW transactions under random stalls, and explicit PW→RQ and
  RQ→PW changes while an output was held blocked. All PW products and RQ
  products/results passed with no mode-order, missing, duplicate, or unexpected
  output errors.
- Final result: `PASS edgembconv_hwacandidate_d4_vstream_dual dsp_count=16
  pw_ii=1 rq_ii=1 mode_fence=random_backpressure=checked`.

## Boundary

This milestone is functional RTL simulation only. OOC synthesis, post-route
timing, full-network integration, and a cycle-model comparison remain open.
