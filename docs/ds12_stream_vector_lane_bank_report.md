# DS12 stream vector lane bank

`rtl/cnn/ds12_stream_vector_lane_bank.v` is a minimal independent 32 KiB
activation store: sixteen explicit 8-bit memories, each with 2,048 line
addresses.  32-bit little-endian writes use aligned byte addresses and four
byte enables; `addr[3:2]` selects the four lanes within a 16-byte line.

The vector request accepts 16-byte aligned addresses and returns a registered
128-bit response (`lane0` in bits `[7:0]`).  The one-entry response register
supports arbitrary ready stalls and sustains one request/response per cycle
when ready is high.  A simultaneous read and write of the same line is
explicitly READ_FIRST; independent lines may be accessed in the same cycle.
Invalid alignment and range requests handshake without touching memory and
set sticky `error`/`error_code` bits.

## Inference-preserving implementation

Each of the sixteen byte arrays now has a fixed conditional write port and an
explicit registered read assignment.  The aligned word offset (`addr[3:2]`)
selects one of four fixed groups of four lane enables; the line row address is
the only variable memory index.  This removes the variable lane `case` in the
write path and the dynamic lane-selection function in the read path, leaving
Vivado with sixteen ordinary synchronous byte-wide RAM templates.  The reads
and writes remain in the same clocked process, so nonblocking RHS evaluation
continues to provide READ_FIRST behavior for same-line collisions.

Run the self-check with:

```text
./scripts/run_ds12_stream_vector_lane_bank_sim.sh
```

The test writes all 8,192 DS1 words continuously, applies randomized partial
byte-enable writes, checks randomized vectors under response backpressure,
checks same-line READ_FIRST and different-line read/write overlap, and proves
4,608 vector reads within the one-per-cycle pipeline bound.  The simulator
emits `PASS ds12_stream_vector_lane_bank` and saves its log below
`build/ds12_stream_vector_lane_bank/`.

Validation on 2026-09-05:

```text
PASS ds12_stream_vector_lane_bank DS1_words=8192 DS1_write_cycles=8192 random_reads=1202 throughput_reads=4608 throughput_cycles=4610 capacity=32KiB read_first=1
PURE_TWO_LAYER_REAL_PASS start_to_done=22978 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576 mismatches=0 errors=0
PURE_TWO_LAYER_REAL_PASS start_to_done=35693 cfg=1180 out1=8192 out2=4096 dw=221184 pw=1048576 mismatches=0 errors=0
```

The final two lines are respectively the normal and `TB_RANDOM_BP` runs;
both use the real two-layer configuration/output checks and report zero
mismatches and errors.
