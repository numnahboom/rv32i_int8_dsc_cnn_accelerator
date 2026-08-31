# Unified64 Stem runner integration — 2026-08-31

## Scope

`USE_UNIFIED64_STEM` is now an optional compile-time parameter on `cnn_top`
and `cnn_layer_runner`.  The default (`0`) keeps the legacy Stem, including
the legacy tiled Stem loader.  The unified path is selected with
`USE_UNIFIED64_STEM=1`; it consumes the existing external 32-bit scalar
memory request/response bus, writes four output channels per feature-bank
word commit, and leaves the existing DS selector (`USE_UNIFIED64_DS`) intact.

The unified path is restricted to the actual full Stem contract:
32x32x3 input, 32x32x16 output, stride 1, padding 1.  It reads one int8 from
`mem_resp_rdata[7:0]` per accepted 32-bit read.  The isolated module retains
its packed-four-byte proof mode through `PACKED_INPUT=1`; runner integration
uses `PACKED_INPUT=0` to match the repository's scalar external-memory
vectors.

## Functional evidence

Commands:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_stem_unified64_streaming_sim.sh'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_cnn_fullnet_unified64_stem_verilator.sh'
```

The standalone packed source test passed two 32x32x3 runs with 8,192 output
commits, 442,368 MACs per run, and 768 source reads per run.  The fresh
fullnet Verilator run passed all 10 logits (`errors=0`) and all downstream
feature-bank checks:

| metric | unified Stem fullnet |
|---|---:|
| total hardware cycles | 654,205 |
| external reads | 77,630 |
| external writes | 10 |
| Stem cycles | 57,950 |
| Stem external reads | 3,552 |
| Stem feature-bank writes | 16,384 scalar-equivalent bytes |
| MAC count | unchanged full network 5,136,896 |
| logits | exact, 10/10 |

The Stem external-read count is 3,072 scalar input words plus 480 weight and
requant parameter words.  The legacy fullnet run in the same worktree is
873,289 cycles and 78,890 external reads, so this candidate removes 219,084
cycles (25.1%) and 1,260 external reads without changing the computation.

The same fullnet test was also built with `MEM_READY_STALLS=1`, inserting a
deterministic ready bubble pattern on the shared external bus.  It passed all
10 logits with `errors=0` and completed in 680,533 cycles.  This exercises the
runner request bridge's valid/address stability under backpressure.

## Timing / implementation evidence

The fresh 8 ns full-top attempt was launched with Vivado 2025.2,
xc7z020clg400-1, Explore, and `general.maxThreads=2` using
`scripts/run_cnn_top_unified64_stem_8ns_impl.ps1`.  Vivado crashed during
full-top synthesis (Windows exit `-1073740940`); therefore no full-top
post-route result is claimed.

The required pre-integration isolated 8 ns post-route screen already exists
at `build/reports/vivado_stem_unified64_streaming_ooc_20260831/`:

| metric | isolated unified Stem |
|---|---:|
| WNS | -10.537 ns |
| TNS | -5,841.980 ns / 5,435 failing endpoints |
| WHS | +0.123 ns |
| LUT | 8,862 (16.66%) |
| FF | 11,793 (11.08%) |
| DSP | 80 (36.36%) |
| BRAM | 0 inferred in this run |
| total on-chip power | 0.325 W |

This is a negative timing gate despite the functional/cycle gain.  The
dominant cause is the current unified Stem's wide static-window select and
64-MAC fanout mapping: the isolated design has 33,937 timing endpoints and
the worst routed paths are about 31 logic levels.  The path is not a runner
protocol or scalar-memory correctness issue.  The full-top synthesis crash
also means resource/timing interaction at top level remains unproven.

## Changed files

- `rtl/cnn/stem_unified64_streaming.v`: explicit scalar external-memory mode.
- `rtl/cnn/cnn_layer_runner.v`: optional generate-selected engine, target
  mapping, full-image direct source bridge, and four-byte output-buffer commit.
- `rtl/cnn/cnn_top.v`: parameter propagation.
- `sim/tb_cnn_top_fullnet_sram_datapath.v`: unified parameter and optional
  external-bus-stall test mode; unified read-count expectation.
- `sim/filelist.f`, `sim/filelist_cnn_current.f`, and runner filelists:
  include the optional Stem source.
- `scripts/run_cnn_fullnet_unified64_stem_verilator.sh` and
  `scripts/run_cnn_top_unified64_stem_8ns_impl.ps1`: reproducible checks.

## Decision

Keep the integration behind `USE_UNIFIED64_STEM`, but do not promote it to
the production default or claim timing closure.  The 25.1% fullnet cycle
reduction is real and exact, while the isolated OOC WNS is far below the
required +0.5 ns candidate gate.  The next engineering step is to physically
localize/restructure the unified Stem's 64-MAC and window-select cones before
another full-top attempt; runner-level changes alone cannot repair this
negative implementation result.
