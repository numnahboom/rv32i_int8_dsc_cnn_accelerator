# DW to PW tile streaming feasibility (2026-08-27)

## Result

`BLOCKED` for a bounded RTL prototype under the current PW K-serial ABI.  The
DW buffer itself can perform a dual-port read and write in the same cycle, but
the current controller is group-major and the PW array does not start a
reduction until it has received `k_last`.  A useful overlap therefore needs an
independent DW/PW scheduler plus a spatial-block commit protocol (or a PW
partial-K interface, which is outside this task's ABI boundary).

## Exact dependency and ordering

* `dw_tile_fusion_engine_vector4` computes one `channel_base` group of 16 DW
  channels while scanning the complete padded input tile.  Selected 3x3
  windows are emitted in increasing output-pixel order; stride 1/2 selection
  and the 3x3 boundary are resolved by `window_origin_*`,
  `stride_phase_match`, and `window_inside_output`.
* `ds_block_tile_engine_new` waits for `dw_done`, then loads the next 16-channel
  parameter group and restarts the input scan.  Consequently the producer
  order is `channel_group 0: pixels 0..N-1`, then `channel_group 1: pixels
  0..N-1`, and so on.  The final vector4 output is byte-masked for a tail
  channel group.
* `dw_tile_buffer_bram` stores channel `c` in physical bank `c[1:0]`, at
  address `{pixel_base[5:3], c[6:2]}`.  A word contains eight spatial bytes;
  the read contract is one-cycle `rd_valid` and an 8-pixel vector for one
  channel.  The four XPM instances are simple dual-port BRAMs with byte
  writes, 64-bit reads, and `READ_MODE_B("read_first")`.
* The PW source transaction is exactly one channel's 8-pixel vector plus its
  weight vector.  `pw_systolic_array_8x8` stores vectors in K order and only
  asserts `compute_active` after the transaction with `k_last`; it then replays
  the complete K list for the two physical 8x4 halves.  `clear_acc` is only
  meaningful on K=0, so a channel prefix cannot be reduced and resumed as two
  independent transactions.

## Smallest safe producer/consumer unit

The smallest PW-consumable unit is an 8-pixel spatial block across **all** C
channels.  A 16-channel DW result block is not sufficient: it supplies only a
K prefix.  With the existing group-major producer, block 0 becomes complete
only when the final channel group has emitted pixels 0..7.  For an output tile
with at most eight pixels, no DW work remains after that point, so a concurrent
PW computation cannot save cycles.  For larger tiles, only later final-group
spatial blocks can overlap; the current single FSM has no valid/tag/fence
token to launch PW at those boundaries.

Physical bank observations:

* Different channel groups map to the same four physical banks but different
  `c[6:2]` addresses, so an SDPRAM read of an already committed block and a DW
  write to a different group/address are electrically legal.
* The existing buffer has no tile/block valid bits, ownership tag, or reuse
  fence.  A same-bank/same-address read during a byte write is only
  `READ_FIRST`, not a producer-consumer commit guarantee.  A true ping-pong
  implementation would need bank-set selection and an explicit commit/fence
  protocol, not a second copy of the PW array.

## Counterexample to channel-chunk streaming

For `C=17`, the PW array must receive K=0..16 in order before `k_last` and
cannot compute with K=0..15 while waiting for channel 16.  DW emits group 0
(channels 0..15) for all pixels before group 1 (channel 16).  Thus a proposed
“write one 16-channel bank while PW consumes it” schedule either sends
`k_last` too early (incorrect partial sums) or stalls before computation.  The
valid alternative is to wait until a complete 8-pixel block has all 17
channels, then overlap PW with later spatial blocks; that requires the missing
independent scheduler and commit tags.

## Current direct evidence

Command:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY=tb_ds_block_tile_engine_new \
  SIM_LOG_DIR=build/reports/dw_pw_direct_20260827 bash scripts/run_all_sims.sh
```

Verilator passed `tb_ds_block_tile_engine_new`, 7 cases and 2,191 checks.  The
cases include stride 1/2 and channel counts 8, 16, 8, 1, 7, 17, and 127.  The
current sequential baseline counters were:

```text
case total  dw    pw    pw_issue
0    2108   1856  252   64
1     840    604  236   64
2    1188    272  916   256
3     457    406   51    2
4     401    328   73   14
5    1049    811  238   68
6   13851   1513 12338 4064
```

The direct DS output has no external ready signal, and this run therefore does
not claim output-backpressure coverage.  No RTL was changed and no overlap
trace was claimed; an implementation would need the interface below before a
functional/backpressure prototype could be meaningful.

## Smallest next interface

Keep the current PW data/K ABI if a spatially interleaved DW schedule is
authorized, and add:

1. `dw_block_valid`, `dw_block_tag={tile_id, spatial_block, channel_group}`,
   and a commit count/last indication after all C channel groups for one
   8-pixel block are written;
2. independent DW and PW phase control, with PW launch only on a committed
   block and a fence before reusing either ping-pong bank set; and
3. bank-set select on both buffer ports plus assertions for no same-bank,
   same-address read/write and no tag mismatch.

If channel-group-major order must be retained, the PW array additionally needs
an explicitly tagged partial-K accumulate/resume transaction (`k_base`,
`k_count`, `k_last`/epoch).  That changes the existing PW ABI and is outside
the requested boundary.

