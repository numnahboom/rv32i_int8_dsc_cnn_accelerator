# cnn_layer_runner unified64 DS integration (2026-08-31)

This is an isolated compile-time integration proof.  The production default
`USE_UNIFIED64_DS=0` is unchanged; the testbench instantiates
`cnn_layer_runner #(.USE_UNIFIED64_DS(1))` and feeds the existing externally
addressed `cnn_top_dsblock_cases.hex` vectors directly to the runner.

## Reproduction

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_cnn_layer_runner_unified64_ds_sim.sh"
```

The memory model returns every accepted read one cycle later and checks every
output write address and byte against the generated golden vector.  The
vector's descriptor entries are not counted as runner traffic; the expected
read count is therefore `entry_count - 32`.

## Verilator result

```text
RESULT case=0 cycles=5651 reads=984 writes=512 expected_writes=512 nonzero=64 error=0
RESULT case=1 cycles=5166 reads=1792 writes=256 expected_writes=256 nonzero=32 error=0
PASS tb_cnn_layer_runner_unified64_ds cases=2
```

Case 0 is DS1-shaped (`10x10x8 -> 8x8x8`, stride 1); case 1 exercises a
stride-2/tail-compatible (`9x9x16 -> 4x4x16`) transaction.  Thus the result
checks the real runner load phases, DS DW computation, unified64 PW output
commit into `cnn_out_buffer`, and subsequent external scalar output writes.
All expected output bytes are compared in order; nonzero output counts prove
the check did not pass only through zero initialization.

The actual tiled runner envelope was then checked with
`tests/vectors/cnn_top_tiled_dsblock_cases.hex` (external input reads,
descriptor-controlled tile loading, DW, unified64 PW commit, tiled output
addressing, and external writes):

```text
RESULT tiled case=0 cycles=12172 reads=1528 writes=960 expected_writes=960 nonzero=720 error=0
RESULT tiled case=1 cycles=16581 reads=2864 writes=1296 expected_writes=1296 nonzero=1134 error=0
PASS tb_cnn_layer_runner_unified64_ds_tiled cases=2
```

The tiled case 0 is the closest available DS1-shaped runner vector
(`12x10x8`, stride 1, 960 outputs); case 1 exercises a spatial tail and
stride 2 (`17x17x8`, stride 2, 1296 outputs).  These are runner-level tiled
transactions, not the full C10 32x32x16 DS1 descriptor.

## Integration change

`ds_block_tile_engine_new.v` now has a one-entry elastic register between its
synchronous DW-tile/weight BRAM responses and unified64 ingress.  The old
direct BRAM-valid pulse could be lost when unified64 temporarily deasserted
`ready_in` while draining a completed result bank; that caused a reproducible
deadlock in runner state `ST_ENGINE_WAIT` / DS state `ST_PW_FEED`.  The stage
holds the response until `pw_fire`, while preserving the legacy path and its
default behavior.

Files added:

- `sim/tb_cnn_layer_runner_unified64_ds.v`
- `sim/filelist_cnn_layer_runner_unified64_ds.f`
- `scripts/run_cnn_layer_runner_unified64_ds_sim.sh`
- `sim/tb_cnn_layer_runner_unified64_ds_tiled.v`
- `sim/filelist_cnn_layer_runner_unified64_ds_tiled.f`
- `scripts/run_cnn_layer_runner_unified64_ds_tiled_sim.sh`

File modified:

- `rtl/cnn/ds_block_tile_engine_new.v`
- `rtl/cnn/cnn_top.v` (passes the selector through the complete-top wrapper)
- `sim/filelist.f`, `sim/filelist_cnn_current.f`
- `scripts/vivado_cnn_top_impl.tcl`, `scripts/vivado_cnn_top_synth.tcl`

## Six DS layer wiring status

The runner has one generic DS instance (`u_ds_block_engine`) selected for every
descriptor with opcode `OP_DS_BLOCK`; it receives descriptor-derived
`in_c_reg`, `out_c_reg`, `stride`, and output dimensions and is not separately
specialized per layer.  The C10 layer shapes routed through this same instance
are:

| layer | P / input spatial | Cin | Cout | stride |
|---|---:|---:|---:|---:|
| DS1 | 1024 / 32x32 | 16 | 32 | 1 |
| DS2 | 256 / 16x16 | 32 | 64 | 2 |
| DS3 | 256 / 16x16 | 64 | 64 | 1 |
| DS4 | 64 / 8x8 | 64 | 128 | 2 |
| DS5 | 64 / 8x8 | 128 | 128 | 1 |
| DS6 | 16 / 4x4 | 128 | 256 | 2 |

The two direct runner cases above prove only the small external-memory
transaction envelope.  The complete six-DS C10 descriptor sequence was then
verified independently with Verilator using the following command:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_cnn_fullnet_unified64_ds_verilator.sh"
```

The fullnet result was exact (`checks=10`, `errors=0`):

```text
PERF tb_cnn_top_fullnet_sram_datapath case=0 hw_cycles=931402 checks=10 errors=0 status=0e364a82 mem_reads=78890 mem_writes=10
PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10
```

The hardware and expected logits files have the identical SHA256
`9AE481448D028A5774406C6B73FF3CCCDB820DA8F4A2EB0ACDBF79AA76251260`.
The machine-readable aggregate is in
`build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt`; the per-layer
ledger is in `build/reports/fullnet_layer_metrics.csv`:

| layer | cycles | mem reads | mem writes | SRAM logical reads | SRAM writes |
|---|---:|---:|---:|---:|---:|
| Stem | 277034 | 4812 | 0 | 0 | 16384 |
| DS1 | 101933 | 800 | 0 | 23104 | 8192 |
| DS2 | 106385 | 2624 | 0 | 34848 | 4096 |
| DS3 | 126857 | 5056 | 0 | 20736 | 4096 |
| DS4 | 82161 | 9344 | 0 | 16384 | 2048 |
| DS5 | 109521 | 18304 | 0 | 8192 | 2048 |
| DS6 | 112113 | 35072 | 0 | 8192 | 1024 |
| GAP | 8720 | 0 | 0 | 4096 | 256 |
| FC | 5795 | 2590 | 10 | 256 | 0 |

The fresh full-top 8 ns gate for this snapshot used Vivado 2025.2,
`xc7z020clg400-1`, `RuntimeOptimized`, and `general.maxThreads=2`.  It routed
with zero routing errors, but did not close timing:

```text
run: build/reports/vivado_cnn_top_unified64_ds_8ns/20260831T101500_unified64_ds_8ns_mt2/
WNS -3.654 ns, TNS -18749.982 ns, 18658 setup failing endpoints
WHS +0.056 ns, THS 0 ns, 0 hold failing endpoints
LUT 36421/53200 (68.46%), FF 35517/106400 (33.38%)
BRAM 48/140 (34.29%), DSP 127/220 (57.73%), total on-chip power 0.398 W
route errors 0, unrouted nets 0, partially routed nets 0
```

The worst setup path is the tiled-loader address recurrence
`u_layer_runner/tiled_input_row_stride_reg_reg/CLK` to
`u_layer_runner/tiled_input_row_base_reg0__2/C[43]`, with 11.337 ns data
delay: 7.423 ns logic (65.5%) and 3.914 ns routing (34.5%).  Therefore this
gate is valid post-route evidence but a negative timing result, not a closure
claim.  Full reports are retained in the run directory above.
