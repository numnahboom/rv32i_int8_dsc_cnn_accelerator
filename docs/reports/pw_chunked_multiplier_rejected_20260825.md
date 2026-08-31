# PW chunked multiplier candidate — rejected

Date: 2026-08-25  
Tool: Vivado 2025.2 (v2025.2)  
Part: `xc7z020clg400-1`  
Clock: 8.000 ns

The isolated requant candidate was synthesized out-of-context with the
explicit Vivado executable at
`D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat`.

The partial-product implementation synthesized to four DSP48E1 instances and
113 CARRY4 cells.  However, the 8 ns setup gate failed:

| Metric | Result |
|---|---:|
| Worst setup slack | -1.691 ns |
| Worst max path delay | 9.684 ns |
| Worst path logic levels | 23 (17 CARRY4) |
| Setup failing endpoints | 39 |
| Total setup violation | -45.516 ns |
| Worst hold slack | +0.263 ns |
| LUTs | 562 |
| FFs | 722 |
| DSPs | 4 |
| BRAM | 0 |

The worst endpoint was `shifted_s4_reg[0]/D`; the path was dominated by the
partial-sum/rounding carry cone.  Since the local max delay exceeded 8 ns and
WNS was negative, the candidate was rejected before full-top P&R.

The candidate's partial-product RTL and 7-stage tag changes were restored.
The pre-existing descriptor-local operand staging in
`ds_block_tile_engine_new.v` was preserved.  No full-top Explore run was
started because the isolated gate failed.

Evidence files:

- `build/reports/pw_candidate_ooc/requant_activation_unit/timing_summary_max.txt`
- `build/reports/pw_candidate_ooc/requant_activation_unit/timing_summary_min.txt`
- `build/reports/pw_candidate_ooc/requant_activation_unit/timing_maxpaths.txt`
- `build/reports/pw_candidate_ooc/requant_activation_unit/utilization.txt`
