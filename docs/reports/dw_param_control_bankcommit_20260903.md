# Persistent DS DW parameter/control candidate (2026-09-03)

This candidate is limited to `ds_block_tile_engine_new.v` and the direct DW
MAC helper.  It preserves the original signed arithmetic, DW/PW handshakes,
single outstanding behavior, token/commit ordering, and the 5,136,896-MAC
full-network workload.

## RTL change

The DW parameter loader now registers the packed parameter address and the
distributed-memory read result before committing a completed 9-byte lane to a
fixed slice of the existing vectors.  This removes the former combined
`dw_param_lane`/`dw_param_kernel` variable part-select from the 1,152-bit DW
weight vector.  Small physical copies of DW shape/control values feed the DW
engine, and `dw_mac_lanes` uses a kept local cycle-index replica for its row
decode.  No upper-level interface or file list was changed.

## Evidence

* Focused Verilator: `tb_dw_mac_lanes` and `tb_ds_block_tile_engine_new` PASS;
  2,191 DS checks, exact logits in all 7 DS cases.  The final candidate's
  largest focused case is 12,008 cycles (DW 3,817, PW 8,191).
* C0 fullnet shared unified64 + persistent DS: PASS, 10/10 checks,
  `hw_cycles=601532`, `mem_reads=77630`, `mem_writes=10`; hardware and expected
  logits both hash to
  `9AE481448D028A5774406C6B73FF3CCCDB820DA8F4A2EB0ACDBF79AA76251260`.
  The debug metric block could not be enabled against the current dirty
  runner hierarchy without touching the protected fullnet TB; the exact
  functional/cycle run was performed without that observability define.
* Fresh Vivado 2025.2 routed OOC, `xc7z020clg400-1`, 8 ns, with Explore
  placement and AggressiveExplore post-route physopt: WNS **+0.140 ns**,
  TNS 0, WHS +0.098 ns, THS 0, zero unrouted nets; 15,934 LUTs (29.95%),
  23,268 FFs (21.87%), 28 BRAM36 (20.00%), 16 DSP (7.27%), 0.259 W.
  The former DW parameter path is no longer critical.  The reported critical
  path is now `out_w_reg_reg[1]` to `state_reg[3]`, inside DW control, with
  0.140 ns slack.

The result is timing-clean at 8 ns but does not meet the stricter +0.5 ns OOC
screen.  It is therefore a partial timing result, not full-top closure.
