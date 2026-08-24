# Stem row-base timing candidate (2026-08-24)

## Change

`conv3x3_stem_engine_new` now registers the base byte address of the current
input row.  The 3x3 MAC address expression uses that stable row base plus the
kernel-row and output-column offsets.  The row base advances only when the
output pixel wraps to the next row, so the MAC cadence and single-outstanding
memory protocol are unchanged.

This specifically removes `out_y_idx` from the address-to-accumulator timing
cone observed in the fresh routed run `20260824T020909569-25960` (WNS
`-8.246 ns`).  Its worst path was `out_y_idx_reg[0]/C` to
`acc_reg_reg[26]/D`, with 18.241 ns delay and 22 logic levels.

## Functional verification

Fresh XSim focused tests passed:

| Test | Result |
|---|---|
| `tb_cnn_top_tiled_stem_datapath` | PASS, 16,384 checks |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, 576 checks |

Fresh WSL Verilator `tb_cnn_top_tiled_stem_datapath` also passed with 16,384
checks.  No cycle or protocol changes were introduced.

## Timing verification status

A fresh routed OOC run was subsequently completed with Vivado 2025.2,
`xc7z020clg400-1`, and `RuntimeOptimized` (`20260824T113041158-23176`).  The
candidate regressed the direct baseline and was rejected:

| Run | WNS (ns) | TNS | WHS (ns) | THS (ns) | Route |
|---|---:|---:|---:|---:|---|
| baseline `b665a74` | -8.246 | -37008.645 | +0.078 | 0 | routed |
| row-base candidate | -9.653 | -38094.851 | +0.076 | 0 | routed |

The candidate had 16,416 setup-failing endpoints.  Its worst path was
`kernel_y_idx_reg[0]_replica/C` to `acc_reg_reg[29]/D` (19.600 ns data delay,
26 logic levels), replacing the baseline's `out_y_idx` path but with worse
slack.  No functional change justified the 1.407 ns WNS loss.  The RTL
candidate was reverted after this run.  This report is retained as negative
timing evidence; no timing optimization commit is accepted from this
experiment.
