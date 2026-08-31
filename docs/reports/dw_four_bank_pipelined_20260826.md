# DW four-bank fusion: registered MAC pipeline

Date: 2026-08-26

This report records the timing candidate layered on top of the verified
channel-interleaved four-bank DW tile buffer.  The four-bank storage and
vector4 output protocol are unchanged; the RTL change is in
`rtl/cnn/dw_mac_lanes.v`, which is instantiated by
`dw_tile_fusion_engine_vector4`.

## Change

The former DW MAC cycle selected a row dynamically and combined three 8x8
products, two row additions, and the 32-bit accumulator carry chain in one
clock period.  Each lane now has fixed current-row registers and registered
future rows.  A single outstanding window advances through:

1. registered lane/tap operands and product stage;
2. registered three-product row sum;
3. registered 32-bit accumulation.

The three rows still use the same signed 8-bit products and the same 32-bit
wraparound arithmetic.  `ready_in`, `valid_out`, `ready_out`, `busy`, and
single-outstanding behavior remain unchanged.  No MAC, precision, external
ABI, or network operation was removed.

## Functional verification

All XSim invocations were run serially through the shared lock:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_dw_tile_fusion_engine_new
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_ds_block_tile_engine_new,tb_cnn_top_dsblock_datapath,tb_cnn_top_backpressure,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_top_fullnet_sram_datapath
```

Results:

* DW fusion direct: `PASS`, 3 cases.
* DS block: `PASS`, 7 cases, 2,191 checks.
* Top DS/backpressure/tiled/SRAM-tiled: `PASS` (768, 768, 2,256, and 480
  checks).
* Fullnet: `PASS`, 10/10 exact logits, `838,344 cycles`, `5,136,896 MACs`,
  78,890 memory reads, and 10 external writes.

The four-bank predecessor was `818,184 cycles`; this pipeline adds exactly
`20,160 cycles` (6 cycles per 3,360 DW output windows) while retaining the
same logits and operation count.  The result remains below the 2.0M-cycle
limit.  Fullnet throughput at 100 MHz is approximately 8.383 ms.

The post-change Verilator command was:

```bash
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_dw_tile_fusion_engine_new tb_ds_block_tile_engine_new tb_cnn_top_backpressure tb_cnn_top_tiled_dsblock_datapath tb_cnn_top_sram_tiled_dsblock_datapath tb_cnn_top_fullnet_sram_datapath" SIM_CONTINUE_ON_FAIL=0 SIM_LOG_DIR=build/reports/verilator_dw_four_bank_pipelined_20260826 bash scripts/run_all_sims.sh'
```

All six selected simulations passed.  The fullnet row reports
`hw_cycles=838344`, `checks=10`, `errors=0`.

## Fusion OOC implementation

Exact command:

```powershell
& D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_dw_tile_fusion_vector4_ooc_20260826.tcl -nolog -nojournal -notrace
```

The run targeted `xc7z020clg400-1`, Vivado 2025.2, an 8.000 ns clock, and
completed synthesis, placement, routing, timing, utilization, power, DRC,
and checkpoint generation.  Reports are in
`build/reports/vivado_dw_tile_fusion_vector4_ooc_20260826/`.

| Candidate | WNS | TNS | WHS | Route errors | LUT | FF | BRAM36 | DSP | total on-chip power |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Previous vector4 | -4.944 ns | -4,771.726 ns | +0.098 ns | 0 | 13,280 | 10,392 | 0 | 16 | 0.208 W |
| Registered MAC pipeline | **+0.263 ns** | **0 ns** | +0.096 ns | 0 | 7,378 | 11,429 | 0 | 16 | 0.211 W |

The previous critical endpoint was the dynamic `cycle_idx`-to-accumulator
path.  After staging, the worst reported setup endpoint is the line-buffer
window-control path into a registered DW operand enable:

```text
Source      u_dw_line_buffer/window_x_idx_reg[1]/C
Destination u_dw_mac_lanes/pixel_cur2_reg[8][7]/CE
Data delay  7.448 ns (logic 1.324 ns, route 6.124 ns)
Logic       7 levels
```

The isolated fusion result has zero failing setup/hold endpoints and zero
routing errors.  It meets the 125 MHz isolated module constraint, although
the margin is only 0.263 ns and the critical path is now control/routing
dominated.

## Boundary and decision

This is module-level OOC evidence only.  No complete `cnn_top` Explore routed
OOC was run for this candidate, so it does not establish full-top WNS/TNS,
full-design resource closure, board timing, or post-implementation full-top
power.  The candidate is functionally exact and has zero-TNS fusion OOC timing;
it is suitable for the next top-level timing experiment.  The added latency
is bounded and leaves substantial cycle headroom, while the fusion module
resource usage remains below 70% of the XC7Z020 resources.

`git diff --check` passed for the working tree after this report was written.
