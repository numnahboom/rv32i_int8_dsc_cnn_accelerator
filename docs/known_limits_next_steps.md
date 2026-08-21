# Known Limits and Next Optimizations

## Current Status

- `ds_block_tile_engine_new` remains the active DS path.  The runner now uses
  compact and tiled loader lookahead, and the PW BRAM path also pre-arms its
  next read.
- The Stem is a 3-MAC implementation; GAP and FC retain their sequential,
  load-time accumulation approach.
- `cnn_out_buffer` is synchronous and uses four BRAMs in the synthesis/XPM
  implementation.  Ordinary XSim and Verilator use its cycle-equivalent
  behavioral model; the XPM branch is checked through synthesis structure,
  not executed by those ordinary simulators.
- The fixed full-network SRAM datapath is freshly bit-exact for all 10 logits:
  `944568` cycles, status `0x0e69b882`, 5.438 MAC/cycle.  This is 194332
  cycles (17.06%) below the dated 1138900-cycle pre-lookahead baseline.
- The same 944568-cycle/status result is confirmed through the CPU harness.
  A three-sample CPU+RTL run is bit-exact with argmax values 3, 8, and 8;
  tracked vectors were not changed for that evidence.
- The fullnet transaction oracle reports 78602 payload external reads plus 288
  descriptor reads, 10 external writes, 115808 SRAM reads, and 102656 SRAM
  writes.  Bounds testing checks every SRAM address transaction-by-transaction.

## Evidence Boundary

- The tiled external-memory backpressure tests exercise one outstanding read,
  response delays of 0..3 idle cycles, ready stalls, payload stability and a
  write-sequence oracle.  Fresh Windows XSim recompiled 27 RTL files and
  passed all 16 selected TBs, including fullnet.
- A WSL Verilator 5.020 clean directed run passed tiled Stem (16384 checks),
  tiled DSBlock (2256 checks), and tile engine tail cases (7 / 2191).  The
  complete 38-test Verilator batch remains an explicit follow-up because the
  controller's one-command runtime limit interrupted a longer aggregation run;
  this is a coverage limitation, not a DUT failure.
- Fresh 2026-08-18 Vivado OOC synthesis for the current lookahead/output-buffer
  RTL passed with 30451 CLB LUT, 18558 CLB registers, 46 Block RAM tiles, and
  65 DSPs.  It also proves `cnn_out_buffer` is a 4-BRAM XPM structure (6 LUT
  at that hierarchy), rather than the earlier large LUTRAM.  These are current
  structural/resource figures, not timing-closure evidence.
- OOC synthesis is a structural/resource check.  Even after a fresh OOC PASS,
  it does not exercise board IO, routing congestion, clock uncertainty, WNS,
  Fmax, power, or timing closure.
- The installed K26 database is a non-timing device database.  It cannot
  produce WNS/Fmax or prove place-and-route timing closure even when synthesis
  or a non-timing implementation step succeeds.

## External Read Contract

- At most one external read may be outstanding.
- A request is accepted only on its ready/valid handshake.  Its response may
  be delayed arbitrarily, but must not arrive in that same handshake cycle;
  the earliest legal response is the following cycle.
- External writes have no response channel.  While a write is stalled, its
  `{write, address, data}` payload must remain stable.
- An AXI adapter or a combinational-RAM adapter must register its read
  response so that it obeys the above contract.

## Remaining Limits

- The accelerator is fixed around EdgeDSCNet-C10 shapes; it is not a general
  CNN/NPU ISA.
- External memory still uses a simulation-friendly word-per-int8 layout rather
  than packed NHWC bytes and burst transfers.
- DW/PW multiplier DSP-versus-LUT mapping has not been tuned against a routed
  timing target.  Requant also needs timing-driven width/pipeline decisions.
- There is no formal proof or broad constrained-random memory/CDC campaign.
- NPC/custom-instruction simulation exists, but there is no production AXI SoC
  top, CDC plan, board constraints, bitstream, or board bring-up evidence.

## Next Actions

1. Archive a complete 38-test Verilator batch in an environment without the
   controller command-time limit; retain its summary.csv with the XSim log.
2. Use a timing-capable target/device installation for implementation, then
   collect WNS, Fmax, congestion, power, and routed utilization.
3. Convert external payloads to packed NHWC byte addressing and a burst-aware
   memory adapter while preserving the registered response contract.
4. Add formal assertions/coverage for loader and memory protocol boundaries.
5. Integrate a production bus/SoC top and board-level debug path.
