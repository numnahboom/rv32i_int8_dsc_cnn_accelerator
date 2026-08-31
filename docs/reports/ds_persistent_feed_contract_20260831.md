# DS persistent packed-bank feed ledger (2026-08-31)

Reproduce with `python scripts/model_ds_persistent_feed_contract.py`. The companion RTL test is `scripts/run_ds_persistent_feed_contract_sim.sh`.

## Measured RTL probes

The measured cycles include the request/response loader and the tested jobs; they are not full-layer runtime claims.

| probe | cfg/load cycles | job cycles | external source words | external param words | local source reads | local param row reads | reused windows |
|---|---:|---:|---:|---:|---:|---:|---:|
| DS1 PW, 3 jobs (two share pixel window) | 9563 | 187 | 4096 | 128 | 112 | 48 | 1 |
| DS3 PW, 2 jobs (same pixel window) | 9564 | 400 | 4096 | 1024 | 256 | 128 | 1 |
| DS6 PW, 2 jobs (same pixel window) | 18029 | 795 | 512 | 8192 | 512 | 256 | 1 |

Every accepted token was checked against the nonzero source/weight address reference. The TB applies independent source/parameter request bubbles and token backpressure; final aggregate was 432 tokens, 880 local source reads (window gathers plus token-row reads), 432 local parameter reads, and 3 window reuses. The first DS1 job uses a five-pixel/six-channel mask, proving the tail mask is captured independently of a reused source window.

## C10 traffic projection

| layer | shape (P,Cin,Cout) | dual32 source | packed external source | dual32 parameter | packed parameter | PW source once | PW parameter once |
|---|---|---:|---:|---:|---:|---:|---:|
| DS1 | (1024,16,32) | 20992 | 4096 | 25600 | 164 | 4096 | 128 |
| DS2 | (256,32,64) | 18688 | 2048 | 20992 | 584 | 2048 | 512 |
| DS3 | (256,64,64) | 37376 | 4096 | 41984 | 1168 | 4096 | 1024 |
| DS4 | (64,64,128) | 17536 | 1024 | 18688 | 2192 | 1024 | 2048 |
| DS5 | (64,128,128) | 35072 | 2048 | 37376 | 4384 | 2048 | 4096 |
| DS6 | (16,128,256) | 16960 | 2048 | 17536 | 8480 | 512 | 8192 |
| **DS subtotal** | | **146624** | **15360** | **162176** | **16972** | | |

The retained full-network dual32 reference is **154560 source + 190848 parameter words**. Keeping Stem/FC traffic unchanged and replacing only the six DS feed paths projects **23296 source + 45644 parameter words**. That is 84.9% fewer source transfers and 76.1% fewer parameter transfers. This is traffic projection, not a full-top cycle or timing result.

## XC7Z020 routed OOC evidence

The independent OOC run uses Vivado 2025.2, `xc7z020clg400-1`, an 8.000 ns clock, and the script `scripts/vivado_ds_persistent_feed_contract_ooc_20260831.tcl`. The routed checkpoint completed with zero route errors, but setup timing is not viable:

| metric | routed result | evidence |
|---|---:|---|
| WNS | **-30.841 ns** | `timing_summary.rpt` |
| TNS | **-1,868,119.375 ns** | `timing_summary.rpt` |
| setup failing endpoints | **81,997 / 83,906** | `timing_summary.rpt` |
| WHS | **+0.102 ns** | `timing_min.rpt` |
| THS | **0.000 ns** | `timing_min.rpt` |
| hold failing endpoints | **0 / 83,906** | `timing_min.rpt` |
| LUT | **18,524 (34.82%)** | `utilization.rpt` |
| FF | **8,674 (8.15%)** | `utilization.rpt` |
| DSP | **2 (0.91%)** | `utilization.rpt` |
| BRAM36 | **32 (22.86%)** | `utilization.rpt` |
| total on-chip power | **0.314 W** | `power.rpt` |
| route errors | **0** | OOC run log |

The worst setup path is `pixels_reg_reg[10]/C` -> `param_mem_reg_2816_2943_52_52/DP.HIGH/WE`, with 38.124 ns data delay: 22.186 ns logic (58.194%) and 15.938 ns routing (41.806%), 47 logic levels (`CARRY4=30`, `DSP48E1=1`, `LUT2=5`, `LUT3=10`, `LUT6=1`). The path includes `param_physical_row_return[11]` (fanout 68) and the final parameter write-enable net (fanout 128). The source clock net has fanout 16,931.

