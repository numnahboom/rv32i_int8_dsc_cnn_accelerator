# PW replay operand pipeline candidate

Date: 2026-08-28  
Device: `xc7z020clg400-1`  
Clock gate: 10.000 ns, Vivado 2025.2 `RuntimeOptimized`

## Change

`rtl/cnn/pw_systolic_array_8x8.v` now registers the replay-memory operands
(`act_feed_reg`, selected four-column `wgt_feed_reg`, and
`clear_feed_reg`) before driving the 8x4 PE fabric.  The selected weight half
is formed while filling/prefetching the operand register, so `compute_phase`
does not fan out through the PE multiplier/accumulator input muxes.  The
first cycle of each half-replay is a fill cycle; subsequent K words are
prefetched while the current registered word is consumed.  This adds two
fixed cycles per 8x8 PW result, preserves the input ready/valid and output
elastic transaction contracts, and does not change any signed arithmetic or
MAC count.

## Functional evidence

Verilator 5.020 focused tests passed:

* `tb_pw_systolic_array_8x8`: 6 cases / 384 checks.
* `tb_pw_systolic_array_8x8_backpressure`: held output stable under five
  stalled cycles and accepted the following reduction.
* `tb_ds_block_tile_engine_new`: 7 cases / 2,191 checks; PW issue counts
  remained 64, 64, 256, 2, 14, 68, and 4,064.
* `tb_cnn_top_fullnet_sram_datapath`: 10/10 exact logits, 999,014 hardware
  cycles, 5,136,896 MACs, and no memory errors.

The one failed batch invocation was a test-vector regeneration `OSError` on
the shared WSL-mounted path; rerunning the DSBlock test with vector
generation disabled passed.  No RTL mismatch was observed.

## Routed OOC evidence

The candidate was routed in isolation through both PW and DSBlock wrappers
using 10 ns clocks.  Reports are under:

* `build/reports/vivado_pw_systolic_array_operand_pipeline_ooc_20260828/`
* `build/reports/vivado_ds_block_tile_engine_operand_pipeline_ooc_20260828/`

| Wrapper | WNS | WHS | TNS / THS | Route errors | LUT / FF / BRAM / DSP | Power |
|---|---:|---:|---:|---:|---:|---:|
| PW array | +0.107 ns | +0.098 ns | 0 / 0 | 0 | 7.39% / 3.98% / 0% / 0% | 0.135 W |
| DSBlock | +0.128 ns | +0.096 ns | 0 / 0 | 0 | 38.49% / 27.59% / 20.00% / 14.55% | 0.232 W |

These are local routed OOC gates, not full-top timing closure.  The supplied
full-top baseline remains WNS `-1.600 ns`, TNS `-2053.791 ns`, and WHS
`+0.017 ns`; a fresh full-top implementation is required before accepting or
rejecting this candidate for integration.

## Recommendation

Retain the RTL candidate pending the parent's fresh full-top rerun.  The local
10 ns setup/hold gates and exact functional tests pass, with no ABI or
architecture change.  If the full-top critical path merely moves to a
different cone or remains negative, revert this candidate rather than claiming
closure; the two-cycle-per-PW-result cost is already included in the exact
999,014-cycle fullnet measurement and remains below the 2M-cycle limit.
