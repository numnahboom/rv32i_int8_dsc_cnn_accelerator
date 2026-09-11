# D4 vstream v3 mb16 candidate — 2026-09-02

## Scope and evidence boundary

This is an independent `v3` arithmetic/sink candidate.  It does not modify C0,
the production runner, legacy D4 files, or the pre-existing dirty DS paths.
The shell adds a registered one-entry aligned 32-bit feature-memory sink around
the local two-context scheduler.  `sink_addr` is four-byte aligned,
`sink_data[7:0]` is byte zero, `sink_byte_enable=4'b1111`, and the word is
held stable under `sink_valid && !sink_ready`.  Completion is held until the
last packed word drains.  The scheduler uses the dedicated 112-lane PW island,
the shared elastic 16-DSP pool, and a two-entry DW raw capture FIFO.

This is still a candidate boundary: it proves exact C10 MB16 arithmetic and
measured PW/RQ/DW overlap in the standalone workload, but it is not a full-top
integration or timing-closure result.  No OOC/full-top run is claimed here.

## Frozen workload

The test uses the real `mb16_down` vectors and all three stages:

| stage | operation | MAC | RQ vectors | output bytes |
|---|---|---:|---:|---:|
| expand | PW 16→32 | 524,288 | 8,192 | 32,768 |
| depthwise | DW 3×3, 32 channels | 73,728 | 2,048 | 8,192 |
| project | PW 32→32 | 262,144 | 2,048 | 8,192 |
| **total** |  | **860,160** | **12,288** | **8,192 final** |

The frozen stage MAC ledger above is the semantic workload reference.  The
measured RTL counters are `pw_mac=821,248` and `dw_mac=73,728`; the PW counter
includes 34,816 redundant dedicated-island MACs caused by the current context
refill schedule, so it must not be substituted for the semantic ledger.

## Functional and service checks

The independent Verilator testbench checks every final byte against the frozen
golden output, checks monotonically increasing word index/address, epoch and
byte enables, and checks the registered sink under randomized backpressure.

| run | exact words | exact bytes | word fires | sink stalls | protocol errors |
|---|---:|---:|---:|---:|---:|
| randomized sink/source backpressure | 2,048 | 8,192 | 2,048 | 512 | 0 |
| no backpressure | 2,048 | 8,192 | 2,048 | 0 | 0 |

The no-backpressure run printed:

```text
D4_V3_MB16 words=2048 bytes=8192 cycles=43688 pw_mac=821248 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=512 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0 sink_errors=0 child_overlap=4608 errors=0
PASS edgembconv_hwacandidate_d4_vstream_v3_mb16_controller exact=8192 aligned_word_sink=2048
```

The randomized run includes 512 sink stalls and printed the same exact output
with `cycles=44965` and `sink_errors=0`.

## Cycle ledger and decision

The no-backpressure `cycle_count` is **43,688**, so the `≤25,000` v3 gate is
not met (`+18,688`, 1.75× the gate).  `child_overlap=4,608` is real measured
PW/RQ and DW/RQ overlap in this standalone scheduler.  `dw_req=dw_resp=4,418`,
`dw_cfg=288`, `dw_start=512`, and `final=8,192` match the required service
counts; the sink is a real 2,048-fire / 8,192-byte commit path.  Functional
exactness passes, but the redundant PW issue work and cycle gap keep this as a
negative throughput result.  The current sink/scheduler has no standalone OOC
PPA evidence; no post-route, power, GOPS/W, or full-top conclusion is valid.

The context initialization/refill path is now functionally correct for the
first expansion row (including the x=0/group=1 tile), and the completion token
prevents a final-word loss under sink backpressure.  Remaining work for a
production candidate is to eliminate redundant PW refill work, close the
25,000-cycle gate, and then obtain fresh full-top timing/resource/power
evidence before integration.

## Reproduction

```text
bash scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_nobp.sh
bash scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_sim.sh
verilator --lint-only --timing --Wall --Wno-fatal --Wno-BLKLOOPINIT --Wno-UNOPTFLAT -f sim/filelist_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller.f --top-module tb_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller
```

Both scripts use Verilator build parallelism `8`; the lint command exits `0`.
Build directories are generated artifacts and are intentionally not part of
the candidate commit.
