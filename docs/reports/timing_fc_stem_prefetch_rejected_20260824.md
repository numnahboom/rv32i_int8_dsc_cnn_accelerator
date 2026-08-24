# FC/stem requant operand prefetch experiments (2026-08-24)

## Scope

The descriptor-local PW requant result was the controlled Explore baseline:
WNS `-6.997 ns`, TNS `-26365.537 ns`, WHS `+0.061 ns`, zero unrouted nets.
Two short-lived candidates were tested against that baseline.  Both were
reverted because the required simultaneous WNS/TNS improvement gate failed.

## Candidate A: FC class-local operand prefetch

`rtl/cnn/fc_unit_new.v` temporarily added a prefetch state that registered
`acc_mem`, `bias_mem`, `multiplier_mem`, and `shift_mem` before product issue.
This removed the class-indexed LUTRAM reads from the product issue cycle while
preserving the arithmetic and external handshake.

Functional evidence:

- Verilator `tb_fc_unit`: 2 cases, 20 checks, PASS.
- Verilator gap-FC, tail, and fullnet: PASS for gap/tail; fullnet retained the
  known single mismatch at address `0004d410` (`expected=2`, `actual=0`) and
  reported `hw_cycles=995230`.
- XSim gap-FC, tail, and fullnet: gap/tail PASS; fullnet retained the known
  `actual=x` mismatch at the same address, with `hw_cycles=995230`.

Routed Explore run:
`build/reports/vivado_cnn_top_impl/runs/20260824T190005100-31484/`.

| result | WNS | TNS | WHS | THS | route |
|---|---:|---:|---:|---:|---|
| FC prefetch | -7.365 ns | -23844.395 ns | +0.085 ns | 0.000 ns | 0 unrouted |
| baseline | -6.997 ns | -26365.537 ns | +0.061 ns | 0.000 ns | 0 unrouted |

Although TNS improved, WNS regressed by `0.368 ns`; the first endpoint
family moved to Stem in this run.  Candidate A was reverted.

## Candidate B: Stem channel-local operand prefetch

`rtl/cnn/conv3x3_stem_engine_new.v` temporarily added a one-cycle prefetch
state for the channel-indexed bias, multiplier, and shift before the wide
requant product.  This preserved output ordering and added one cycle per stem
output channel.

Functional evidence:

- Verilator tiled Stem: 16,384 checks, PASS.
- XSim tiled Stem: 16,384 checks, PASS.
- Verilator/XSim fullnet retained only the known single mismatch at
  `0004d410`; candidate cycles were `1011604`.

Routed Explore run:
`build/reports/vivado_cnn_top_impl/runs/20260824T191740466-2756/`.

| result | WNS | TNS | WHS | THS | route |
|---|---:|---:|---:|---:|---|
| Stem prefetch | -6.961 ns | -30214.551 ns | +0.082 ns | 0.000 ns | 0 unrouted |
| baseline | -6.997 ns | -26365.537 ns | +0.061 ns | 0.000 ns | 0 unrouted |

WNS improved by `0.036 ns`, but TNS regressed by `3849.014 ns`; this fails
the dual timing gate.  Candidate B was reverted.

## Decision

Neither RTL experiment is retained.  The existing descriptor-local PW
requant RTL remains the current implementation.  Both routes were complete
and hold-clean; neither is timing closure, and no resource or power change is
claimed for the rejected candidates.
