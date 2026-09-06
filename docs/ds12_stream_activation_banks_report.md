# DS12 stream activation banks

## Scope

`rtl/cnn/ds12_stream_activation_banks.v` is an independent two-bank,
32-bit-word activation store.  Each bank has 8,192 words (32 KiB); byte
addresses are aligned and byte enables select individual lanes.  The default
reset ownership is bank 0 `READ`, epoch 0 and bank 1 `FREE`.

The layer-start command claims a FREE bank and records epoch and expected byte
count.  Writes are accepted only for the active WRITE bank and matching epoch.
Each accepted write has a held one-entry response.  `write_last` closes the
command stream, and a commit fence checks last, exact byte count, matching
bank/epoch, and drained write response before atomically freeing the old READ
bank and marking the new bank `COMMITTED`; the new bank publishes as `READ` on
the following fence edge.  Reads have a registered one-cycle data, bank,
epoch, and address response held under backpressure.

## Self-check

Run from WSL/native Bash:

```text
./scripts/run_ds12_stream_activation_banks_sim.sh
```

The self-check uses DS1's 32x32x32-byte shape (8,192 continuous full-word
writes) and DS2's 16x16x64-byte shape (4,096 words plus partial byte-enable
writes).  It checks every stored byte, padding lanes, epochs, atomic swaps,
read/write bank exclusion, stale epochs, range errors, early commit, and
backpressured responses.  The run emits a `PASS ds12_stream_activation_banks`
line and stores the simulator log under `build/ds12_stream_activation_banks/`.

The DS1 write phase is designed for 8,192 handshakes in 8,192 cycles when
`write_resp_ready=1` (one word/cycle).  Capacity is 32 KiB per bank.
