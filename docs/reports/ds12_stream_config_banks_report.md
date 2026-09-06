# DS12 packed dual-config-bank loader

`rtl/cnn/ds12_stream_config_banks.v` is an isolated loader for the real
packed DS1/DS2 configuration streams.  It does not modify `cnn_top`,
`cnn_layer_runner`, or any existing endpoint.

## Contract

- DS1 accepts exactly 308 32-bit words; DS2 accepts exactly 872 words.
- A request is a 32-bit aligned read with all four byte lanes enabled.
- An arbitrary-delay external memory response is matched to its source word
  index through a 1024-entry outstanding-request FIFO.
- Writes go only to `~active_bank`; commit occurs on the final response after
  request FIFO drain.  Layer, epoch, bank owner, and valid become visible on
  that same commit edge.
- Each bank is synchronously readable after commit.  `received_count` and a
  reflected CRC-32 (`0xedb88320`, final XOR `0xffffffff`) are observable.
- Sticky error codes cover stale epoch, invalid/overrun count, early commit,
  invalid bank/address read, spurious response, index failure, and bad layer.

## Verification

Run `scripts/run_ds12_stream_config_banks_sim.sh`.  The script regenerates the
packed words from the checked-in C0 export, then runs the standalone Verilator
TB.  The TB checks every config word, every packed weight byte/lane, atomic
bank metadata, stale/overrun/early-commit/read-invalid cases, random
ready/delay, and the no-backpressure one-word-per-cycle issue rate.  It also
asserts exactly `308 + 872 = 1180` accepted requests/responses and checks DS2
completion within the modeled DS1 runtime window.

This is a loader/contract result only; it is not evidence of full-top timing,
datapath integration, or hardware closure.

The deterministic Verilator run observed DS1 commit at cycle 311 and DS2
commit at cycle 1961 (earliest/latest in this two-load run), with 1180 accepted
requests and 1180 responses.  The ideal-ready DS1 phase sustained one accepted
word per cycle; the DS2 phase used the randomized ready/delay memory model.
