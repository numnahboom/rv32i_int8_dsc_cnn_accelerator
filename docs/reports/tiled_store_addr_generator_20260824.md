# Tiled-store address generator verification (2026-08-24)

Commit: `b665a74` (`Optimize tiled store address progression`).

The change registers the tiled external-store byte address at tile setup and
advances it only after `mem_req_valid && mem_req_ready`.  It preserves the
single-outstanding read/write protocol, synchronous output-buffer read, stall
payload stability, and store request cadence.

## Functional evidence

Focused XSim and Verilator tests pass for tiled Stem, tiled DSBlock,
backpressure, and SRAM tiled DSBlock.  The complete XSim and Verilator suites
have failures in ops/multilayer/GAP-FC/tail/e2e/fullnet paths; every reported
failure was reproduced in an isolated worktree at `b665a74^` with the same
address and mismatch location, so these are pre-existing baseline failures.

## Fresh routed OOC evidence

Vivado 2025.2, part `xc7z020clg400-1`, 100 MHz clock, post-route OOC:

| Run | Directive | WNS (ns) | TNS (ns) | WHS (ns) | THS (ns) | Route |
|---|---|---:|---:|---:|---:|---|
| baseline | RuntimeOptimized | -8.900 | -36509.522 | n/a | n/a | routed |
| `20260824T020909569-25960` | RuntimeOptimized | -8.246 | -37008.645 | +0.078 | 0.000 | routed |

The valid apples-to-apples WNS improvement is `+0.654 ns`, exceeding the
`+0.15 ns` target.  The current worst paths are Stem accumulation paths;
the tiled loader path is no longer among the top paths.  TNS is 499.123 ns
more negative than the recorded baseline and remains a review risk.  The run
manifest is `FAILED_TIMING_CLOSURE` because setup timing remains violated.
