# DS12 dual vector activation store

`rtl/cnn/ds12_stream_dual_vector_activation_store.v` wraps exactly two
`ds12_stream_vector_lane_bank` instances.  Each physical instance contains
16 explicit 8-bit lane memories, 2,048 vector lines, and 32 KiB of storage;
the wrapper adds FREE/READ/WRITE/COMMITTED ownership, per-bank epoch tags,
word-count and `write_last` drain checks, and an atomic commit/swap fence.

The active READ bank serves registered 128-bit (16-byte) responses tagged with
bank, epoch, and address.  Writes to the opposite WRITE bank overlap reads in
the same cycle.  Responses are elastic under backpressure; a response consume
and replacement can occur on one edge.  Invalid starts, stale epochs,
out-of-range or unaligned accesses, early commit, and same-bank access are
sticky error cases matching `ds12_stream_activation_banks` error bits.

Run the standalone proof with:

```text
./scripts/run_ds12_stream_dual_vector_activation_store_sim.sh
```

The Verilator proof reports `PASS` with 8,192 DS1 writes in 8,192 cycles,
4,608 DS1 vector addresses checked during the opposite-bank DS2 write, a
16 KiB DS2 swap/readback, random response backpressure, and five invalid cases.

Physical estimate: 2 vector-bank instances, 2 × (16 × 2,048 × 8) = 524,288
storage bits total, or 16 nominal Xilinx BRAM18 primitives (8 per bank),
excluding control/register overhead and implementation-specific packing.
