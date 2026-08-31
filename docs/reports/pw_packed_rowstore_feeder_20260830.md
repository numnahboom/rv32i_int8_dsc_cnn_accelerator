# Packed 64-bit PW row-store feeder (isolated prototype)

This report records the non-production `pw_packed_rowstore_feeder` proof
vehicle.  It is deliberately not connected to `cnn_layer_runner`,
`ds_block_tile_engine`, or the full-network simulation.

## Datapath contract

- Physical weight row address is `{cout_tile[4:0], k[6:0]}` (4096 rows).
- Each row is 64 bits: lower 32 bits are output lanes 0..3 and upper 32 bits
  are lanes 4..7.
- The loader accepts one 32-bit word per handshake.  A registered
  tile/K/half cursor maps the tile-major, K-minor stream to the sparse
  physical row address; no division or dynamic address calculation is used
  by the compute path.
- `load_begin` captures epoch/Cin/Cout and invalidates the prior commit.
  `load_commit_ready` is asserted only after exactly
  `2*Cin*ceil(Cout/8)` words.  Missing and extra words are reported and are
  not committed/accepted.
- Compute captures the committed `cout_tile` and epoch in a job register,
  accepts explicit sequential group commands, and maps reverse group order
  through a registered group cursor.  The BRAM response is held in one
  elastic slot and is presented to the existing exact full-K, two-lane
  output-stationary row-bank core at II=1 when downstream is ready.
- `cout_base` is passed only as the output tag.  The weight address is formed
  exclusively from registered `cout_tile`, group, and K cursors.

## Functional evidence

`scripts/run_pw_packed_rowstore_feeder_sim.sh` and
`sim/tb_pw_packed_rowstore_feeder.v` exercise:

- Cin 16/48/128 and Cout 13/256;
- P=17 pixel tails and Cout tails, including both lower and upper packed
  32-bit halves;
- forward and reverse group order;
- deterministic output backpressure and activation stalls;
- missing-word commit rejection, extra-word rejection, and stale-epoch job
  rejection;
- packed-load and packed-read counters, with one read enable per accepted
  activation (no duplicate/replay reads).

The completed Verilator differential run reported:

```
PASS tb_pw_packed_rowstore_feeder outputs=32 cycles=8730 loads=512 reads=416
```

The `loads=512`/`reads=416` totals are the final 128-Cin/Cout-13 load and
the cumulative accepted activation reads across the exercised jobs.  The
regression compares row/beat/pixel/channel tags and masked int8 results;
the lane-dependent packed pattern makes both 32-bit halves observable.

## XC7Z020 OOC physical screen

Command: `scripts/vivado_pw_packed_rowstore_feeder_ooc_20260830.tcl`.

Target is `xc7z020clg400-1`, Vivado 2025.2, 8.000 ns clock, generic
`MAX_CIN=128 MAX_COUT=256`, `flatten_hierarchy none`, and
`general.maxThreads=2`.  The final run includes post-route
`phys_opt_design -directive AggressiveExplore`.

| Metric | Post-route result |
|---|---:|
| WNS | +0.591 ns |
| TNS / setup failing endpoints | 0.000 ns / 0 |
| WHS | +0.098 ns |
| THS / hold failing endpoints | 0.000 ns / 0 |
| LUT | 3,375 (6.34%) |
| FF | 10,785 (10.14%) |
| DSP | 72 (32.73%; PW row-bank) |
| BRAM36 | 8 (5.71%) |
| Total on-chip power | 0.304 W |
| Routing errors | 0 |

The routed checkpoint and raw reports are under
`build/reports/vivado_pw_packed_rowstore_feeder_ooc_20260830/`.
The structural cone audits `coutbase_to_weight_memory.txt` and
`coutbase_to_dsp.txt` both report no timing paths.  The high-fanout report
identifies the inherited row-bank ownership/requant control as the dominant
fanout; the feeder adds no cout-base-to-BRAM/DSP path.

## Scope and limitations

This is an isolated feeder/core prototype, not full-top timing closure,
runner integration, or end-to-end cycle/energy evidence.  Its 0.304 W OOC
power and 73 DSP count must not be substituted for the full-network metrics.
