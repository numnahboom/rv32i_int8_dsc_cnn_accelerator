# Shared unified64 plus persistent DS fullnet/OOC evidence (2026-08-31)

This is the current validation record for `USE_SHARED_UNIFIED64=1` and
`USE_PERSISTENT_DS=1`.  The fullnet run is functional/cycle evidence; the
8 ns result is a routed OOC screen.  No fresh full-top post-route run is
claimed because the production DS OOC screen remains negative.

## Reproduction

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_cnn_fullnet_shared_persistent_ds_verilator.sh"
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_ds_block_tile_engine_persistent_ooc_20260831.tcl
```

## Full-network Verilator result

```text
PERF tb_cnn_top_fullnet_sram_datapath case=0 hw_cycles=695553 checks=10 errors=0 status=0a9d0182 mem_reads=77630 mem_writes=10
SHARED_METRIC stem_tok=6912 stem_mac=442368 stem_commit=256 ds_tok=65536 ds_mac=4194304 ds_commit=1344 total_tok=72448 total_commit=1600
PASS tb_cnn_top_fullnet_sram_datapath cases=1 checks=10
SHA256 hw=9AE481448D028A5774406C6B73FF3CCCDB820DA8F4A2EB0ACDBF79AA76251260 expected=9AE481448D028A5774406C6B73FF3CCCDB820DA8F4A2EB0ACDBF79AA76251260
```

The measured total is 5,136,896 MACs: Stem 442,368 and DS PW
4,194,304.  External traffic is 77,630 reads and 10 writes.  Compared with
the shared-unified64 nonpersistent result of 713,086 cycles, persistent
window feeding saves 17,533 cycles (2.46%) while preserving exact logits.

The machine-readable DS ledger is
`build/reports/fullnet_persistent_ds_metrics.csv`:

| layer | preload words | compute cycles | commit blocks | source-window reads | SRAM writes | window reuse | tokens |
|---|---:|---:|---:|---:|---:|---:|---:|
| DS1 | 800 | 111,324 | 512 | 2,048 | 8,192 | 384 | 8,192 |
| DS2 | 2,624 | 107,068 | 256 | 1,024 | 4,096 | 224 | 8,192 |
| DS3 | 5,056 | 120,372 | 256 | 2,048 | 4,096 | 224 | 16,384 |
| DS4 | 9,344 | 78,427 | 128 | 512 | 2,048 | 120 | 8,192 |
| DS5 | 18,304 | 98,107 | 128 | 1,024 | 2,048 | 120 | 16,384 |
| DS6 | 35,072 | 106,133 | 64 | 256 | 1,024 | 62 | 8,192 |

`preload words` is the measured external memory-read traffic for the DS
layer; `compute cycles` is the complete DS engine envelope; `commit blocks`
is the shared-array final result fence count; `source-window reads` and
`window reuse` are per-layer persistent feeder counters; `SRAM writes` is
the output-bank write count.

## Production-path bank confirmation

The persistent path is actually selected in the production hierarchy, not
only in an independent contract wrapper:

- `cnn_top.USE_PERSISTENT_DS` propagates to
  `cnn_layer_runner.USE_PERSISTENT_DS`, then to
  `ds_block_tile_engine_new.USE_PERSISTENT_FEED`.
- In persistent mode, `dw_buf_rd_en` and the persistent source address feed
  the existing `dw_tile_buffer_bram` (`u_dw_tile_buffer`).  Its synchronous
  64-bit row output drives `source_rd_data` of `u_persistent_pw_feed`.
- In persistent mode, `pw_weight_rd_en` and the persistent Cout/channel
  address feed the existing `pw_weight_buffer_bram` (`u_pw_weight_buffer`).
  Its synchronous 64-bit row output drives `weight_rd_data` of
  `u_persistent_pw_feed`.
- `u_persistent_pw_feed` supplies the token and first/last-K metadata to the
  single shared unified64 array.  The independent
  `ds_persistent_feed_contract_bram` is not instantiated by this production
  path.

## XC7Z020 routed OOC screen

Vivado 2025.2, `xc7z020clg400-1`, 8.000 ns, `general.maxThreads=2`, routed
successfully with zero route errors:

| metric | result | gate |
|---|---:|---:|
| WNS / TNS | **-0.838 ns / -354.351 ns** | WNS >= +0.5 ns / TNS = 0 |
| setup failing endpoints | **1,409 / 53,914** | 0 |
| WHS / THS | +0.098 ns / 0 ns | >= +0.1 ns / 0 |
| LUT | 17,010 (31.97%) | <70% |
| FF | 23,048 (21.66%) | <70% |
| BRAM36 | 28 (20.00%) | <70% |
| DSP48E1 | 16 (7.27%) | <70% |
| total on-chip power | 0.233 W | <3 W |
| route errors | 0 | 0 |

The worst setup path is the existing DW parameter-load cone,
`dw_param_lane_reg[3]_rep/C -> dw_weight_vec_reg[953]/D`, with 8.829 ns
data delay: 2.979 ns logic and 5.850 ns routing.  The persistent feeder is
visible in the routed netlist, but its `token_cout_base` fanout reaches about
2,324 loads and its `token_act_reg[63]` fanout about 513 loads.  Thus the
OOC failure is not evidence that the persistent source-window idea closes
timing; the dominant blocker remains the shared DW parameter/control cone.

## Promotion decision

The candidate passes exact fullnet logits, MAC accounting, and the cycle
ledger, and all resource/power limits are met in OOC.  It fails the required
OOC timing screen, so it is not promoted to a fresh full-top implementation.
The next change must reduce the DW parameter-load/control fanout or replace
that cone with a physically banked/preloaded structure before another global
PR run.
