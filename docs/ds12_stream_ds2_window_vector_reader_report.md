# DS12 DS2 vector-window reader candidate

`rtl/cnn/ds12_stream_ds2_window_vector_reader.v` is an isolated candidate
adapter for `ds12_stream_dual_vector_activation_store`. It keeps four tagged
contexts and emits each output window in tap-major order (`3x3`, then channel
slices `0` and `1`). A valid in-range tap issues exactly one 16-byte request
and consumes the store's registered 128-bit response. SAME padding emits a
zero vector without a store request. The reader checks response bank, epoch,
and address tags and holds all output metadata/data under `ready/valid`
backpressure.

The candidate is not connected to `default`, `cnn_layer_runner`, `cnn_top`, or
any existing DS1 component. Its standalone proof is:

```text
./scripts/run_ds12_stream_ds2_window_vector_reader_sim.sh
```

The testbench writes the generated real DS1 activation (`32x32x32` signed
NHWC bytes) as 8,192 32-bit writes to store bank B, commits epoch `0x11`, and
then requests all `16x16` DS2 output windows. The no-backpressure raster
completes in 4,621 cycles from the first window start through the final vector
(limit 5,000), with 4,608 logical vectors and 4,418 physical in-range vector
requests. All 73,728 vector bytes, addresses, tags, ordering, and 190 padding
vectors pass. A follow-up randomized response/output stall run checks stable
held transactions, and an injected stale response epoch is detected.

The `read_count` ledger intentionally counts logical vectors (including
padding), while the testbench's physical request counter counts only store
handshakes. This makes the 4,608-vector DS2 contract explicit without issuing
illegal memory requests for padding.