This is not a single-register timing miss. The RTL creates a long address/write cone: `param_physical_row()` divides by runtime `cin_reg` and reconstructs the row with multiply/subtract (`rtl/cnn/ds_persistent_feed_contract.v:209-217`); the resulting variable index is used for the two half-word writes (`:422-426`). Synthesis maps the nominal 4K x 64 `param_mem` to **2,048 RAM128X1D distributed-RAM primitives** rather than BRAM. The local transposed window also uses variable array indices and variable part-select writes (`:488-501`), and Vivado explicitly warns that it cannot infer RAM for `window_mem` because of multiple/invalid writes (`ds_persistent_feed_contract_ooc_20260831.log`, synthesis warning at RTL line 501). Thus a register inserted on the endpoint would only split one symptom; it would not remove the variable decode, LUTRAM write enables, fanout, or the address-generation work, and it would require a new ready/response phase if inserted into the loader.

The persistent ABI itself is implementable with existing fixed-address BRAM building blocks, but this wrapper is not a drop-in timing-qualified implementation yet. `pw_weight_buffer_bram.v:44-49` already uses a tile/channel linear address and `:68-110` an XPM block RAM with byte enables; `ds_spatial_word_window_bank.v:10-20,121-148` accepts a caller-linearized address and uses four explicit block-RAM planes; `row_image_bram_store.v:57-95,112-118` shows explicit RAMB36 instances and static bank concatenation. A production adapter should register `cout_tile`, `k`, and half-word phase, increment a fixed physical row (`tile_base + k`) rather than divide by `cin_reg`, and present one BRAM write port per bank. The loader/commit/epoch contract can remain unchanged; only the physical bank adapter and its address schedule need replacement.

## Storage and port contract

The default source bank is 32,768 x 32 bits (1,048,576 bits, ceiling 29 RAMB36); the packed parameter bank is 4,096 x 64 bits (262,144 bits, 8 RAMB36). The combined worst-case projection is therefore 37 RAMB36, 26.4% of the 140-RAMB36 full-top budget and below the 98-RAMB36 promotion ceiling. In a production integration these banks replace the corresponding repeated source/parameter staging, rather than being added alongside it; the prototype itself does not alter cnn_top.

The external source and parameter ports are single outstanding request/response channels with explicit ready and one-cycle response capture. Loading is completed before commit, and committed banks are read-only during token service, so no source or parameter read/write collision exists. The local eight-pixel window is written during gather and read only after the gather fence. A future dual-port implementation can preserve this phase contract.

## Scope and promotion boundary

`mode=0` has a complete PW K-token contract. `mode=1` exposes and checks the real DW source/parameter word accounting but deliberately does not claim a 3x3 DW token schedule. The PASS therefore proves persistent packed PW parameter storage, source-window reuse, nonzero address fidelity, tails/masks, epochs/sessions, and backpressure—not DS integration, fullnet logits, or XC7Z020 post-route closure.

## Reproduction and artifacts

The traffic ledger is regenerated with `python scripts/model_ds_persistent_feed_contract.py`; it writes `build/reports/ds_persistent_feed_contract_ledger.csv` and `build/reports/ds_persistent_feed_contract_ledger.md`. The RTL contract regression is `wsl.exe bash -lc "cd /mnt/d/Stuff/Project && scripts/run_ds_persistent_feed_contract_sim.sh"` and covers DS1/DS3/DS6, 432 accepted tokens, request bubbles, token backpressure, masks, epochs/sessions, and window reuse. The routed OOC evidence is regenerated with `& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal -notrace -source scripts/vivado_ds_persistent_feed_contract_ooc_20260831.tcl`.

The task-owned source files are `rtl/cnn/ds_persistent_feed_contract.v`, `sim/tb_ds_persistent_feed_contract.v`, `sim/filelist_ds_persistent_feed_contract.f`, `scripts/run_ds_persistent_feed_contract_sim.sh`, `scripts/model_ds_persistent_feed_contract.py`, and `scripts/vivado_ds_persistent_feed_contract_ooc_20260831.tcl`. The report is this file; generated OOC outputs are under `build/reports/vivado_ds_persistent_feed_contract_ooc_20260831/` (`timing_summary.rpt`, `timing_max.rpt`, `timing_min.rpt`, `timing_min_paths.rpt`, `utilization.rpt`, `power.rpt`, and the routed DCP).
