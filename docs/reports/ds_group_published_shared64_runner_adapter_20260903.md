# Group-published shared64 runner adapter slice (2026-09-03)

## Produced boundary

`ds_group_published_shared64_runner_adapter.v` provides a descriptor-facing
optional bridge around one `ds_group_published_shared64_sweep` and one reused
4x8 DW producer.  `ds_group_feature_word_address_adapter.v` maps delayed
pixel-major SRAM words, stride/pad halo, and 16-channel source slices.  PW
weights are captured from scalar config writes and preloaded into the sweep;
DW weights/bias/multiplier/shift are repacked for each sequential 16-channel
producer job.  The bridge exposes packed output words and metrics, without
changing the legacy runner.

Dedicated filelist/script/testbench:

```text
sim/filelist_ds_group_published_shared64_runner_adapter.f
scripts/run_ds_group_published_shared64_runner_adapter_sim.sh
sim/tb_ds_group_published_shared64_runner_adapter.v
```

## Fixed-preload baseline evidence (superseded by active-shape run below)

The dedicated Verilator run now executes all six C10 DS shapes through the
real producer and bridge. Each shape loads 256 PW parameter rows and 4,096
physical PW weight rows before `start`; the source model uses pseudo-random
data and delayed responses, while the output sink applies periodic
backpressure. Source addresses are independently checked for
alignment and the active NHWC byte range; every output handshake is checked
for alignment, range, and byte-enable mask. The bridge's DW repack is checked
against the runner's channel-major nine-tap ABI during every group setup.

| Shape | Input / output | stride | `perf_cycles` | DW service cycles | DW beats | jobs | descriptors | PW tokens | output words | source words | output stalls |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DS1 | 32x32x16 -> 32x32x32 | 1 | 35,445 | 22,048 | 4,096 | 32 | 256 | 8,192 | 8,192 | 6,992 | 884 |
| DS2 | 32x32x32 -> 16x16x64 | 2 | 33,246 | 12,512 | 2,048 | 16 | 128 | 8,192 | 4,096 | 9,240 | 436 |
| DS3 | 16x16x64 -> 16x16x64 | 1 | 41,669 | 22,048 | 4,096 | 32 | 256 | 16,384 | 4,096 | 6,336 | 439 |
| DS4 | 16x16x64 -> 8x8x128 | 2 | 25,066 | 6,256 | 1,024 | 8 | 64 | 8,192 | 2,048 | 4,352 | 239 |
| DS5 | 8x8x128 -> 8x8x128 | 1 | 34,324 | 11,024 | 2,048 | 16 | 128 | 16,384 | 2,048 | 2,560 | 218 |
| DS6 | 8x8x128 -> 4x4x256 | 2 | 28,875 | 6,256 | 1,024 | 8 | 64 | 8,192 | 1,024 | 2,048 | 110 |
| **Total** | — | — | **198,625** | **80,144** | **14,336** | **112** | **896** | **65,536** | **21,504** | **31,528** | **2,326** |

The physical DW beat/descriptor ledger is macro-based: DS6 has 16 useful
output pixels but the reused 4x8 producer emits a complete 32-pixel macro,
so its physical traffic is intentionally 1,024 beats and 64 descriptors.
This is reported as traffic overhead, not credited useful MAC work. The
semantic six-layer DS workload remains 4,194,304 MAC / 8,388,608 operations.

The run also counts cycles spent in the adapter's `S_WAIT_JOB` DW-service
state.  The total is 80,144 cycles (DS1..DS6: 22,048, 12,512, 22,048,
6,256, 11,024, 6,256), below the 90,000 DW-service gate.  The full adapter
ledger remains 198,625 cycles, above the 160,000 threshold for the optional
narrow OOC step, so no OOC/full-top run is started from this slice.

The read path was changed to a one-read-per-cycle bank pipe with held output
under backpressure, an eight-entry response-address FIFO, and a bounded
four-entry local synchronous-RAM lookahead queue.  The queue carries only
registered vector data plus issue metadata; it does not add a compute core,
payload-copy bank, or CAM.  The existing epoch/bank fences and READ_FIRST
collision behavior remain in force.

The run ends with:

```text
PASS six-shape real-producer ledger source_words=31528 output_words=21504
```

