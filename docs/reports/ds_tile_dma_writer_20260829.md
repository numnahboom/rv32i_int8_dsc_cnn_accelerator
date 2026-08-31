# Registered DS tile DMA writer (2026-08-29)

## Scope

`rtl/cnn/ds_tile_dma_writer.v` is a standalone, unintegrated writer for the
existing 128-bit `ds_input_tile_buffer_bram`.  It captures a compact
`{bank,epoch,base,extent}` fill command, aligns native 32-bit requests, and
stores an in-order byte-lane token for each request.  The response stream has
no ready signal, so total outstanding requests are bounded by the active
parser plus the response FIFO; a stale response with no token is discarded
and counted.

The response parser consumes one selected byte per clock.  A registered
accumulator groups four bytes (or three for the 3-channel Stem shape) into a
vec4 command.  A final short group is held in registered tail state and is
drained as scalar commands before `fill_done_valid` is raised.  The BRAM write
command itself is held in a registered ring FIFO, so no live response word or
wide variable decode reaches the write port.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_ds_tile_dma_writer_sim.sh'
```

Verilator 5.020 passed all three fixed 10x10 shapes with unaligned bases,
short extents, request bubbles, four-cycle registered responses, completion
drain, and stale responses after the fence:

| Layout CIN | Exact byte checks | Requests/responses | BRAM commands | Sim cycles |
|---:|---:|---:|---:|---:|
| 3  | 1,600 | 76 / 76 | 101 | 595 |
| 16 | 1,600 | 400 / 400 | 400 | 2,216 |
| 48 | 4,800 | 1,200 / 1,200 | 1,202 | 6,620 |

An additional short-tail run (`CIN=3`, base byte 3, extent 5) passed 1,600
checks with 2 requests/responses and 3 drained commands, covering the
lane-3 one-byte final-word case.

The source model accepts native requests on ready edges and returns every
accepted word in order.  Maximum accepted request streaks were 9/8/8,
including an initial one-word-per-cycle ready window, under the deterministic
ready-bubble pattern.  The test explicitly checks that the
completion descriptor is retained through the drain and that post-fence
responses increment `stale_resp_count` rather than entering a later epoch.

## XC7Z020 routed OOC screen

Command:

```text
vivado.bat -mode batch -source scripts/vivado_ds_tile_dma_writer_ooc_20260829.tcl
```

Target is `xc7z020clg400-1`, 8.000 ns clock, RuntimeOptimized synthesis,
placement, phys-opt, and route with two implementation threads.

| Metric | Post-route |
|---|---:|
| Setup WNS / TNS | +1.059 ns / 0.000 ns |
| Hold WHS / THS | +0.147 ns / 0.000 ns |
| Failing setup / hold endpoints | 0 / 0 |
| LUT / FF | 911 / 1,167 |
| BRAM / DSP | 4 / 0 |
| Vectorless total on-chip power | 0.138 W |
| Route errors | 0 |

This is an OOC primitive result, not full-top timing, resource, power, or
end-to-end CNN evidence.  The writer remains a candidate until a future
ping-pong shell proves its runner contract and full-network effect.
