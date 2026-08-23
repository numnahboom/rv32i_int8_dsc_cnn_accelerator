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

A fresh routed OOC run could not be produced in this environment.  The only
installed Vivado is 2021.2 with an `xc_k26`-only device database; both
`xc7z020clg400-1` and `7z020clg400-1` are rejected as invalid parts.  Therefore
the candidate is functionally verified but not yet timing-accepted.  The
previous accepted routed baseline remains WNS `-8.246 ns`, TNS `-37008.645 ns`,
WHS `+0.078 ns`, THS `0 ns`.
