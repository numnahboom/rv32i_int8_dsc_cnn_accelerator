# DS tiled double-bank validation (2026-08-27)

## Scope

This report validates the existing DS tiled overlap candidate without changing
the DS/runner RTL.  The focused bank test drives `ds_block_tile_engine_new`
directly.  It computes bank A while filling bank B, then computes the same
payload from bank B and checks a wrong-tag start is rejected.

## Focused bank protocol test

Testbench: `sim/tb_ds_block_tile_engine_banked.v`

The two cases use a 2x2 output tile with stride 1 and stride 2.  They therefore
exercise 4x4 and 5x5 input tiles, respectively.  Bank A is loaded with scalar
writes.  Bank B is loaded concurrently using vector4 writes for channels 0--3
and scalar writes for channels 4--15.  The test also holds an active-bank write
while compute is busy and requires `cfg_ready=0`.

Commands:

```text
GENERATE_TEST_VECTORS=0 ./scripts/run_sim.sh tb_ds_block_tile_engine_banked
.\scripts\run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_ds_block_tile_engine_banked
```

Both Verilator and XSim report:

```text
PASS tb_ds_block_tile_engine_banked stride=1,2 overlap scalar/vec4 tag/backpressure
```

The test checks bank-A/bank-B result equivalence, nonzero compute/load
overlap, scalar and vector4 accepted writes, zero same-bank writes, zero engine
bank conflicts, active-bank backpressure, and rejection of a bank-B start with
tag `0x23` after committing tag `0x22`.

## Full-network exact run

The current vector file is used unchanged (`GENERATE_TEST_VECTORS=0`).  Fresh
Verilator and XSim both pass the exact 10-logit fullnet check:

```text
hw_cycles=899451 checks=10 errors=0 status=0db97b82
mem_reads=78890 mem_writes=10
```

Verilator log:
`build/reports/verilator_runner_ds_overlap_stats_20260827/tb_cnn_top_fullnet_sram_datapath.log`

XSim command:

```text
.\scripts\run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_top_fullnet_sram_datapath
```

The XSim wrapper now completes its Python report step.  The generated
`build/reports/inference_accuracy_perf.md` records 53,088 scalar SRAM read
transactions, 15,680 32-bit word transactions, and 115,808 logical byte reads.
The accounting identity is `logical = scalar + 4*word`; no transaction is
silently multiplied in the raw counter.

## Overlap trace

With `+TRACE_DS_OVERLAP`, the current fullnet trace contains these unique
nonzero summaries (one per DS block):

```text
DS_OVERLAP_SUM cycles=42540 writes=1888 conflicts=0
DS_OVERLAP_SUM cycles=63288 writes=2976 conflicts=0
DS_OVERLAP_SUM cycles=123258 writes=6624 conflicts=0
```

`cycles` counts runner clocks with `ds_busy && ds_pf_busy`.  `writes` counts
accepted scalar prefetcher configuration writes only; vector4 configuration
writes are separately visible in the focused test and are not included in this
field.  `conflicts` counts accepted scalar writes whose bank equals the active
bank.  Repeated final summaries are a pre-existing `ST_DONE` observation and
are not additional DS blocks.

## OOC boundary

The available routed report is produced by
`scripts/vivado_ds_block_tile_engine_new_8x4_ooc_20260827.tcl`, whose top is
`ds_block_tile_engine_new` in out-of-context mode for
`xc7z020clg400-1`.  It reports WNS `-3.320 ns`, TNS `-5284.915 ns`, WHS
`+0.096 ns`, and zero unrouted nets.  This is DS-module routed evidence only;
it is not full-top timing closure, board validation, or a 125 MHz claim.

Remaining attribution risk: 899451 cycles is the current aggregate dirty
checkout result.  A feature-off A/B run in the same checkout is still needed
to attribute the full 58,723-cycle reduction from the older 958174-cycle log
to the double-bank overlap alone.
