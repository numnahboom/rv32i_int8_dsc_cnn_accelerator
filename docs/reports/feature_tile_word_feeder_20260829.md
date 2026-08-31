# Native-word feature tile feeder feasibility (2026-08-29)

## Result

The reusable `feature_tile_word_feeder` is functionally viable, but this
candidate is **not** a production/full-top integration candidate. The
throughput-preserving registered response-command repair improved the 8 ns
XC7Z020 OOC post-route screen from WNS +0.008 ns to +0.582 ns, clearing the
+0.5 ns feasibility gate. No full-top run was started.

## ABI and behavior

`fill_start` captures `{bank,tile_id,epoch,base_byte_addr,row_stride,tile_h,
tile_w,channels,row_valid_mask,col_valid_mask,pad}`.  The feeder issues aligned
32-bit native word requests and aligns each fixed-latency response through a
registered token pipe.  Four independent byte-lane XPM memories per bank
allow all response bytes to be written once per cycle, including unaligned
source addresses.  A bank becomes READY only after all responses and an
edge-mask scrub; `activate` switches the active bank and `release` returns the
old bank to FREE.  The consumer receives an ordered, one-cycle synchronous
byte stream with an elastic response register.

## Functional evidence

`scripts/run_feature_tile_word_feeder_sim.sh` passed Verilator 5.020 with
5,132 ordered byte checks:

* first-Stem shape: 10x10x3, base byte address 3, row stride 37;
* DS traffic shape: 10x10x48, base byte address 1003, row stride 64;
* unaligned native words, two-bank switch/release, invalid final row and two
  invalid columns (pad 0x80), request bubbles, and fill/consume overlap;
* 1,294 native-word responses matched 1,294 accepted requests.  The DS fill
  issued 1,211 words while the active bank was being consumed; total simulation
  length was 21,697 cycles.

The testbench uses a registered one-cycle SRAM response model; no response is
fabricated from the request-valid signal.  Consumer readiness is deliberately
removed through the response presentation cycle on a periodic subset; all
5,132 tags/data remain ordered.  The exported full-cycle stall counter is 0
because the bench releases readiness before the following sampling edge; a
future stress bench should hold it for a complete edge to measure sustained
stall occupancy.

## Physical evidence

The final repaired OOC run is
`build/reports/vivado_feature_tile_word_feeder_ooc_20260829/` using Vivado
2025.2, xc7z020clg400-1, 8 ns clock, two XPM banks (8 KiB each in the realistic
wrapper), placement, phys-opt, and routing:

* setup WNS +0.582 ns, TNS 0, 0 failing endpoints;
* hold WHS +0.108 ns, THS 0;
* route errors 0 and no DRC violations;
* 636 LUTs (1.20%), 709 FFs (0.67%), 4 BRAM tiles (2.86%), 0 DSP;
* vectorless total on-chip power 0.124 W.

The +0.5 ns feasibility gate is met for this OOC block. The repair uses a packed
registered four-lane response command (rotated byte mask/data and a two-word
address vector), followed by the existing lane-memory write register; it
retains one native response per cycle and avoids the former wide variable
destination decode. The remaining limiting path is the row-word index to row
counter CE (6.925 ns data delay: 3.117 ns logic and 3.808 ns routing), leaving
0.582 ns setup margin. This OOC result is not a full-top timing closure result.
Vivado synthesis still emits the pre-existing multi-driver warning on
`scrub_needed_reg` from its split reset/capture processes; this must be cleaned
before treating the feeder as production RTL.
