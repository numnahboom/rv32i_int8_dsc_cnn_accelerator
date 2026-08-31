# Passive spatial quarter-plane window bank (2026-08-29)

## Scope

`ds_spatial_word_window_bank` is a storage-only producer/consumer island
primitive.  It stores a logical 16-lane int8 vector in four independently
write-enabled 32-bit planes.  The default configuration covers
`17 x 17 x 3 = 867` vector addresses (one address per spatial position and
channel group); the address and group linearization remain outside the bank.

The write payload `{vector_addr, quarter, data32, epoch}` is captured at the
island boundary before the RAM write.  Reads capture address, 16-lane validity
mask, tag, and epoch, then return a registered 128-bit vector.  Masked lanes
are zeroed at the response boundary while the original mask is returned.  A
read coincident with a retiring write to the same address and quarter is
explicitly write-first, independent of the inferred RAM collision mode.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_spatial_word_window_bank_sim.sh'
```

Verilator 5.020 completed successfully:

```text
PASS ds_spatial_word_window_bank writes=3724 reads=2456 cycles=19664
```

The test fills all 867 addresses in all four quarters, then checks 2,200
random masked gathers and 256 same-address write/read collisions.  It also
covers unaligned quarter order, response-ready stalls, read admission stalls,
tail/padding masks, tags, and epoch propagation.  No model mismatches were
reported.

## 8 ns routed OOC validation

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_spatial_word_window_bank_ooc_20260829.tcl
```

Run directory:
`build/reports/vivado_ds_spatial_word_window_bank_ooc_20260829/`

Post-route timing summary:

| Metric | Result |
|---|---:|
| Clock | 125 MHz (8.000 ns) |
| WNS | +3.839 ns |
| TNS | 0.000 ns; 0 failing endpoints |
| WHS | +0.118 ns |
| THS | 0.000 ns; 0 failing endpoints |
| Routing errors | 0 |
| Total on-chip power | 0.112 W |

Post-route utilization:

| Resource | Used | Device | Utilization |
|---|---:|---:|---:|
| LUT | 85 | 53,200 | 0.16% |
| FF | 288 | 106,400 | 0.27% |
| DSP | 0 | 220 | 0.00% |
| BRAM tile | 4 RAMB36E1 | 140 | 2.86% |

Vivado synthesis recognized four XPM synchronous dual-port RAMs, one per
32-bit plane.  The final cell report contains four `RAMB36E1` instances; the
previous implied-array implementation was intentionally replaced because
Vivado mapped it to distributed RAM despite `ram_style = block`.

This is primitive-level evidence only.  It does not establish full-network
timing, cycle count, or energy efficiency; integration still requires the
producer/runner contract and the authoritative full-top post-route run.
