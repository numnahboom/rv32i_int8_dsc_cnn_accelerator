# EdgeMBConv HW candidate D4 physical composition

This is an independent D4 screening artifact. It does not modify C0, the D4
network description, the existing D4 block shell, or any legacy RTL.

## Composition

| island | implementation | DSP48E1 |
|---|---|---:|
| PW dedicated | seven pixels × sixteen Cout, registered INT8 products and INT32 output-stationary accumulation | 112 |
| shared pool | existing D4 dual-mode pool; eighth PW pixel in PW mode, four exact RQ lanes in RQ mode | 16 |
| DW/source | sixteen registered INT8 DW products plus two registered address products (`x*stride`, `(y*stride)*input_width`) | 18 |
| **total** | observable composite top | **146** |

The composite PW interface therefore represents all `8 × 16 = 128` lanes per
K token: lanes 0..111 come from the dedicated island and lanes 112..127 from
the shared pool. The pool and dedicated side are joined only at the reduction
boundary; the top-level mode lock prevents a PW reduction from being mixed
with an RQ transaction.

## Functional evidence

`sim/tb_edgembconv_hwacandidate_d4_composite_datapath.v` was run with Vivado
2025.2 XSim. It checks:

- all 128 PW lanes for a three-token INT8 reduction;
- mode-boundary transition from PW to an existing generated D4 coefficient /
  shift vector, including exact RQ product/result and output holding;
- DW16 raw sums for real stride 1 and stride 2 coordinates;
- synchronous source response, source stalls, output stalls, and output
  stability while stalled.

Result:

```text
PASS edgembconv_hwacandidate_d4_composite_datapath mapping=112PW+16dual+18DW stalls=checked
```

The reproducible entry point is
`scripts/run_edgembconv_hwacandidate_d4_composite_datapath_sim.ps1`.

The composite subsequently gained a one-cycle RQ transaction-lifetime fence
at the output-copy boundary.  Its standalone PW/RQ/DW regression remains
passing, and the guarded composite is the instance used by the complete
`mb16_down` controller gate.  The OOC figures below predate that function-only
acceptance guard and are retained as historical physical-screen evidence, not
as a fresh post-route result for the guarded RTL.

## Fresh XC7Z020 OOC post-route screen

Part: `xc7z020clg400-1`; clock: 8.000 ns (125 MHz); Vivado 2025.2;
`general.maxThreads=8`.

| metric | post-route result |
|---|---:|
| WNS | +0.041 ns |
| WHS | +0.097 ns |
| TNS / THS | 0 / 0 ns |
| LUT as Logic | 15,114 / 53,200 (28.41%) |
| FF | 19,091 / 106,400 (17.94%) |
| BRAM | 0 |
| DSP | 146 / 220 (66.36%) |
| Total on-chip power | 0.283 W |
| route errors | 0 |

The exact hierarchy count is recorded in
`build/reports/vivado_edgembconv_hwacandidate_d4_composite_datapath_ooc_threads8_20260902/run_settings.txt`:
112 dedicated PW DSPs, 16 shared-pool DSPs, 16 DW channel DSPs, and 2 DW
scheduler DSPs. The complete reports are in that same directory. The
reproducible OOC entry point is
`scripts/run_edgembconv_hwacandidate_d4_composite_datapath_ooc_threads8_20260902.ps1`.

## Boundary

This is a physical composition/rejection screen, not a complete D4 block or
full-network cycle result. It proves the intended 146-DSP resource mapping and
the local vector contracts; block-pair integration, full-network exact output
comparison, and end-to-end cycle/energy claims remain open.
