# Depthwise 3x3 window-reuse scheduler prototype (2026-08-29)

This is a non-production feasibility block for the next DS dataflow.  It owns a
single `ds_input_tile_buffer_bram` 128-bit synchronous vector-read port and
fronts a sixteen-lane direct DW MAC.  For one 8x8 output tile and one
16-channel tile, the scheduler reads the 10x10 footprint once (100 vector
reads), stores complete vectors in a tile-local distributed RAM, and emits the
9 ordered tap tokens for each of the 64 outputs (576 compute tokens).  Padding
is represented by zero vectors in the footprint.  The parameterized address
function also supports `STRIDE=2` (17x17/289 reads), although the measured
OOC gate below is the stride-1 configuration.

## Functional evidence

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_dw_window_reuse_scheduler_sim.sh'
```

Verilator 5.020 passed four exact signed-int8 cases with periodic output
backpressure:

| case | channel tile | active lanes | reads | DW tokens | outputs | latency (cycles) |
|---:|---:|---:|---:|---:|---:|---:|
| 0 (Stem-like tail) | 0 | 3 | 100 | 576 | 64 | 755 |
| 1 (DS full) | 0 | 16 | 100 | 576 | 64 | 755 |
| 2 (DS-48 tile 1) | 1 | 16 | 100 | 576 | 64 | 755 |
| 3 (DS-48 tile 2 tail) | 2 | 5 | 100 | 576 | 64 | 755 |

The reference includes explicit top/left/right/bottom zero padding and all
active lanes are compared for every output.  The test also verifies output
pixel order, lane masks, exact read/token counters, and output stability while
`ready_out` is periodically deasserted.  No wide-buffer reread occurs during
the 576-token phase.

## 8 ns XC7Z020 OOC post-route

Command:

```text
vivado.bat -mode batch -source scripts/vivado_dw_window_reuse_scheduler_ooc_20260829.tcl
```

Configuration is Vivado 2025.2, `xc7z020clg400-1`, 8.000 ns clock,
`general.maxThreads=2`, out-of-context synth/place/route.  The final reports
are under `build/reports/vivado_dw_window_reuse_scheduler_ooc_20260829/`.

- WNS +0.529 ns; 0 setup failing endpoints; TNS 0.
- WHS +0.123 ns; 0 hold failing endpoints; THS 0.
- Route status: 0 routing errors, 0 unrouted nets.
- Slice LUTs 1,786 (3.36%); slice registers 5,370 (5.05%).
- DSP48E1 16 (7.27%); Block RAM tiles 16 (11.43%).
- Estimated total on-chip power 0.194 W.

The decisive physical changes were packed vector local storage inferred as
distributed RAM, registered local-store address/data prefetch, and a separate
producer-side registered weight prefetch.  The latter removes the direct
tap-index-to-weight-memory mux from the critical path.  The remaining worst
path is a registered tap-address to prefetched weight vector path; its slack
is +0.529 ns at the 8 ns gate.

## Projection and boundary

This prototype is a valid storage-bandwidth/dataflow primitive, not a complete
network implementation.  One instance emits one token per cycle only after a
100-read fill and still takes about 755 cycles per 8x8/Ctile transaction under
the exercised stalls.  A simple MAC-equivalent floor for the complete network
would therefore be several hundred thousand cycles with one instance; a
credible <=150k projection requires later ping-pong DMA and multiple
independently scheduled/placed DW consumers (plus PW and stem accounting).
The design demonstrates that the planned 100-read footprint and registered
window supply can meet the physical gate, but it does not by itself establish
the <=2.0M full-network result, 20 GOPS/W, or full-top post-route closure.

No production runner or `cnn_top` source was modified or integrated by this
prototype, and no full-top implementation was run.
