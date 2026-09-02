# D4 vstream v3 mb16 candidate — 2026-09-02

## Scope and evidence boundary

This is an independent `v3` output-service milestone.  It does not modify C0,
the production runner, legacy D4 files, or the pre-existing dirty DS paths.
The RTL shell adds a registered one-entry aligned 32-bit feature-memory sink
around the byte-exact D4 arithmetic child.  `sink_addr` is four-byte aligned,
`sink_data[7:0]` is byte zero, `sink_byte_enable=4'b1111`, and the word is
held stable under `sink_valid && !sink_ready`.  The shell does not instantiate
an arithmetic island or a multiplier.

The arithmetic child is the already verified v2 schedule.  Therefore this
milestone proves the sink ABI and preserves exactness, but it does **not** prove
the v3 persistent PW/RQ/DW overlap architecture.  In particular, the child
reports zero arithmetic overlap and remains above the requested 25,000-cycle
gate.  No OOC/full-top run is claimed from this result.

## Frozen workload

The test uses the real `mb16_down` vectors and all three stages:

| stage | operation | MAC | RQ vectors | output bytes |
|---|---|---:|---:|---:|
| expand | PW 16→32 | 524,288 | 8,192 | 32,768 |
| depthwise | DW 3×3, 32 channels | 73,728 | 2,048 | 8,192 |
| project | PW 32→32 | 262,144 | 2,048 | 8,192 |
| **total** |  | **860,160** | **12,288** | **8,192 final** |

The measured arithmetic counters are `pw_mac=786,432` (expand plus project)
and `dw_mac=73,728`; the PW counter is intentionally not used as the total
stage ledger.  The frozen stage MAC ledger above is the acceptance reference.

## Functional and service checks

The independent Verilator testbench checks every final byte against the frozen
golden output, checks monotonically increasing word index/address, epoch and
byte enables, and checks the registered sink under randomized backpressure.

| run | exact words | exact bytes | word fires | sink stalls | protocol errors |
|---|---:|---:|---:|---:|---:|
| randomized sink/source backpressure | 2,048 | 8,192 | 2,048 | 510 | 0 |
| no backpressure | 2,048 | 8,192 | 2,048 | 0 | 0 |

The no-backpressure run printed:

```text
D4_V3_MB16 words=2048 bytes=8192 cycles=47646 pw_mac=786432 dw_mac=73728 rq_accept=12288 dw_cfg=288 dw_start=512 dw_req=4418 dw_resp=4418 final=8192 sink_stall=0 sink_errors=0 child_overlap=0 errors=0
PASS edgembconv_hwacandidate_d4_vstream_v3_mb16_controller exact=8192 aligned_word_sink=2048
```

The randomized run includes 510 sink stalls and printed the same exact output
with `cycles=48846` and `sink_errors=0`.

## Cycle ledger and decision

The no-backpressure `cycle_count` is **47,646**, so the `≤25,000` v3 gate is
not met (`+22,646`, 1.91× the gate).  The authoritative child state counts
are:

| state | cycles |
|---|---:|
| expand PW | 4,096 |
| expand PW wait | 3,072 |
| expand RQ | 11,008 |
| DW config/start | 288 / 512 |
| DW source/compute wait | 7,230 |
| DW RQ | 7,680 |
| project PW | 2,048 |
| project PW wait | 768 |
| project RQ | 2,752 |
| final byte output | 8,192 |

The stage fences serialize expand, DW, and project; `child_overlap=0` is thus
the measured result.  `dw_req=dw_resp=4,418` and `dw_cfg=288`, `dw_start=512`
match the required DW service counts, while the v3 sink itself is a real
2,048-fire / 8,192-byte commit path.  This result is a negative throughput
result, not a change in workload or a claim that the D4 network is unsuitable.

Required next work is a new v3 arithmetic controller with two-entry raw
psum/context ping-pong, independent 112-PW progress, shared-pool RQ priority,
and DW capture overlapped with prior-tile RQ.  Until that controller is
implemented and measured, no OOC, post-route, power, or GOPS/W conclusion is
valid for v3.

## Reproduction

```text
bash scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_nobp.sh
bash scripts/run_edgembconv_hwacandidate_d4_vstream_v3_mb16_controller_sim.sh
```

Both scripts use Verilator build parallelism `8`.  Build directories are
generated artifacts and are intentionally not part of the candidate commit.
