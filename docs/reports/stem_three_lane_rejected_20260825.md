# Stem three-lane MAC candidate — rejected after 8 ns OOC gate

Date: 2026-08-25  
Part: `xc7z020clg400-1`  
Tool: Vivado 2025.2 (`D:/Software/vivado2025.2/2025.2/Vivado/bin/vivado.bat`)

The candidate temporarily split the 3x3 MAC into three independent 32-bit
accumulators, added registered 33-bit pair and 34-bit total sums, and retained
the exact signed requantization path. Vivado mapped the three lane accumulators
to three `DSP48E1` cells (`lane0_acc0`, `lane1_acc0`, `lane2_acc0`). The pair and
total add stages also mapped to `DSP48E1` (`lane_pair_reg0`, `lane_total_reg0`).

## Functional gate

All requested XSim tests passed with the candidate:

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_requant` | PASS, writes=16, cycles=242 |
| `tb_cnn_top_tiled_stem_datapath` | PASS, checks=16,384 |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, checks=576 |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, checks=10 |

The full-net hardware cycle count was `1,044,391` (the report wrapper's
default 1,000,000-cycle policy rejected report generation; this is a stale
report-policy limit, not a simulation failure).

## Private 8 ns routed screen

The isolated Stem OOC run completed synthesis, placement, physical
optimization, and routing with zero route errors/unrouted nets. Overall timing
was not a pass: WNS `-6.603 ns`, TNS `-1470.591 ns`, WHS `+0.122 ns`, THS
`0.000 ns`. The negative overall setup result is dominated by the existing
wide requantization product chain, which is outside the new lane/pair/total
cone.

The new registered internal cones that could be measured independently were
positive:

| Cone | Setup slack | Hold slack |
| --- | ---: | ---: |
| lane feedback (`lane*_acc0` to its C input) | +3.860 ns | +0.815 ns |
| lane to pair (`lane*_acc0` to `lane_pair_reg0`) | +3.687 ns | +0.888 ns |
| pair to total (`lane_pair_reg0` to `lane_total_reg0`) | +2.221 ns | +1.373 ns |

The cursor-to-lane A/B data-pin query has no legal sequential timing endpoint.
The routed worst path report nevertheless shows `input_addr_cursor_reg[1]/Q`
arriving at `lane0_acc0/P[24]` at `10.179 ns` from a `1.491 ns` launch, i.e.
`8.688 ns` data delay before the lane output feeds the pair stage. Therefore
the required cursor-to-lane <=8 ns gate cannot be claimed. Full top-level P&R
was intentionally not run.

Evidence files:

- `build/reports/vivado_conv3x3_stem_engine_new/conv3x3_stem_engine_new_8ns_post_route.dcp`
- `build/reports/vivado_conv3x3_stem_engine_new/timing_summary_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/timing_hold_summary_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/timing_maxpaths_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/lane_feedback_{max,min}.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/lane_to_pair_dsp_{max,min}.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/pair_to_total_dsp_{max,min}.txt`

The three-lane candidate was removed after this gate; unrelated worktree
changes were preserved.
