# DW vector4 requantization candidate rejected

Date: 2026-08-26. The candidate split the 16 DW lanes across four parallel
four-lane `requant_activation_vector4` instances while retaining the existing
scalar output handshake and single SRAM write port.

## Functional screen

With the candidate enabled, Verilator 5.020 passed:

* `tb_requant_activation_vector4`: 64 writes;
* `tb_dw_tile_fusion_engine_new`: 3 cases;
* `tb_ds_block_tile_engine_new`: 7 cases / 2,191 checks;
* `tb_cnn_top_fullnet_sram_datapath`: 10/10 exact checks, zero errors.

The candidate required an absolute-pixel upper bound (`pixel_base + 1`) and an
explicitly enabled vector4 early-stop mode for DW. The latter was kept local
to DW so the existing PW fixed issue cadence remained unchanged.

## Cycle screen

The candidate and saved scalar-DW baseline produced the same DS totals:

| case | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| total cycles | 2776 | 988 | 1344 | 509 | 441 | 1034 | 5772 |
| DW cycles | 2240 | 700 | 296 | 460 | 364 | 919 | 1561 |

The full-network result was also unchanged at `949792` hardware cycles,
`78890` reads, and `10` writes. Thus the extra parallel requantization does
not improve the measured externally visible schedule.

## Decision

Rejected before synthesis/P&R. The candidate adds four arithmetic lanes without
a measured cycle benefit; its timing and resource cost are therefore not worth
spending a full implementation run. The DW engine is restored to its scalar
requantization implementation. The vector4 primitive remains in the tree for
the existing PW path.
