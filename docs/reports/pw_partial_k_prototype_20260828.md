# PW tagged partial-K prototype

Date: 2026-08-28  
Device: `xc7z020clg400-1`  
Scope: `pw_systolic_array_8x8` and the memory-oriented
`ds_block_tile_engine_new`; the DW-to-PW phase barrier and external SRAM ABI
are unchanged.

## Contract and implementation

The PW array now accepts `first_k`, `last_k`, `k_group`, and `k_count` on every
accepted K token. `first_k` and `last_k` mark the whole reduction, while
`k_group` and `k_count` identify and size a contiguous K group. Thus a group
boundary cannot release the array merely because the legacy `k_last` happens
to be asserted there. Old users with `k_count=0` retain the `clear_acc` /
`k_last` spelling.

This first-stage prototype retains the existing replay RAM and two 4-column
half replays. All tagged groups are buffered before compute; only the final
`last_k` starts the replay, and no intermediate group is requantized or
written. The first token is the only token allowed to set the PE clear bit.
The lower-half result is still fenced into `first_psum` before the upper-half
replay, so the 8x8 output layout and signed arithmetic remain unchanged.
The live group tracker rejects malformed id/count fences from clearing a
reduction, and simulation monitors count accepted tokens and all 32-lane MAC
issues.

`ds_block_tile_engine_new` emits 16-entry group metadata (with a short final
tail group) while preserving its existing issue sequence. No runner, Stem, or
external SRAM interface was changed.

## Validation

* `verilator --lint-only` passed for the tagged PW test.
* `tb_pw_systolic_array_8x8_partial_k`: 2 cases, `Cin=32/48`, nonuniform
  group sizes including a tail, 128 exact signed psum checks, three-cycle
  output backpressure, and adversarial legacy `k_last` at non-final group
  boundaries: PASS.
* Existing `tb_pw_systolic_array_8x8_backpressure`: PASS.
* `tb_ds_block_tile_engine_new`: 7 cases / 2,191 checks: PASS.
* `tb_cnn_top_fullnet_sram_datapath`: exact logits, 10 checks, status 0,
  `hw_cycles=1,003,577`, `mem_reads=78,890`, `mem_writes=10`: PASS.
  The cycle count is unchanged from the retained baseline; no throughput
  improvement is claimed.

## 8 ns routed OOC screen

Reports are under
`build/reports/vivado_pw_partial_k_ooc_20260828/` and
`build/reports/vivado_ds_partial_k_ooc_20260828/`. Both runs used Vivado
2025.2 and routed cleanly with zero routing errors.

| OOC top | WNS (ns) | TNS (ns) | WHS (ns) | THS (ns) | LUT | FF | DSP | BRAM | Power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| PW array | -0.826 | -200.001 | +0.098 | 0 | 7.45% | 4.00% | 0% | 0% | 0.164 W |
| DSBlock | -1.115 | -1084.665 | +0.096 | 0 | 38.08% | 27.64% | 14.55% | 0% | 0.263 W |

The local 125 MHz setup gate therefore fails. The PW worst paths have about
4.4 ns logic and 4.4 ns route delay; the DSBlock worst paths are in the DW
parameter-load cone (`dw_param_lane` to `dw_weight_vec`) with about 3.1 ns
logic and 6.0 ns route delay. This is a timing limitation of the retained
control/dataflow cone, not a functional or routing failure. The prototype
does not improve cycles or energy and should be treated as a correctness and
protocol foundation only; a later architectural change is required before
using it to justify DW/PW overlap or an energy claim.
