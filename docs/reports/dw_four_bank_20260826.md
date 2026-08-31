# DW channel-interleaved four-bank tile buffer

Date: 2026-08-26. This candidate is based on the wide feature-store baseline
(`858,576` fullnet cycles). It keeps the scalar DW fusion module for the
legacy interface and routes the memory-oriented DS engine through a dedicated
vector implementation.

## Implementation

* `dw_tile_buffer_bram` is now four channel-interleaved 64-bit BRAM banks.
  Bank `channel[1:0]` stores the eight spatial pixels for that channel. Scalar
  reads retain the original one-cycle, one-channel/8-pixel ABI. A vector write
  commits four channel bytes to the four banks in one cycle with a byte mask.
* `dw_tile_fusion_engine_vector4` retains the existing 16-lane DW MAC and
  submits four contiguous channel groups through `requant_activation_stream4`.
  The stream has four unchanged ten-stage `requant_activation_unit` lanes and
  accepts one quartet per cycle. The DS engine consumes one four-byte result
  transaction per cycle and masks tail channels.
* `dw_tile_fusion_engine_new` remains the scalar, ready/stall-compatible
  implementation used by its existing direct regression. No external ABI or
  fixed-point arithmetic was changed.

## Functional verification

Commands (run serially with the shared XSim lock):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_dw_tile_buffer_bram
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_dw_tile_fusion_engine_new
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_ds_block_tile_engine_new
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_top_dsblock_datapath,tb_cnn_top_backpressure,tb_cnn_top_tiled_dsblock_datapath,tb_cnn_top_sram_tiled_dsblock_datapath,tb_cnn_top_fullnet_sram_datapath
```

Results:

* `tb_dw_tile_buffer_bram`: PASS, 9,355 randomized scalar byte/read cycles.
* `tb_dw_tile_buffer_bram_vec4`: PASS, 4 vector-write/read bank checks.
* `tb_dw_tile_fusion_engine_new`: PASS, 3 cases; scalar backpressure/order
  compatibility retained.
* `tb_ds_block_tile_engine_new`: PASS, 7 cases, 2,191 checks.
* Top DS, backpressure, tiled DS, SRAM-tiled DS: PASS (768, 768, 2,256 and
  480 checks respectively).
* Fullnet: 10/10 exact logits PASS, `818,184 cycles`, `5,136,896 MACs`,
  `78,890` memory reads and 10 external writes. This is 40,392 cycles
  (`4.706%`) below the wide-store `858,576` baseline.

Verilator command:

```bash
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && GENERATE_TEST_VECTORS=0 SIM_ONLY="tb_dw_tile_fusion_engine_new tb_ds_block_tile_engine_new" SIM_CONTINUE_ON_FAIL=0 SIM_LOG_DIR=build/reports/verilator_dw_four_bank_20260826 bash scripts/run_all_sims.sh'
```

Result: both selected simulations PASS. The DWBlock performance cases were
`1701/646/869/401/349/816/5675` cycles, with the expected PW issue counts.
The independent Verilator fullnet run also passed 10/10 checks at
`818,184 cycles`, `78,890` reads and 10 writes.

## OOC implementation evidence

Both runs target `xc7z020clg400-1`, Vivado 2025.2, an 8 ns clock:

| Module | WNS | TNS | WHS | route | LUT | FF | BRAM36 | DSP | power |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| `dw_tile_buffer_bram` | +6.782 ns | 0 | +0.255 ns | 0 unrouted | 174 (0.33%) | 0 | 4 (2.86%) | 0 | 0.114 W |
| `dw_tile_fusion_engine_vector4` | -4.944 ns | -4,771.726 ns | +0.098 ns | 0 unrouted | 13,280 (24.96%) | 10,392 (9.77%) | 0 | 16 (7.27%) | 0.208 W |

The vector fusion module does not meet an isolated 125 MHz constraint; this is
module-level fabric evidence, not timing closure. The BRAM bank itself is
comfortably within timing. The vector implementation uses one four-lane
stream (16 DSPs), rather than four replicated vector wrappers.

No complete `cnn_top` Explore routed OOC was run for this candidate. Therefore
there is no claim here of top-level 125 MHz closure, post-route full-design
power, or final resource closure. The measured cycle improvement is retained
for the next top-level timing experiment because it is functionally exact and
the module resource usage remains below the requested 70% per-resource bound;
the negative vector-fusion WNS is the principal remaining risk.
