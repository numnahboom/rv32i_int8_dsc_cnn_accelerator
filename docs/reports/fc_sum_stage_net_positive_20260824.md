# FC descriptor-local sum stage (2026-08-24)

## Candidate

`rtl/cnn/fc_unit_new.v` now separates the FC accumulator-plus-bias operation
from the multiplier issue.  `ST_RUN` captures the exact 33-bit signed sum and
class tag; `ST_ISSUE_PRODUCT` multiplies that descriptor and drives the
existing `requant_product_pipeline`.  Requant responses are consumed in both
states, preserving the pipeline tag/valid semantics.  The external
configuration, start/done, output-read, precision, and single-outstanding
contracts are unchanged.

This costs one internal cycle per FC output class (10 cycles per FC operation)
and removes the class-index/LUTRAM selection plus 33-bit carry chain from the
same cycle as the DSP product register.  The sum is 33 bits so signed overflow
behavior matches the previous sign-extended 64-bit addition.

## Functional evidence

Commands:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && SIM_ONLY="tb_fc_unit" SIM_LOG_DIR=build/reports/sim_fc_sum_pipeline ./scripts/run_all_sims.sh'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && SIM_ONLY="tb_cnn_top_fullnet_sram_datapath" SIM_LOG_DIR=build/reports/sim_fc_sum_fullnet2 ./scripts/run_all_sims.sh'
& .\scripts\run_cnn_xsim.ps1 -Tests tb_cnn_top_tail_sram_datapath -VivadoBin 'D:\Software\Xilinx\Vivado\2021.2\bin'
```

Results: Verilator FC 2/2 cases, 20/20 checks PASS; Verilator fullnet 1/1
case, 10/10 logits PASS, `hw_cycles=995230`; XSim tail 1/1 PASS, 10/10
checks.  The fullnet cycle count remains below the 2M-cycle objective.  The
10-cycle FC-local expectation is visible in the changed FSM; no network
operation or precision was removed.

## Routed OOC Explore evidence

Command:

```text
& .\scripts\run_cnn_impl.ps1 -Vivado 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -Part xc7z020clg400-1 -Top cnn_top -Directive Explore
```

Candidate run: `build/reports/vivado_cnn_top_impl/runs/20260824T194850696-27908/`.
The design routed with zero unrouted nets.  The timing summary and report are
post-route OOC only; setup remains open and therefore this is not timing
closure or board validation.

| result | WNS (ns) | TNS (ns) | failing endpoints | WHS (ns) | THS (ns) | route |
|---|---:|---:|---:|---:|---:|---|
| descriptor-local baseline | -6.997 | -26365.537 | not retained in baseline report | +0.061 | 0.000 | 0 unrouted |
| sum-stage candidate | -6.520 | -22702.494 | 10436 | +0.050 | 0.000 | 0 unrouted |

Relative to the current baseline, WNS improves by `+0.477 ns` and TNS by
`+3663.043 ns`; WHS decreases by `0.011 ns` but remains positive and THS
remains clean.  The dominant setup family moves away from the FC
`class_idx -> bias/acc LUTRAM -> carry -> 3-DSP` path to a tiled-store address
path (`stride_reg -> tiled_store_addr_current`), which is useful endpoint
coverage evidence that the FC cone was materially shortened.  The new worst
path is `-6.520 ns`, so Fmax closure is not yet reached (the 100 MHz OOC
constraint still fails).

Post-route resources are 30,375 LUT (57.10%), 19,183 FF (18.03%), 46 BRAM
tiles (32.86%), and 50 DSP (22.73%).  Vectorless estimated total on-chip
power is 0.220 W (0.114 W dynamic + 0.107 W static), below the 3 W objective.

## Decision and trade-off

Keep this candidate.  It is functionally bit-exact on the direct FC, XSim
tail, and fullnet gates; has positive/clean hold; and improves both setup
slack and aggregate setup debt by a large margin.  The small WHS regression
is measurable but not a hold failure.  The 10 FC cycles are a bounded latency
cost and fullnet remains under 2M cycles.  Since the new endpoint family is
different, this stage composes cleanly with a future address/control-fanout
optimization.  It is a net engineering improvement even though it does not
close timing and slightly reduces positive hold margin.

