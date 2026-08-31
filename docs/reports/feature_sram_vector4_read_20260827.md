# Feature-SRAM aligned vector4 read candidate

## Scope

The tiled SRAM loader now consumes an aligned 32-bit feature-SRAM word when
four input channels remain in the current pixel and destination 16-channel
tile. Misaligned addresses, channel tails, padding, and cross-tile cases keep
the scalar path. The word-response cursor now performs the same pixel and row
wrap as four scalar responses; this fixes the previously incomplete boundary
case where an exact channel-end word left the cursor at `in_c`.

## Functional evidence

Current-tree focused gates (generated vectors disabled):

* `tb_feature_sram_bank_word_read`: PASS, 2 checks.
* `tb_cnn_top_sram_tiled_dsblock_datapath`: PASS.
* `tb_cnn_top_fullnet_sram_datapath`: PASS, 10/10 exact logits.

The stem/DS SRAM and backpressure passes listed in the earlier candidate
record remain historical evidence; they were not rerun in this focused gate.

Commands used for the current focused gates:

```text
.\scripts\run_cnn_xsim.ps1 -Tests @('tb_feature_sram_bank_word_read','tb_cnn_top_sram_tiled_dsblock_datapath','tb_cnn_top_fullnet_sram_datapath') -VivadoBin 'D:\Software\Xilinx\Vivado\2021.2\bin'
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_feature_sram_bank_word_read"
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_cnn_top_sram_tiled_dsblock_datapath"
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && ./build/verilator/tb_cnn_top_fullnet_sram_datapath/Vtb_cnn_top_fullnet_sram_datapath"
```

The current integrated vector-read fullnet measured **958,174 cycles**. It
remains below the 2.0M-cycle limit with the same 5,136,896 MAC network and
external traffic (78,890 reads, 10 writes). The earlier 813,913-cycle result
is a historical snapshot before later runner arithmetic/pipeline changes.
It performed 2,428, 2,312, and 144 word reads in layers 1, 2, and 3,
respectively; scalar fallback covered the remaining reads.

## Timing/resource screening

Command used for the current OOC synthesis screen:

```text
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts/vivado_cnn_top_feature_read_ooc_20260827.tcl
```

Fresh Vivado 2025.2 synthesis OOC at 8.000 ns for `xc7z020clg400-1` completed
with WNS -8.412 ns, TNS -5,940.615 ns, and WHS +0.189 ns. Synthesis used
37,537 LUT (70.56%), 35,707 FF (33.56%), 48 BRAM36 (34.29%), and 70 DSP
(31.82%). This is not a candidate for full Explore routing or final closure:
the LUT gate remains 297 LUT above the strict 70% limit and setup is deeply
negative. The critical path is the `store_idx`-to-output-buffer BRAM enable
chain in `cnn_layer_runner` (28 logic levels, 15.885 ns data delay).

## Follow-up timing candidate

`ST_TILED_LOAD_AREA`/`ST_TILED_LOAD_COUNT` and `ST_LOAD_COUNT_DECIDE` remain
present in the current runner and are covered by the exact fullnet gate.
Neither pipeline establishes post-route closure; the fresh current-tree
synthesis screening value remains above the objective gate and the active
critical endpoint is the output-buffer BRAM enable chain. No full-top
post-route implementation or power result is implied by this OOC synthesis.
