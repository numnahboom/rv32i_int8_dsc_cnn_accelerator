# Group-ready partial-K real producer integration — 2026-08-30

## Scope

This is a validation shell only. `ds_group_ready_real_producer` connects the
existing `ds_word_window_dw_tagless_stream4_4x8` producer in `STREAM4_ONLY`
mode to the existing requant adapter output, then feeds the stream4 beats to
`ds_group_ready_partial_k_pipeline`. The legacy producer scratch write sink is
disabled in this mode; no production `cnn_top` or runner ABI is changed.

## Files

- `rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v`: optional stream4
  output exposure and `STREAM4_ONLY` sink bypass; default remains unchanged.
- `rtl/cnn/ds_word_window_dw_tagless_stream4_4x8.v`: forwards the optional
  stream4 interface and permits a one-row geometry for the integration proof.
- `rtl/cnn/ds_group_ready_real_producer.v`: real producer → requant adapter →
  assembler/scratch/partial-K PW wrapper.
- `sim/tb_ds_group_ready_real_producer.v` and
  `sim/filelist_ds_group_ready_real_producer.f`: nonzero source/weight
  integration regression.
- `scripts/run_ds_group_ready_real_producer_sim.sh`: reproducible Verilator
  command.

## Producer-to-PW evidence

Command (WSL, Verilator 5.020):

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_group_ready_real_producer_sim.sh"
```

The test uses Cin=16, P=8, Cout=8, a 4x10 source footprint, every source byte
`1`, every DW tap weight `1`, and every PW weight `1`. Thus each valid DW pixel
is 9 and each valid PW output lane is independently expected to be
`16 * 9 = 144`. The test exercises the complete

```text
source fill -> word-window producer -> DW MAC -> stream4 requant ->
half assembler -> scratch pair -> group descriptor -> PW partial-K tokens
```

Raw final output:

```text
PASS real_producer cin=16 pixels=8 cout=8 cycles=630 first_output=627 halves=4 descriptors=2 tokens=16 outputs=1
```

The test also checks 32 nonzero stream4 beats (`mask=4'hf`), all 64 output lane
masks, all 64 signed psums against 144, one output group, four half writes,
two descriptors, and sixteen PW tokens.

## Group-ready/fence cycle comparison

Fresh command:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_group_ready_partial_k_pipeline_sim.sh"
```

The same-shape Cin=48, P=17, Cout=16 case reports:

| Mode | Cycles | First output | Half writes | Descriptors | PW tokens |
|---|---:|---:|---:|---:|---:|
| group-ready | 648 | 434 | 36 | 18 | 144 |
| complete-tile fence | 766 | 553 | 36 | 18 | 144 |

The group-ready saving is `766 - 648 = 118` cycles, or `15.40%`. It comes from
publishing each row/group descriptor after its two halves arrive, allowing the
PW consumer and DW stream to proceed before the complete-tile write fence. The
partial-K token count and final output count remain unchanged.

The regression also passed Cin=16/P=1/Cout=8 (52 cycles), Cin=16/P=8/Cout=13
(108), and Cin=13/P=17/Cout=13 tail (202). The testbench contains handshake
assertions for descriptor exactly-once, descriptor-after-pair, token index and
`last_k`, no intermediate PW output, and commit-after-all-half-writes.

## XC7Z020 OOC post-route screen

Script:

`scripts/vivado_ds_group_ready_partial_k_ooc_20260830.tcl`

Artifacts:

`build/reports/vivado_ds_group_ready_partial_k_ooc_20260830/`

Fresh Vivado 2025.2 `xc7z020clg400-1`, 8 ns clock, routed result:

| Metric | Result |
|---|---:|
| WNS / TNS / setup fails | +0.132 ns / 0 / 0 |
| WHS / THS / hold fails | +0.096 ns / 0 / 0 |
| LUT | 3,971 / 53,200 (7.46%) |
| FF | 6,710 / 106,400 (6.31%) |
| BRAM36 | 23 / 140 (16.43%; 25 block-RAM tiles) |
| DSP48E1 | 32 / 220 (14.55%) |
| Total on-chip power | 0.198 W |
| Fully routed nets | 10,380; route errors 0 |

The worst max path is `half_pipe_row_reg[1]_replica_1/C` to
`half_pipe_group_reg[1]_replica_4/CE`: 7.579 ns data delay, six logic levels,
1.468 ns logic (19.37%) and 6.111 ns routing (80.63%). The path includes a
`fo=250` half-row alias net and a `fo=303` `half_pipe_push` net. Therefore the
prototype clears 8 ns but has only +0.132 ns margin; this is not full-top
timing closure.

## Boundary

This evidence proves real producer/adapter wiring and nonzero arithmetic for
one shape. It does not establish fullnet logits, full-top post-route timing,
full-network cycles, or 20 GOPS/W. The next integration gate is replacing the
validation shell's single producer job with the real DS tile scheduler and
measuring the resulting full-network cycle and route behavior.

## Integrated real-producer OOC

The integrated shell was also screened with
`scripts/vivado_ds_group_ready_real_producer_ooc_20260830.tcl`; artifacts are
in `build/reports/vivado_ds_group_ready_real_producer_ooc_20260830/`.
This routed design includes the word-window producer, DW core, local stream4
requant adapter, assembler, scratch banks, reorder cache and PW array.

| Metric | Integrated OOC result |
|---|---:|
| WNS / TNS / setup fails | +0.036 ns / 0 / 0 |
| WHS / THS / hold fails | +0.039 ns / 0 / 0 |
| LUT | 9,796 / 53,200 (18.41%) |
| FF | 18,927 / 106,400 (17.79%) |
| BRAM36 | 65 / 140 (46.43%; 69 block-RAM tiles) |
| DSP48E1 | 65 / 220 (29.55%) |
| Total on-chip power | 0.276 W |
| Fully routed nets | 30,992; route errors 0 |

The integrated worst setup path is
`u_group_ready/u_scratch0/group_data_row_reg[0]/C` to
`u_group_ready/cache_pmask_reg/DIADI[7]`, with 7.435 ns data delay: 2.997 ns
logic (40.31%) and 4.438 ns routing (59.69%), nine logic levels. Notable local
fanouts are 67 on the scratch-to-cache net, 32 on `group_cache_addr[0]`, and
37 on the carry net; the clock net fanout is 19,751. The shell therefore just
clears 8 ns and has effectively no physical margin, so it is a wiring proof,
not an acceptance-quality timing result.
