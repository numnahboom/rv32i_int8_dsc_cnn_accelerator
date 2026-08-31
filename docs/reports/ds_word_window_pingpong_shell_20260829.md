# Single-word/two-bank window shell (2026-08-29)

## Scope

This is a non-production DS storage/dataflow shell.  It uses two instances of
`ds_spatial_word_window_bank`, but only one source-word fill engine.  A fill
command captures the destination bank and epoch, issues aligned 32-bit source
requests, and carries `{vector_addr, quarter, epoch}` through an eight-entry
in-order descriptor FIFO.  The inactive bank is therefore written at one
accepted response/word per clock when the source is continuous.

The reader captures an active bank/epoch and walks a programmable row-major
window.  `read_stride` and `read_pitch` are captured into registered address
steps; no dynamic multiply is present in the per-request address recurrence.
The bank's registered 128-bit response is captured by a second shell register
before being exposed to the consumer.  The four-state fence is:

```
FREE --fill_start--> FILL --fill_done--> READY --read_start--> ACTIVE
  ^                                                        |
  +---------------------- release(epoch) ----------------+
```

An epoch mismatch on read start or release cannot change ownership.  The
outward completion descriptors are held until their ready inputs are asserted.
No production runner, full-network RTL, direct DW core, or `cnn_top` source was
modified or integrated.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_word_window_pingpong_shell_sim.sh'
```

Verilator 5.020 passed all three parameterized cases with exact byte-vector
comparison under source request bubbles, registered response latency, periodic
consumer backpressure, concurrent inactive-bank fill, bank swap, and a stale
epoch release:

| Layout | Fill words (both banks) | Read vectors (both reads) | Overlap cycles | Sim cycles |
|---|---:|---:|---:|---:|
| 10x10, 16 channels, stride 1 | 800 (400/fill) | 200 (100/read) | 439 | 1,491 |
| 10x10, 48 channels, stride 1 | 2,400 (1,200/fill) | 200 (100/read) | 513 | 3,150 |
| 17x17, 16 channels, stride 2 | 4,616 (2,308/fill) | 578 (289/read) | 1,485 | 6,523 |

The stride-2 case uses a 17-pixel row pitch and checks the address span through
vector address 576 (the backing bank is provisioned for the 17x17x3 worst-case
vector capacity).  Every response's address, epoch, lane mask, and 128-bit
payload was compared against the source model.  The test also checks exactly
once fill/read counters and rejects the wrong-epoch release before valid
release.

## 8 ns XC7Z020 OOC post-route

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_pingpong_shell_ooc_20260829.tcl
```

Run directory:
`build/reports/vivado_ds_word_window_pingpong_shell_ooc_20260829/`

The fixed worst-case shell is 17x17 storage with three channel groups.  Vivado
2025.2 targeted `xc7z020clg400-1`, `general.maxThreads=2`, out-of-context
synthesis/place/route, and an 8.000 ns clock.

| Metric | Post-route result |
|---|---:|
| WNS | +1.355 ns |
| TNS / setup failing endpoints | 0.000 ns / 0 |
| WHS / THS / hold failing endpoints | +0.105 ns / 0.000 ns / 0 |
| Routing errors / unrouted nets | 0 / 0 |
| Slice LUTs | 588 / 53,200 (1.11%) |
| Slice registers | 1,177 / 106,400 (1.11%) |
| DSP | 1 / 220 (0.45%) |
| Block RAM tiles | 8 / 140 (5.71%) |
| Estimated total on-chip power | 0.113 W |

The earlier unregistered address recurrence synthesized a DSP-based dynamic
multiply and routed at WNS -1.402 ns.  Registering the column step and row
delta at read admission removed that DSP from the per-request recurrence and
produced the +1.355 ns result above.  This is a shell-level physical gate only;
it does not establish full-top timing, complete-network cycles, or energy
efficiency.
