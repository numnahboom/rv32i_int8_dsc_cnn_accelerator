# EdgeMBConv HW candidate D4 composite timing repair v5

This is an independent D4 hardware-aware candidate artifact. C0, the D4
network definition, training outputs, and legacy RTL are unchanged.

## RTL changes

- `u_dw16` now captures tap data, tap index, end-of-tap metadata, and the
  current weight before the DSP input. A shifted nine-tap weight schedule
  removes the dynamic `tap_idx` weight mux from the DSP endpoint.
- Source requests use a registered descriptor (address, in-bounds decision,
  and tap index). The 3x3 in-bounds mask and address table are built once from
  the registered start coordinates. Halo events use a one-entry
  `pad_pending` decision, cleared when consumed, so an out-of-bounds tap
  cannot be emitted twice. In-bound requests remain one per source handshake.
- `u_pool` splits the exact RQ saturation path into a registered native-int8
  clamp candidate and a registered activation min/max clamp. Candidate,
  metadata, and configured bounds remain transaction-aligned.
- The 112-lane PW island uses lane-local kept operand/tag/valid registers to
  prevent control fanout from becoming an accumulator or DSP timing path.
- The composite output boundary now fences RQ acceptance while `u_pool` is
  presenting the result that is being copied into the common output register.
  This is a one-cycle transaction-lifetime guard only; it changes no arithmetic
  or quantization operation and does not add a DSP island.

No arithmetic, precision, output format, or DSP count was reduced.

## Functional validation

Vivado 2025.2 XSim:

```text
PASS edgembconv_hwacandidate_d4_composite_datapath mapping=112PW+16dual+18DW stalls=checked
```

The testbench checks all 128 PW lanes, five exact RQ vectors through the
split saturation pipeline, DW stride 1 and 2, center and corner SAME-padding
windows, registered source responses, source stalls, output stalls, metadata,
and output stability. Measured DW transaction cycles were 43 (stride-1
center), 44 (stride-2 center), and 28 for both corner cases. The independent
D4 pool regression also passed: 3 PW records and 5 RQ records with random
backpressure.

## Fresh XC7Z020 post-route OOC screen

Command: `scripts/run_edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v5_threads8_20260902.ps1`

Device `xc7z020clg400-1`, 8.000 ns clock (125 MHz), Vivado
`general.maxThreads=8`, `place_design -directive Explore`,
`phys_opt_design -directive Explore`, and `route_design -directive Explore`.

| metric | post-route result |
|---|---:|
| WNS | +0.633 ns |
| WHS | +0.096 ns |
| TNS / THS | 0 / 0 ns |
| LUT as Logic | 18,461 / 53,200 (34.70%) |
| FF | 23,264 / 106,400 (21.86%) |
| BRAM | 0% |
| DSP | 146 / 220 (66.36%) |
| Total on-chip power | 0.525 W |
| routing errors | 0 |

The exact DSP hierarchy count is 112 dedicated PW + 16 shared-pool + 16 DW
channel + 2 DW scheduler = 146, recorded in
`build/reports/vivado_edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v5_threads8_20260902/run_settings.txt`.
The authoritative timing, utilization, power, route, DRC, and max/min path
reports are in that same directory.

This remains a local physical composition screen, not full-top closure or a
full-network latency/energy claim.

After the RQ boundary guard was added, the standalone composite regression
was rerun and passed again.  The complete real-vector `mb16_down` controller
gate also passed 8,192/8,192 output bytes under randomized scratch-read and
output backpressure (`PW=786432`, `DW=73728`, `protocol_errors=0`).

The post-route numbers above are the existing v5 OOC screen.  The
function-only RQ guard was not presented as a newly rerun OOC result; a later
implementation slice must rerun OOC/post-route if this guarded RTL is selected
for physical closure.
