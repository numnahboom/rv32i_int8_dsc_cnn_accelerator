# EdgeMBConv hardware-aware candidate D4 — DW16 stream tile RTL evidence

This is an independent D4 candidate artifact.  It does not modify C0, any C0
training/checkpoint path, the legacy runner, or the production top level.  The
primitive is a 16-lane INT8 depthwise 3x3 tile intended for the MBConv/PW-DW-PW
workload; it is not a claim that D4 replaces C0.

## Frozen transaction and workload

The vectors are generated from the frozen D4 INT8 deployment archive
`build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy/edgembconv_hwacandidate_d4_int8.npz`
(SHA256 `5804204e0ba2bd23e8e40dcfc656007838935d28692279401ae058822775dbe7`)
and official CIFAR-10 test sample 0 (label 3).  Each transaction computes one
8x8 output tile for one 16-channel depthwise group:

| Case | Layer | Stride | Output pixels | Taps | Semantic MACs | Source requests |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `mb32_stride1_dw16` | `mb32.spatial` | 1 | 64 | 576 | 9,216 | 529 |
| `mb16_down_stride2_dw16` | `mb16_down.spatial` | 2 | 64 | 576 | 9,216 | 529 |

The source interface is a synchronous, worded, in-order request/response ABI
with at most one outstanding 128-bit word.  Halo taps are generated locally;
the 529 requests are the 576 taps minus 47 halo taps.  The sixteen signed
INT8xINT8 products are registered before INT32 accumulation.  Requantization
uses a separate registered, shift/add-oriented stage with `use_dsp=no`, so it
does not silently duplicate the DW DSP bank.

## Exact simulation evidence

Command:

```text
python python/export_edgembconv_hwacandidate_d4_dw16_vectors.py
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_sim.sh'
```

The Verilator test uses real D4 vectors, random source/output backpressure,
request and output stability checks, exact raw INT32 psums and INT8 outputs,
SAME halo behavior, metadata/first/last tags, and a 12-lane tail-mask case.

```text
D4_DW16 case=0 name=mb32_stride1 stride=1 outputs=64 taps=576 source_words=529 cycles=990 source_stalls=74 output_stalls=5
D4_DW16 case=1 name=mb16_down_stride2 stride=2 outputs=64 taps=576 source_words=529 cycles=1016 source_stalls=99 output_stalls=6
D4_DW16 case=1 name=mb16_down_stride2 stride=2 outputs=64 taps=576 source_words=529 cycles=987 source_stalls=69 output_stalls=7
PASS edgembconv_hwacandidate_d4_dw16_stream_tile cases=3 real_cases=2 tail_case=1
```

For all three runs, subtracting the counted source and output stall cycles
gives the same 911-cycle no-backpressure service floor:

| Run | Observed | Source stalls | Output stalls | Derived no-stall floor |
| --- | ---: | ---: | ---: | ---: |
| stride 1 | 990 | 74 | 5 | **911** |
| stride 2 | 1,016 | 99 | 6 | **911** |
| stride 2 rerun | 987 | 69 | 7 | **911** |

The 911-cycle floor accounts for the one-cycle synchronous source boundary,
registered product/accumulator and requantization drain, and the output fence;
it is not a raw `MAC count / lane count` claim.  Against the current
conservative feeder service envelopes (stride 1 <= 1,325 cycles, stride 2 <=
1,674 cycles), the observed runs are inside the envelope.  This is a tile-level
service result only; a full-block or full-network cycle result still requires
producer/consumer integration.

## XC7Z020 fresh OOC/post-route screen

Run script:
`scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.ps1`

Output directory:
`build/reports/vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902`

The run used Vivado 2025.2, `xc7z020clg400-1`, an 8.000 ns clock, and
`general.maxThreads=8`.  The Vivado log reports multithreaded place/phys-opt/
route using eight CPUs.  Route status reports 43,909/43,909 routable nets fully
routed and zero routing errors.

| Metric | Fresh routed OOC result | Interpretation |
| --- | ---: | --- |
| WNS / TNS | **-8.485 ns / -10,081.023 ns** | fails 8 ns setup timing |
| WHS / THS | +0.151 ns / 0.000 ns | hold passes |
| Slice LUT | 32,066 (60.27%) | below 70% screen |
| Slice registers | 5,013 (4.71%) | below 70% screen |
| DSP48E1 | 18 / 220 (8.18%) | shift/add requant remains LUT-oriented |
| BRAM | 0 | no BRAM inferred in this standalone primitive |
| Estimated total on-chip power | 0.219 W | vectorless OOC estimate |

The setup result is a negative physical gate for this current standalone
implementation.  The critical paths have roughly 16.4 ns data delay at an
8 ns target, with both logic and routing contributing materially.  This does
not invalidate the exact functional result, but it prevents claiming a
125 MHz implementation or a favorable latency result.  Any timing repair must
remain inside this independent primitive; C0 and production RTL are out of
scope.

## Independent artifacts and boundary

- RTL: `rtl/cnn/edgembconv_hwacandidate_d4_dw16_stream_tile.v`
- Testbench/filelist: `sim/tb_edgembconv_hwacandidate_d4_dw16_stream_tile.v`, `sim/filelist_edgembconv_hwacandidate_d4_dw16_stream_tile.f`
- Vector generator/vectors: `python/export_edgembconv_hwacandidate_d4_dw16_vectors.py`, `build/edgembconv_hwacandidate_d4_dw16_stream_vectors/`
- Simulation launcher: `scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_sim.sh`
- OOC Tcl/launcher: `scripts/vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.tcl`, `scripts/run_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.ps1`
- Fresh reports: `build/reports/vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902/`

This gate establishes a reusable DW primitive with exact real-vector behavior,
stall-safe protocol semantics, and a measured resource/timing boundary.  It
does not establish full D4 accuracy, full-network RTL reuse, synthesis closure,
or a D4-over-C0 accuracy-latency tradeoff.
