# Packed paired-scratch consumer locality repair (2026-08-30)

## Scope

This is a non-production physical-screen variant.  Only
`dw_pw_pair_scratch_bank.v` was changed; the production runner, DW producer,
and PW row-store ABI were left untouched.

## Mask contract and implementation

The original scratch bank inferred a `[bank][group]` register array for the
32-bit top/bottom half lane masks.  For the fixed 4x8 spatial tile, the pixel
validity portion is invariant across Cin groups.  The only group-dependent
case in the covered ABI is the final Cin-group channel tail (for example
Cin=128, group 15, channels 5..7 invalid).  The repair therefore stores four
compact descriptors per bank: top/bottom first-group masks and top/bottom
final-group masks.  A read selects the first descriptor for non-final groups
and the final descriptor for the final group.  This preserves P17 spatial
tails, final channel tails, reverse group order, arbitrary half order, stale
tag rejection, bank reuse, and output backpressure behavior without a dynamic
`[bank][group]` mask write-enable decode.

The accepted scratch read is also registered for one cycle before driving the
BRAM read enable/address.  This keeps the packed consumer's live reverse/group
selector off the BRAM ENARDEN path and does not change the one-vector-at-a-time
external protocol other than the expected extra read latency.

## Functional validation

Commands:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_dw_pw_pair_scratch_bank_sim.sh'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_dw_pw_pair_scratch_rowbank2_packed_consumer_sim.sh'
```

Results after the locality repair:

```text
PASS paired-half scratch bank checks=24 cycles=257
PASS packed pair consumer jobs=3 outputs=32 cycles=2155 packed_words=512 packed_reads=192
```

The differential packed test covers Cin=16/48/128, P17 spatial and Cout13
tails, forward/reverse group order, half-order variation, bank/session/epoch
reuse, and deterministic output backpressure/stability.  The standalone test
also covers the final-group channel-tail mask explicitly.

## XC7Z020 OOC post-route

Command/script: `scripts/vivado_dw_pw_pair_scratch_rowbank2_packed_consumer_ooc_20260830.tcl`

Target is `xc7z020clg400-1`, Vivado 2025.2, 8 ns, generic
`MAX_CIN=128 MAX_COUT=256 MAX_GROUPS=16`, `flatten_hierarchy none`,
`general.maxThreads=2`, and post-route `phys_opt_design -directive
AggressiveFanoutOpt`.

| Metric | Post-route result |
|---|---:|
| WNS | +0.548 ns |
| TNS / setup failing endpoints | 0.000 ns / 0 |
| WHS / hold failing endpoints | +0.098 ns / 0 |
| Slice LUTs | 4,333 (8.14%) |
| Slice registers | 12,758 (11.99%) |
| BRAM36 | 24 (17.14%) |
| DSP | 72 (32.73%) |
| Total on-chip power | 0.319 W |
| Routing errors | 0 |

The former `group_cursor -> top_lane_mask[bank][group]/CE` path is absent from
the routed max-path report.  The new worst setup path is the packed consumer's
`read_count -> FSM state CE` control path at 7.163 ns data delay (74.6% route),
not a scratch-mask CE path.  The BRAM read-address/enable path is now driven by
registered `read_issue_*` state.  The OOC result clears the local WNS >= +0.5
ns / WHS >= 0 gate, but remains primitive/integration evidence only and is not
full-top timing or network evidence.