The separate older `ds_group_published_shared64_real_producer` DS1 vehicle was
also re-run after the pipe change.  Its legacy hard-coded result scoreboard
currently reports 16,896 mismatches (the transaction counts remain exact:
4,096 DW writes, 256 descriptors, 8,192 PW tokens, 8,192 output words, and 32
jobs).  The new six-shape bridge test intentionally uses an independent
address/count/handshake scoreboard rather than claiming logits, and the
producer-island exact arithmetic bench still passes.  Consequently this slice
does not claim end-to-end logits correctness for the legacy vehicle; its
remaining mismatch is a promotion risk that must be resolved before any
runner/full-top integration.

`perf_cycles` counts from each adapter `start` through PW parameter/weight
preload, source service, DW jobs, shared64 PW/RQ, output drains, and the final
done fence. The corrected channel-major DW repack is a minimal bridge fix;
the former DS1-only all-ones test could not expose that group-slice ABI bug.
Verilator compilation of the complete dedicated filelist exits 0 (existing
width/connectivity warnings remain).

## Original integration blocker

An exploratory six-shape run correctly reached DS2 but deadlocked at macro 2
with the sweep descriptor FIFO containing mixed row/group order (`desc=30`,
`pw_group=2`, `pw_tokens=16`, both scratch banks busy).  The existing sweep
consumer requires strict row-major descriptor-head order, while a single
16-channel producer emits all four rows for groups 0/1 before the next
channel slice emits groups 2/3.  Therefore this bridge is **not** a six-layer
fullnet integration and no C0 cycle, MAC, logits, OOC, or full-top claim was
made at that point.

## Direct-index reorder recovery (not yet a runner promotion)

The descriptor FIFO has subsequently been replaced in the sweep vehicle with
a bounded direct-index publication scoreboard. It stores no payload: the
existing four scratch memories remain the only 256-bit row storage, while the
metadata key is `{bank, local_row[1:0], k_group[3:0]}`. A slot becomes valid
only on the final second-half/pixel write; the PW schedule consumes only its
expected row/group with a matching bank owner/session/epoch. The final Cout
tile clears the row slots before the bank can be reused, so a later macro
cannot overwrite a live row/group slot.

`bash scripts/run_ds_group_published_shared64_sweep_sim.sh` now completes all
six synthetic, non-zero C0 DS shapes under periodic output backpressure with
exact scoreboards, no intermediate requantization, and no deadlock. The
per-layer sweep cycles are 14,946, 12,427, 20,713, 10,474, 18,867, and 9,642
(87,069 total; this remains an isolated sweep measurement, not a real runner
end-to-end count). Re-running
`bash scripts/run_ds_group_published_shared64_runner_adapter_sim.sh` is the
authoritative six-shape real-producer run above; the older stop-and-wait
326,289-cycle ledger is superseded by the lookahead/backpressured 198,625-cycle
run.

## Decision boundary

The real six-shape bridge run is functionally/protocol complete for this
boundary and clears the local DW-service gate, but it is a **NEGATIVE_RESULT**
for the parent next-step gate because 198,625 adapter cycles exceed 160,000.
Therefore this candidate must not be promoted into the runner or full top from
this slice. It provides no C0 logits, OOC, post-route timing, resource, or
power evidence; those claims remain unproven.

## Active-shape preload update (2026-09-03)

The adapter preload state machine now stops at the active shape rather than the
compile-time maxima.  PW parameters load channels `0..Cout-1`; physical PW
weight rows load tiles `0..ceil(Cout/8)-1` and input rows `0..Cin-1`.  Runtime
schedule bounds remain captured by the sweep's `start_cin/start_cout`, so an
inactive parameter or weight slot cannot create a valid token.  The physical
weight address ABI is unchanged (`tile*128 + k` at preload and
`tile*128 + group*8 + k` at sweep read), and the runner's MAX_CIN-strided
configuration ABI is unchanged.

The dedicated TB now uses non-uniform PW weights and audits every active
parameter slot, every physical preload tile/k address and its eight lanes,
active result pixel/channel slots, source address range/alignment, output
byte-enable/range, DW channel-major repacking, and forward progress.  Source
and output interfaces receive independent deterministic LFSR backpressure;
the sequence is randomized/reproducible and is not a periodic fixed pattern.

| Shape | `perf_cycles` | DW service | active PW params | active PW weight rows | output stalls |
|---|---:|---:|---:|---:|---:|
| DS1 | 31,513 | 22,048 | 32 | 64 | 1,146 |
| DS2 | 25,553 | 12,512 | 64 | 256 | 552 |
| DS3 | 34,358 | 22,048 | 64 | 512 | 586 |
| DS4 | 18,969 | 6,256 | 128 | 1,024 | 292 |
| DS5 | 30,098 | 11,024 | 128 | 2,048 | 302 |
| DS6 | 28,998 | 6,256 | 256 | 4,096 | 141 |
| **Total** | **169,489** | **80,144** | **672** | **8,000** | **3,019** |

