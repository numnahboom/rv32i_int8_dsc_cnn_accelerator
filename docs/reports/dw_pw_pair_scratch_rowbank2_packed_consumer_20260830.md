# Packed-weight paired scratch consumer integration (2026-08-30)

This is a non-production proof vehicle.  It does not modify the layer runner,
the full-network testbench, or the DW producer.

## Datapath contract

`dw_pw_pair_scratch_rowbank2_packed_consumer` combines the existing paired-half
DW scratch-bank ownership/fence protocol with `pw_packed_rowstore_feeder`.
The PW loader accepts the tile-major/K-minor 32-bit stream and commits a
64-bit row store.  A job captures `job_cout_tile`; each group command and
activation token is then forwarded to the feeder.  The feeder forms weight
addresses from registered tile/group/K cursors only.  `job_cout_base` is passed
through to the row-bank output tag and is not used in the weight address path.

The consumer keeps the full-K group protocol: scratch groups can be read in
forward or reverse order, only the final group carries `last_k`, and the
scratch bank is released only after the registered PW output sink has drained.

## Functional evidence

Command:

```text
scripts/run_dw_pw_pair_scratch_rowbank2_packed_consumer_sim.sh
```

The Verilator differential integration passed after the final RTL changes:

```text
PASS packed pair consumer jobs=3 outputs=32 cycles=2133 packed_words=512 packed_reads=192
```

The jobs cover Cin=16/48/128, P=17 including the one-pixel tail, Cout=13
including the channel tail, both Cout tiles, forward/reverse group order,
half-order variation, bank reuse with new sessions/epochs, and deterministic
output backpressure with stalled-output stability checking.  The expected
values are independently accumulated and requantized in the testbench.

## XC7Z020 OOC physical screen

Command/script: `scripts/vivado_dw_pw_pair_scratch_rowbank2_packed_consumer_ooc_20260830.tcl`

Target is `xc7z020clg400-1`, Vivado 2025.2, 8 ns clock, generic
`MAX_CIN=128 MAX_COUT=256 MAX_GROUPS=16`, `flatten_hierarchy none`, and
`general.maxThreads=2`.  The final run used post-route
`phys_opt_design -directive AggressiveFanoutOpt` and completed with zero
routing errors.

| Metric | Post-route result |
|---|---:|
| WNS | +0.327 ns |
| TNS / setup failing endpoints | 0.000 ns / 0 |
| WHS / hold failing endpoints | +0.098 ns / 0 |
| LUT | 4,690 (8.82%) |
| FF | 14,549 (13.67%) |
| BRAM36 | 24 (17.14%) |
| DSP | 72 (32.73%) |
| Total on-chip power | 0.321 W |
| Routing errors | 0 |

The strict local candidate gate requested for this slice was WNS >= +0.5 ns;
the integrated design therefore does **not** pass that gate and must not be
promoted to the runner or full-top implementation.  It does pass the basic
8 ns setup/hold feasibility screen (WNS/WHS >= 0).  The limiting path after
the final route is scratch-bank control:

```text
u_scratch/group_cursor_reg[0][2]/C
  -> u_scratch/top_lane_mask_reg[1][9][11]/CE
data delay 7.384 ns = 1.674 ns logic + 5.710 ns routing
```

The packed row-store/PW side also has a 0.386 ns-slack class from the row-bank
activation register to the DSP inputs, but it is not the worst path.  The
dominant failure against the +0.5 margin is therefore scratch-bank control
placement/routing, not a `cout_base`-dependent weight mux.

## Scope conclusion

The packed feeder integration is functionally closed as an isolated variant
and uses the expected 72-DSP/24-BRAM organization, but its OOC margin is only
+0.327 ns.  It is evidence for the packed-weight interface and not evidence
of full-network cycle, power, or post-route closure.
