# DS1 PW streaming consumer candidate

`rtl/cnn/ds12_stream_ds1_pw_consumer.v` is an isolated DS1 pointwise
consumer for the 16-lane tagged vectors emitted by
`ds12_stream_ds1_dw_endpoint`. It has no full-layer DW replay memory. Sixteen
bounded context slots retain at most 128 vectors (2 KiB of INT8 activation
storage); each slot is selected by context, owner, and epoch tags and accepts
pixel vectors in arbitrary order.

The compute tile is one 8-pixel x 8-Cout x 1-Cin 64-MAC transaction. K=0..7
and K=8..15 are continuous partial groups, with no intermediate
requantization. Four Cout groups produce 32 channels. Compute and the
backpressured 32-bit sink use separate context slots.

## Reproduction

```text
bash scripts/run_ds12_stream_ds1_pw_consumer_sim.sh
```

The TB uses the generated C0 DS1 DW and final-activation vectors, reads the
packed PW configuration transaction ledger, permutes context and pixel
arrival order, inserts configuration response delay and configuration ready
stalls, and randomizes sink ready. It checks output bytes, sink addresses and
owner/epoch/context tags, output stability under stall, and all ledgers.

## Observed evidence

```text
DS12_PW_PASS byteexact=1 cfg_reads=224 weight_reads=128 dw_vectors=1024 pw_tokens=8192 mac=524288 output_words=8192 partial_context_peak=16 span=1959
```

The span is measured from the first accepted DW vector to the final accepted
output word in this randomized run. This is RTL/simulation candidate evidence
only; no OOC, timing, resource, power, or full-top closure is claimed.
