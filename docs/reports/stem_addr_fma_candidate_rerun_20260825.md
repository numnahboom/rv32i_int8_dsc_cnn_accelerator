# Stem ADDR->F->M->A candidate rerun

Date: 2026-08-25 18:10 CST  
Tool: Vivado 2025.2, `xc7z020clg400-1`, 8.000 ns clock

This is a fresh candidate build from the current RTL, not the earlier DCP.
The candidate registers three address lanes, six operands, three DSP-forced
products, three accumulation lanes, a 33-bit Pair register, and a 34-bit
Total register. The non-final MAC path explicitly returns to `ST_MAC` after
the accumulator stage; this was functionally checked after correcting that
state transition.

## Functional evidence

All four required candidate tests pass with the candidate RTL:

| Test | Result |
| --- | --- |
| `tb_conv3x3_stem_engine_new_requant` | PASS, writes=16, cycles=674 |
| `tb_cnn_top_tiled_stem_datapath` | PASS, checks=16,384 |
| `tb_cnn_top_sram_stem_dsblock_datapath` | PASS, checks=576 |
| `tb_cnn_top_fullnet_sram_datapath` | PASS, checks=10, errors=0, hw_cycles=1,486,759 |

The full-network cycle count remains below the 2.0M requirement.

## Fresh post-route evidence

Evidence directory: `build/reports/vivado_stem_addr_fma_candidate_20260825_retry3`  
RTL SHA-256: `4B95DA28939A2E77EF2B664A3FB2BD971BF3C46173117CE687A7A5A26BA1F323`  
Post-route DCP timestamp: `2026-08-25 18:10:25`, size 1,188,907 bytes.

Routing completed with 0 routing errors and 2,256/2,256 routable nets fully
routed. Overall post-route timing is not closed: WNS=`-6.766 ns`,
WHS=`+0.151 ns`, TNS=`-968.891 ns`.

The intended internal setup/hold gates (worst path in each report) are:

| Cone | Setup slack | Hold slack |
| --- | ---: | ---: |
| address -> operand | +2.469 ns | +0.238 ns |
| operand -> product | +0.889 ns | +1.027 ns |
| product -> lane | +2.627 ns | +0.842 ns |
| lane feedback | +3.265 ns | +0.193 ns |
| lane -> Pair | +3.338 ns | +0.551 ns |
| Pair -> Total | +3.371 ns | +0.674 ns |

All six intended stage gates meet setup >= +0.5 ns and hold >= 0 ns. The
dynamic Tcl audit discovers the actual post-route cells/pins and records them
in `discovered_groups.txt` and `discovered_dsp_mapping.txt`; it does not rely
on stale endpoint names. A scalar discovered address-Q to lane-D bypass audit
reports `No timing paths found`, consistent with the registered operand and
product stages. The total/bias-to-`rq_sum_reg` query fails loudly because
Vivado optimized that endpoint into downstream arithmetic; no pass is claimed
for that cone.

Post-route isolated utilization is 1,434 Slice LUTs, 692 Slice Registers,
16 DSPs, and 0 BRAM18/36 primitives. Power was not run for this isolated
candidate, and overall WNS is negative; therefore this candidate is rejected
and no full-top P&R is justified.
