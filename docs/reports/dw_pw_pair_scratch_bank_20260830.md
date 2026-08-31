# Paired-half DW/PW scratch bank (2026-08-30)

## Scope

`rtl/cnn/dw_pw_pair_scratch_bank.v` is an isolated, non-production precursor
for two 4x8 halves of an 8x8 DW tile.  It is intentionally not connected to
the layer runner, DS engine, PW core, or full-network simulation.

Each of two logical banks stores one 256-bit top half and one 256-bit bottom
half for each configured Cin group (up to 16 groups).  The write protocol
accepts either half order within a group, but advances only after both halves
retire and enforces ascending group order.  A group cursor and two one-bit
half-retired flags provide completion accounting; there is no wide
write-seen bitmap.  Lane masks are retained as tail metadata.  Ownership is
`FREE -> DW -> COMMITTED -> PW -> FREE`; session and epoch are checked at DW
acquire, DW commit, and PW acquire, while data writes and reads carry no tags.
The PW read path enables the selected pair of BRAMs together and registers a
512-bit 8x8 result plus its 64-bit lane mask.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_dw_pw_pair_scratch_bank_sim.sh'
```

Result: `PASS paired-half scratch bank checks=24 cycles=249`.

The Verilator test covers Cin=16/48/128 (2/6/16 groups), both top/bottom
orders, 7/8/5 active pixels, a final-group channel tail, write bubbles,
reverse group reads, stale DW/PW session tags, read-before-commit rejection,
reacquire/overwrite rejection, output backpressure/stability, and bank 0
reuse after release.  Every returned 8x8 vector and lane mask is compared to
an independent byte-level reference.

## XC7Z020 OOC post-route

Command:

```text
vivado.bat -mode batch -source scripts/vivado_dw_pw_pair_scratch_bank_ooc_20260830.tcl
```

Target is `xc7z020clg400-1`, Vivado 2025.2, one 8.000 ns clock, OOC
`RuntimeOptimized`, `general.maxThreads=2`.

| Metric | Post-route result |
|---|---:|
| WNS | +0.582 ns |
| TNS / setup failures | 0.000 ns / 0 |
| WHS | +0.166 ns |
| THS / hold failures | 0.000 ns / 0 |
| Slice LUTs | 1,015 (1.91%) |
| Slice registers | 2,699 (2.54%) |
| BRAM tiles | 16 (11.43%) |
| DSP | 0 (0%) |
| Total on-chip power | 0.112 W |
| Routing errors | 0 |

Reports are in
`build/reports/vivado_dw_pw_pair_scratch_bank_ooc_20260830/`.

This positive OOC result is a primitive-level gate only.  It does not prove
full-top timing, network cycles, end-to-end logits, or the 20 GOPS/W target.
