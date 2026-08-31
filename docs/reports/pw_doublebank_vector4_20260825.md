# PW double-bank + vector4 phase-1 experiment

Date: 2026-08-25.  Target fabric: `xc7z020clg400-1`, Vivado 2025.2.

## RTL hypothesis

`pw_systolic_array_8x8` now has two accumulator banks.  The bank selected by
the current K reduction receives the final product on `k_last`; the bank
select changes on that same accepted edge, so the next block starts on the
other bank while the completed 64-psum vector remains stable.  The external
single-vector valid/ready interface is unchanged.

`requant_activation_vector4` wraps four unchanged exact ten-stage
`requant_activation_unit` instances.  Each lane has a tagged 32-entry output
FIFO, allowing the arithmetic to consume four psums per cycle while the
legacy scalar output write port drains one result per cycle.  `ds_block_tile_engine_new`
accepts a completed vector and advances the next PW block without waiting for
the previous vector's output FIFO to drain.  No runner, SRAM, output-memory,
precision, or network-compute changes were made.

## Functional/performance evidence

Commands were run with Verilator 5.020 from WSL:

* `tb_requant_activation_vector4`: PASS, 64/64 tagged writes under varying
  lane backpressure.
* `tb_pw_systolic_array_8x8_backpressure`: PASS; output held stable for five
  stalled cycles and the second banked block produced all 64 expected psums.
* `tb_pw_systolic_array_8x8`: PASS, 6 cases / 384 checks.
* `tb_requant_activation_unit`: PASS, 100 cases.
* `tb_ds_block_tile_engine_new`: PASS, 7 cases / 2,191 checks.  The largest
  directed case reports `total=5772`, `pw=4211`, `pw_issue=4064` cycles.
* `tb_cnn_top_fullnet_sram_datapath`: PASS, 10/10 exact logits, unchanged
  memory transaction totals, `hw_cycles=949792`, `status=0e7e2082`.

## Vivado screens

The isolated vector4 OOC route is in
`build/reports/vivado_requant_vector4_ooc_20260825/`:

* post-route WNS `+0.076 ns`, WHS `+0.098 ns`, TNS/THS `0`, 0 routing errors;
  worst setup datapath `7.902 ns` (about 126.5 MHz at the isolated 8 ns
  constraint);
* LUT 3,376/53,200 (6.35%), FF 11,421/106,400 (10.73%), BRAM 0/140,
  DSP 16/220 (7.27%);
* vectorless estimated total on-chip power `0.189 W`.

The DS-only post-synthesis screen is in
`build/reports/vivado_ds_block_tile_engine_new_v4_20260825/`:

* LUT 32,815/53,200 (61.68%), FF 26,110/106,400 (24.54%), BRAM 26/140
  (18.57%), DSP 20/220 (9.09%).

Vivado `opt_design` reported opaque `Synth 20-411` for the standalone vector
wrapper, so the OOC route screen intentionally routes the legal synthesized
netlist directly (no timing claim is made for the skipped optimization pass).
No full top implementation was started for this phase.

