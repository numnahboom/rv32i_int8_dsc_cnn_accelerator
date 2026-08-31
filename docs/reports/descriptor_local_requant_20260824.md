# Descriptor-local PW requant boundary experiment (2026-08-24)

## Candidate

`rtl/cnn/ds_block_tile_engine_new.v` now captures the PW accumulator slice,
bias, multiplier, shift, and pixel/channel tag in a one-entry descriptor-local
register before `requant_activation_unit`.  The external ready/valid contract
and single-outstanding scan behavior are unchanged.  The existing three-entry
output tag pipeline remains aligned to the requant unit's three-cycle latency.

This isolates the LUTRAM/address-selection cone from `product_s1` at the cost
of one internal descriptor cycle per PW tile.  The PW issue count is unchanged.

## Functional and cycle evidence

- Verilator 5.020 direct DS-block test: `tb_ds_block_tile_engine_new`, 7 cases,
  2191 checks, PASS.
- Vivado XSim 2021.2 full selected regression: 10/16 tests PASS.  The six
  failures (`tb_cnn_top_ops_datapath`, multilayer, SRAM gap/FC, tail, E2E,
  fullnet) reproduce the pre-existing XSim `actual=x` signatures; direct
  DS-block, backpressure, tiled, and stem tests pass.
- PW issue counts remained 64, 64, 256, 2, 14, 68, and 4064 for cases 0..6.
  Compared with the current baseline logs, total-cycle deltas were +8, +4,
  0, 0, 0, +1, and 0 respectively (only descriptor/drain overhead; no issue
  cadence change).

## Routed OOC Explore evidence

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_cnn_top_impl.tcl -tclargs cnn_top xc7z020clg400-1
```

Candidate evidence: `build/reports/vivado_cnn_top_impl_desc_local_20260824/`.
The fully routed result has WNS `-6.997 ns`, TNS `-26365.537 ns`, WHS
`+0.061 ns`, with zero unrouted nets.  The controlled Explore baseline was
WNS `-7.376 ns`, TNS `-27930.100 ns`, WHS `+0.028 ns`.  Therefore the
candidate improves both setup metrics (`+0.379 ns` WNS and `+1564.563 ns`
TNS) while retaining positive hold slack and complete routing.  It does not
close setup timing, so this is routed OOC evidence, not timing closure or
board validation.

## Decision

Keep the candidate: it meets the dual WNS/TNS improvement gate and preserves
functional direct-path results with a bounded one-cycle-per-PW-tile cost.
