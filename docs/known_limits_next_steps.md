# Known Limits and Next Optimizations

## Current Status

- `ds_block_tile_engine_new` is the active DS path in `cnn_layer_runner`.
- The new path uses XPM-backed input, PW-weight, and DW-tile buffers.
- Stem, GAP, and FC now use scalar configuration loaders and sequential compute
  instead of runner-owned packed payload vectors.
- Feature SRAM uses an XPM BRAM implementation under synthesis with an explicit
  same-address write/read bypass.
- The descriptor format, firmware address map, external word-per-int8 test
  layout, and golden vectors are unchanged.
- The Windows XSim critical regression passes 13/13 tests, including tiled,
  SRAM, multilayer, end-to-end, and full-network paths.
- `ds_block_tile_engine_new` OOC synthesis passes at 24281 CLB LUT, 15649 FF,
  26 BRAM36 tiles, and 14 DSPs.

## Evidence Boundary

- The post-refactor full `cnn_top` OOC synthesis completed on 2026-07-17 with
  0 errors and 0 critical warnings.
- Standard utilization is 45830 CLB LUT (39.13%), 18387 CLB registers (7.85%),
  42 RAMB36 tiles (29.17%), and 60 DSP blocks (4.81%).
- Hierarchical utilization shows `cnn_layer_runner` at 44503 total LUT,
  including `ds_block_tile_engine_new` at 24283 LUT and `cnn_out_buffer` at
  3398 LUT. The runner's own non-child logic is 14812 LUT, down from the
  333191 logic LUT intermediate result.
- `feature_sram_pingpong` maps to 16 RAMB36 with only 67 LUT, confirming that
  the XPM BRAM conversion is active.
- The earlier 446272-LUT result remains useful only as evidence of why the
  legacy packed stem/GAP/FC loaders had to be removed; it is not the current
  resource count.
- The installed K26 part reports `Cannot run timing on a non-timing device`.
  Current reports are synthesis utilization only, not place-and-route timing
  closure.

## Remaining Limits

- The accelerator is fixed around EdgeDSCNet-C10 shapes; it is not a general
  CNN/NPU ISA.
- External memory still uses a simulation-friendly word-per-int8 layout rather
  than packed NHWC bytes and burst transfers.
- `cnn_out_buffer` is still asynchronous distributed RAM. It should be moved to
  synchronous BRAM only together with an explicit read-prefetch state.
- The DW 16-lane and PW 8x8 int8 multipliers are mainly LUT/CARRY arithmetic;
  DSP-vs-LUT mapping has not been tuned against a routed timing target.
- The single-MAC stem is area-oriented. Its throughput should be increased to
  3 or 9 MAC lanes only if full-network profiling shows it is material.
- Requant is bit-exact with the Python golden but uses wide multiplication.
  Sharing, width reduction, or deeper pipelining still needs timing evidence.
- There is no formal verification or broad constrained-random backpressure
  suite.
- NPC/custom-instruction simulation exists, but there is no production AXI SoC
  top, CDC plan, board constraints, or bitstream bring-up.
- Model accuracy remains a functional-validation checkpoint, not the final ML
  quality target.

## Next Actions

1. Run implementation on a timing-capable device/part installation and collect
   WNS, Fmax, congestion, power, and routed utilization.
2. Redesign `cnn_out_buffer` as synchronous BRAM plus an explicit prefetch
   state; the current asynchronous version costs 3398 LUT.
3. Profile real layer cycles and scale stem/DW/PW parallelism only where useful.
4. Convert external payloads to packed NHWC byte addressing and an aligned
   burst-friendly loader.
5. Add random memory stalls, cfg legality assertions, and tile-boundary stress.
6. Re-run CPU/NPC full-network regression with the new engines.
7. Integrate a production memory bus/SoC top and board-level debug.
8. Train/calibrate a stronger PTQ or QAT checkpoint and regenerate firmware.

See `streaming_engine_refactor_guide.md` for the architecture, exact commands,
cycle/resource data, and a step-by-step reproduction path.
