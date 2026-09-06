# DS1 16-lane DW stream endpoint candidate

`rtl/cnn/ds12_stream_ds1_dw_endpoint.v` is an isolated DS1 depthwise-only
candidate. It is not included by `cnn_top`, `cnn_layer_runner`, or any
`ds1_retained*` module.

The endpoint accepts the first 84 DS1 packed configuration words from the
DS12 harness, reads the real 32x32x16 DS1 feature image through a 128-bit
pixel memory transaction, and emits one 128-bit (16-channel) vector per
pixel. Output tags are row, linear pixel, four-context tag, owner, epoch, and
last. The private feature store makes one outstanding request explicit while
accepting a fixed one-cycle or delayed response. SAME padding is zero (the
real DS1 input zero point), and four rotating context slots are fenced by
owner/epoch checks. Requantization is Q31 half-away-from-zero, post-shift,
INT8 saturation, then the C0 DS1 0..127 activation clamp; four channels are
requantized per cycle.

## Reproduction

```text
bash scripts/run_ds12_stream_ds1_dw_endpoint_sim.sh
```

This regenerates the real C0 harness and runs
`sim/tb_ds12_stream_ds1_dw_endpoint.v`. The TB compares all 16,384 DW output
bytes against the independent Python reference and also checks stable output
payload/tags under randomized output backpressure and randomized response
delay.

## Observed evidence

```text
DS12_DW_CASE_PASS response_mode=0 ready_mode=0 cycles=9217 vectors=1024 reads=1024 padding=380 mac=147456 context_peak=4
DS12_DW_CASE_PASS response_mode=1 ready_mode=1 cycles=12058 vectors=1024 reads=1024 padding=380 mac=147456 context_peak=4
DS12_DW_ENDPOINT_PASS bit_exact=1 backpressure=1 same_padding=1 response_delay=stable
```

The no-backpressure run is below the 10,000-cycle DS1 DW gate. The MAC ledger
is exactly `32*32*16*9 = 147456`; padding is counted as 380 spatial taps and
input traffic as 1024 complete-pixel reads. This is candidate-level RTL and
simulation evidence only; it is not OOC, timing, resource, power, or full-top
closure evidence.
