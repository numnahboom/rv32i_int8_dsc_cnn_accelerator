# Word-window DW producer island (2026-08-29)

## Scope

`ds_word_window_dw_producer_island` is a non-production integration helper. It
connects the registered vector response of `ds_word_window_pingpong_shell` to
the existing sixteen-lane direct DW arithmetic core. A compute command is one
8x8 output tile and one 16-channel tile. Cin=48 and Cin=128 are exercised as
three and eight independently filled channel-tile commands, respectively;
the production runner and PW path are intentionally untouched.

The shell read response is captured into four narrower local synchronous RAM
banks. A registered address/data prefetch then drives the DW token registers.
The scheduler's address recurrence emits the nine taps in row-major order:

* stride 1: 10x10 footprint, 100 wide vector reads;
* stride 2: 17x17 footprint, 289 wide vector reads;
* each compute command: exactly 576 accepted tap tokens and 64 outputs.

The source fill is independently commandable. The bench starts the next
inactive-bank fill immediately after compute admission, so the shell's fill
and active copy/compute regions overlap. Bank and epoch are held through the
read and release fence. No shell bank select or live BRAM output is connected
to a DSP operand.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_word_window_dw_producer_island_sim.sh'
```

Verilator 5.020 passed all six configurations with exact signed-int8 raw DW
sum comparison, lane-tail masks, explicit footprint padding, source request
bubbles, synchronous response latency, output backpressure, alternating bank
swaps, and monotonically changing epochs:

| Cin | stride | channel tiles | reads/tile | tokens/tile | outputs/tile | total sim cycles | overlap cycles |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 1 | 100 | 576 | 64 | 3,843 | 428 |
| 16 | 2 | 1 | 289 | 576 | 64 | 5,586 | 1,226 |
| 48 | 1 | 3 | 100 | 576 | 64 | 10,621 | 1,284 |
| 48 | 2 | 3 | 289 | 576 | 64 | 14,254 | 3,680 |
| 128 | 1 | 8 | 100 | 576 | 64 | 27,567 | 3,426 |
| 128 | 2 | 8 | 289 | 576 | 64 | 35,925 | 9,810 |

The fill counter includes one shadow fill of the inactive bank to make overlap
observable: 400 native words per stride-1 channel tile, or 1,156 per stride-2
tile. The accepted read/token/output counters are checked exactly once per
command. The test does not claim full-network equivalence.

## 8 ns XC7Z020 OOC post-route

Command:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_ds_word_window_dw_producer_island_ooc_20260829.tcl
```

Run directory:
`build/reports/vivado_ds_word_window_dw_producer_island_ooc_20260829/`

Vivado 2025.2, `xc7z020clg400-1`, `general.maxThreads=2`, out-of-context
synthesis/place/route, and an 8.000 ns clock produced:

| Metric | Post-route result |
|---|---:|
| WNS / setup failures | +0.617 ns / 0 |
| TNS | 0.000 ns |
| WHS / hold failures | +0.093 ns / 0 |
| Routing errors / unrouted nets | 0 / 0 |
| Slice LUTs | 1,250 (2.35%) |
| Slice registers | 5,146 (4.84%) |
| DSP48E1 | 17 (7.73%) |
| Block RAM tiles | 12 (8.57%): 10 RAMB36 + 4 RAMB18 |
| Estimated total on-chip power | 0.139 W |

The OOC timing gate is met. The extra DSP is the shell's runtime row-delta
address calculation; it is not a second DW arithmetic lane. The local window
store is four explicit XPM block-RAM banks, while the shell itself contributes
the ten RAMB36 tiles in this worst-case 17x17/three-group boundary.

This is an island-level physical gate only. It does not establish runner
integration, full-network cycle count, full-top timing closure, or 20 GOPS/W.
Those claims require a separate exact full-network regression and fresh
post-route `cnn_top` implementation.
