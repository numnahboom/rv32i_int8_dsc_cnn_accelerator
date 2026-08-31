# Tiled external-load request-enable pipeline (2026-08-28)

## Scope

This candidate changes only `rtl/cnn/cnn_layer_runner.v` and the matching
routed-DCP query script.  It isolates the external tiled-load request issue
from the padding/channel decision by adding `ST_TILED_LOAD_MEM_REQ`.

`ST_TILED_LOAD_REQ` still handles padding, SRAM scalar loads, and SRAM vector4
loads.  For external tiled input, it unconditionally transfers to the new
issue state.  The issue state holds `mem_req_valid` and computes the address
from the already-registered tiled input cursor, waiting for
`mem_req_ready` before entering the existing response state.  Response-side
look-ahead no longer drives `mem_req_addr` directly.  This preserves one
outstanding request, ready stalls, padding/fallback behavior, and scalar/
vector4 SRAM sequencing; it adds one setup cycle per external tiled request.

## Validation

Focused Vivado XSim:

```text
scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_top_backpressure,tb_cnn_top_tiled_stem_datapath,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath
```

Result: `PASS cnn_xsim_regression tests=4` with 768, 16,384, 2,256, and 480
checks respectively.

Fullnet Verilator:

```text
GENERATE_TEST_VECTORS=0 SIM_ONLY='tb_cnn_top_fullnet_sram_datapath' SIM_LOG_DIR=build/reports/verilator_tiled_load_req_enable_20260828 ./scripts/run_all_sims.sh
```

Result: `PASS`, `hw_cycles=1003346`, `mem_reads=78890`, `mem_writes=10`,
`checks=10`, `errors=0`, status `0x0f4f5282`.  The test's exact-logit checks
passed.

Runner-only XC7Z020 post-route screen used 10 ns and
`scripts/vivado_cnn_layer_runner_tiled_store_recurrence_20260827.tcl`:

| Metric | Result |
| --- | ---: |
| Post-route WNS | -2.660 ns |
| Post-route TNS | -2146.764 ns |
| Post-route WHS | +0.080 ns |
| Slice LUTs | 33,623 (63.20%) |
| Slice registers | 34,668 (32.58%) |
| DSPs | 70 (31.82%) |
| BRAM tiles | 32 (22.86%) |
| Estimated total on-chip power | 0.240 W |
| Unrouted nets | 0 |

The routed DCP query in
`scripts/query_runner_tiled_load_req_enable_20260828.tcl` reports zero timing
paths from `tiled_load_channel_reg*/C` to both `mem_req_addr_reg*/CE` and
`mem_req_addr_reg*/D`.  The runner-only WNS remains negative and is not
full-top timing evidence.
