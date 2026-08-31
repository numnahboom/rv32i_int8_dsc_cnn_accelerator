# Row-local 4-lane DS/PW macro (2026-08-31)

## Functional validation

The direct macro regression is run with Verilator 5.020:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_rowlocal_4lane_macro_sim.sh"
```

The test covers three K lengths (16, 128, and 9), spatial/channel masks,
configuration of both islands, and irregular output backpressure.  The
expected result was corrected to compare the complete 32-bit four-lane word;
the earlier 8-bit comparison retained only the last expected lane and caused
false mismatches.

```text
PASS ds_rowlocal_4lane_macro outputs=48 tokens=153 cycles=313
token_ii=1..33 out_ii=1..142 max_occupancy=16 final_occupancy=0
```

The feed-integrated regression uses the real non-zero
`ds_persistent_feed_contract_bram` ABI and independent source/parameter
responders:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_rowlocal_4lane_feed_macro_sim.sh"
```

DS1/Cin16, DS3/Cin64, and DS6/Cin128 each passed token metadata, all 8
activation lanes, all 8 parameter/weight lanes, external load traffic,
independent request backpressure, output backpressure, and exactly-once output
count.  The compute multiplier is deliberately zero in this path, making the
output reference zero while the non-zero feed payload is checked independently.

```text
LEDGER DS1 rowlocal tokens=16 outputs=16 token_ii=1..1 out_ii=1..2 row_occ_max=16 nonzero_act/wgt=128/127
LEDGER DS3 rowlocal tokens=64 outputs=16 token_ii=1..1 out_ii=1..2 row_occ_max=16 nonzero_act/wgt=638/637
LEDGER DS6 rowlocal tokens=128 outputs=16 token_ii=1..1 out_ii=1..2 row_occ_max=16 nonzero_act/wgt=1658/1657
PASS ds_rowlocal_4lane_feed_macro DS1/DS3/DS6 total_outputs=48 max_row_occupancy=16 load_stalls=171/1637
```

## XC7Z020 8 ns OOC result

The OOC run was performed only after both functional regressions passed:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts\vivado_ds_rowlocal_4lane_macro_ooc_20260831.tcl
```

Target is `xc7z020clg400-1`, Vivado 2025.2, `general.maxThreads=2`, and an
8.000 ns clock.  The routed result is a negative timing screen:

| Metric | Post-route |
|---|---:|
| WNS / TNS / setup failing endpoints | -0.975 ns / -3560.928 ns / 12,194 |
| WHS / THS / hold failing endpoints | +0.098 ns / 0 / 0 |
| Slice LUTs | 14,372 / 53,200 (27.02%) |
| Slice registers | 31,347 / 106,400 (29.46%) |
| DSP48E1 | 16 / 220 (7.27%) |
| Block RAM tiles | 0 / 140 (0.00%) |
| Total on-chip power | 0.484 W |
| Routing errors | 0 |

The worst path is `issue_row_reg[0]` to `acc_mem_reg[0][3][0][19]`, with
8.462 ns data delay: 1.716 ns logic and 6.746 ns routing.  The dominant
problem is physical fanout/locality, not multiplier depth: `acc_mem[0]` has
2,125 loads, `issue_row[2]` 2,126 loads, `prod_reg[0]` 1,045 loads, and the
sideband mask net has 6,429 loads.  The routed design also reports about
86--91% local congestion hotspots.  Therefore this row-local macro is not a
candidate for full-top promotion in its current form, despite passing the
functional gate and using acceptable resources/power.

Reports are under
`build/reports/vivado_ds_rowlocal_4lane_macro_ooc_20260831/`.