Command and result:

```text
bash scripts/run_ds_group_published_shared64_runner_adapter_sim.sh
PASS six-shape real-producer ledger source_words=31528 output_words=21504
```

The former fixed preload was `32*128 = 4,096` weight rows plus `256`
parameters per shape, or `26,112` entries per six-shape sweep.  This run loads
`8,000 + 672 = 8,672` active entries in total (the six listed C10 shapes give
`sum(ceil(Cout/8)*Cin)=8,000`; the previously circulated `8,672` weight-row
figure is an arithmetic overestimate).  Thus the measured reduction is 17,440
entries, with no inactive slot credited as useful work.  The total bridge wall
clock is now 169,489 cycles, strictly below the prior 198,625 but still above
the 160,000 promotion gate; no OOC/full-top run is justified by this slice.

## Packed configuration-memory refactor (2026-09-03)

The bridge no longer exposes asynchronous scalar arrays to synthesis. Scalar
configuration writes are decoded at the adapter boundary into these physical
single-copy stores (all XPM SDP, `READ_LATENCY_B=1`, `WRITE_MODE_B="read_first"`):

| Store | Physical organization | ABI mapping |
|---|---:|---|
| PW weights | 4096 x 64 | `row={cout/8,cin}`, byte lane `cout%8`; source index remains `cout*128+cin` |
| PW parameters | 256 x 72 | bias[31:0], multiplier[63:32], shift[69:64] |
| DW weights | 128 x 72 | one channel row containing nine taps; ABI `channel*9+tap` selects byte lane |
| DW parameters | 128 x 72 | one channel row containing bias/multiplier/shift |

The sweep's external-memory mode removes its second PW-weight store and
preload state. It requests one registered PW row per token and receives an
explicit address-tagged response. Eight narrow parameter reads form the
current tile cache; the cache is not modified during a first-k..last-k
sequence. The adapter reads sixteen DW rows into bounded per-job caches before
presenting the existing nine-cycle producer configuration ABI. No payload RAM
is cleared in reset; only control, valid/tag, and cache state is reset.

The scalar boundary exports `config_accept_count` and `config_phase_count`.
The dedicated Verilator test audits all 35,072 scalar writes into the packed
physical rows/byte lanes before running the six real-producer shapes. It also
checks active source/output ranges and randomized output stalls. The current
run passes:

```text
bash scripts/run_ds_group_published_shared64_runner_adapter_sim.sh
PASS six-shape real-producer ledger source_words=31528 output_words=21504
```

The traffic ledger remains 21,504 output words, 14,336 DW beats, 896
descriptors, and 65,536 PW tokens. This is a configuration/storage and
protocol result; it is not a DS1 logits scoreboard or full-network inference
claim. The previous adapter `start->done` number is not an end-to-end
inference number unless the preceding runner configuration-write phase is
added. Vivado is unavailable in this execution environment, so no new OOC
mapping/timing/PPA claim is made here.

## DS1 exact value scoreboard (2026-09-03)

An additional dedicated bench drives the same adapter through 800 scalar
configuration writes (16 Cin, 32 Cout), with one-cycle source responses and
randomized source/output stalls. Unit DW/PW weights and all-one source bytes
are checked against an independent 3x3-neighbour reference for every internal
result handshake (32,768 byte lanes), including boundary/tail pixels. It
passes without mismatch:

```text
bash scripts/run_ds_group_published_shared64_runner_adapter_exact_sim.sh
PASS adapter DS1 exact cycles=32856 dw=4096 desc=256 pw=8192 out=8192 source=6978 stalls=2555 cfg=800
```

This exact bench is intentionally separate from the non-uniform six-shape
traffic bench, whose purpose is packed-address/BE, tail-shape, and forward
progress coverage.

The double current/next parameter cache and removal of PW preload were then
re-run on the six-shape traffic bench. Per-shape adapter cycles are
33,171/25,504/34,415/16,877/26,028/20,559, for **156,554 cycles total**;
DW service is 79,004 cycles. The traffic counts remain exact and the run still
passes the same command above. This clears the local 160,000-cycle bridge
screen, but it is not a full-network or energy result.
