# D4 vstream elastic RQ pool

## Scope

This is an independent hardware-aware D4 RQ streaming candidate. It does not
modify the existing C0, D4 composite, training, RTL, checkpoint, or report
artifacts. The datapath keeps the established 16-DSP mapping: four signed or
unsigned 16-bit partial products per each of four INT32 RQ lanes. The partial
products are followed by registered pair sums, product, magnitude, rounding,
shift, sign restoration, zero-point addition, and clamp stages. Transaction
metadata and all RQ context travel with the elastic valid/ready pipeline.

The input side uses a one-entry pending context to align the DSP48E1 PREG's
one-cycle latency. The ready path is fully propagated from the output, so a
blocked output freezes every occupied stage and preserves the transaction.

## Verification evidence

Command:

```text
bash scripts/run_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_sim.sh
```

The testbench consumes the real D4 RQ vectors exported under
`build/edgembconv_hwacandidate_d4_dsp_pool_vectors/` and checks product,
requantized result, and metadata in order.

- No-output-stall burst: 16 accepted transactions, first acceptance cycle 4,
  last acceptance cycle 19; therefore input II = 1.
- Random independent input/output backpressure: 32 additional transactions;
  all 48 transactions were accepted and produced with no mismatch, duplicate,
  loss, movement while stalled, or unexpected output.
- Final simulation result: `PASS ... dsp_count=16 contiguous_ii=1
  random_backpressure=checked transactions=48`.

## Boundary and remaining work

This is functional RTL simulation evidence only. No Vivado OOC synthesis,
post-route timing, full-network integration, cycle-model comparison, or
hardware measurement has been run for this independent vstream wrapper.
