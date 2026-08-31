# PW output-stationary partial-K streaming prototype

Date: 2026-08-30  
Device: `xc7z020clg400-1`  
Clock screen: 8 ns (125 MHz)

## Scope

This is an isolated prototype for `pw_systolic_array_8x8`; it is not connected
to `ds_block_tile_engine_new`, the layer runner, or the full network. The
external block remains an 8-pixel x 8-cout transaction. The physical fabric is
8 x 4 and uses two output-channel halves.

The lower half now consumes each accepted K token immediately while a narrow
replay memory retains the token for the upper half. `first_k`/`last_k` describe
the complete reduction, while `k_group`/`k_count` describe a group. Group
boundaries never clear, close, requantize, or publish the accumulator. The
lower PE sums are captured into `first_psum` only after the final lower token's
registered PE update; the upper replay then clears the PE fabric exactly once
on its first token and retains its psum across all group boundaries. Legacy
`clear_acc`/`k_last` remains selected when `k_count==0`.

The PE 8x8 multiply is explicitly marked `use_dsp="yes"`. Vivado's default
heuristic mapped these small signed products to LUTs, leaving a 4 ns logic
multiplier plus accumulator path. The DSP mapping uses 32 DSP48 sites and
removes that local timing bottleneck without changing arithmetic width or MAC
count.

## Functional validation

Verilator 5.020 tests:

* `tb_pw_systolic_array_8x8_partial_k`: `Cin=32/48`, nonuniform groups and a
  short tail group, adversarial legacy `k_last`/`clear_acc` at intermediate
  group boundaries, signed nonzero data, and three-cycle output hold: PASS,
  128 exact 32-bit lane checks.
* `tb_pw_systolic_array_8x8_partial_k_random`: 51 independent blocks covering
  `Cin=32/48`, harness `P=1/8/17`, `Cout=8/16/13` (including a 5-channel tail),
  group sizes 7/13/16, random bubbles, held input metadata, output
  backpressure/stability, and independent signed reference sums: PASS,
  51 outputs and 5,712 valid-lane checks (including repeated held-output
  checks).

The simulation-only monitors check first-token ownership, group length and
fence ordering, absence of unexpected first tokens, and that no intermediate
group can close the whole transaction. The random test also checks exactly one
output per accepted block. The `P`/`Cout` dimensions are harness-level because
the fixed RTL ABI has no spatial or channel-mask ports; the Cout tail is
checked only for valid lanes and is not used as a computation shortcut.

## Routed OOC result

Run script: `scripts/vivado_pw_partial_k_streaming_ooc_20260830.tcl`  
Reports: `build/reports/vivado_pw_partial_k_streaming_ooc_20260830/`

| Metric | Post-route result |
|---|---:|
| WNS / TNS | +0.602 ns / 0.000 ns |
| Setup failing endpoints | 0 |
| WHS / THS | +0.067 ns / 0.000 ns |
| Hold failing endpoints | 0 |
| Slice LUTs | 802 (1.51%) |
| Slice registers | 3,211 (3.02%) |
| DSP | 32 (14.55%) |
| BRAM36 / BRAM18 | 0 / 0 |
| Total on-chip power | 0.161 W |
| Route errors | 0 |

The worst reported setup path is `capture_output_pending_reg/C` to
`psum_out_reg[1453]/CE`: 7.109 ns data delay (0.456 ns logic, 6.653 ns
routing in the detailed path report) against the 8 ns requirement. It is a
control fanout/output-capture path, not the signed PE multiplier path. The two
8K-bit replay memories were mapped to distributed RAM (`RAM64M`) rather than
BRAM by the OOC synthesis; this is reflected in the zero BRAM count and 512
LUT-as-memory usage included in the LUT total.

This is a local OOC gate only. It does not establish full-top timing, DS cycle
reduction, fullnet exact logits, or the end-to-end energy target.
