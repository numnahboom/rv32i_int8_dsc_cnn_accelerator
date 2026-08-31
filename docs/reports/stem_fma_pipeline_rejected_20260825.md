# Stem F/M/A pipeline candidate — rejected by private 8 ns OOC gate

Date: 2026-08-25  
Tool: Vivado 2025.2  
Part: `xc7z020clg400-1`  
Candidate: `conv3x3_stem_engine_new.v`

The candidate implemented overlapped F/M/A stages with registered six-byte
operands, three signed 16-bit products, three signed 32-bit accumulation
lanes, and registered 33/34-bit Pair/Total reduction. The pipeline was fully
drained before Pair and preserved the existing signed requantization path.

## Functional gate

The four required XSim tests passed bit-exactly. Stem standalone completed in
274 cycles; full-network hardware latency was 1,077,159 cycles, below the
candidate screening limit of 1.10M cycles.

## Fresh 8 ns private OOC result

Vivado 2025.2 synthesis, placement, physical optimization, and routing all
completed with zero route errors and zero unrouted nets. The candidate is
rejected because the required internal setup gate was not met:

| Cone | Worst setup slack | Worst hold slack |
| --- | ---: | ---: |
| cursor/LUTRAM to operand | -0.372 ns | +0.481 ns |
| operand to product | +0.361 ns | +0.425 ns |
| product to lane | +3.533 ns | +0.524 ns |
| lane feedback | +3.672 ns | +0.467 ns |
| lane to Pair | +4.593 ns | +0.263 ns |
| Pair to Total | +4.735 ns | +0.318 ns |

The required threshold was setup >= +0.5 ns and hold >= 0 ns for every
listed cone. The total+bias-to-requant-sum endpoint was optimized into the
downstream arithmetic by Vivado and had no legal named `rq_sum_reg` endpoint
for an isolated query; it cannot be claimed as passing. RTL structure and the
product-to-lane reports show no cursor/operand direct bypass into lane D pins.

Overall post-route timing was WNS `-6.178 ns`, TNS `-857.532 ns`, WHS
`+0.155 ns`, THS `0.000 ns`.

Post-route utilization was 1,658 Slice LUTs (1,178 logic + 480 distributed
RAM), 641 Slice registers, 0 BRAM tiles, and 10 DSPs. Full-top Explore was
not run because the private Stem gate failed.

Evidence:

- `build/reports/vivado_conv3x3_stem_engine_new/timing_summary_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/timing_hold_summary_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/{cursor_to_operand,operand_to_product,product_to_lane,lane_feedback,lane_to_pair,pair_to_total}_{max,min}.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/utilization_8ns_post_route.txt`
- `build/reports/vivado_conv3x3_stem_engine_new/conv3x3_stem_engine_new_8ns_post_route.dcp`
