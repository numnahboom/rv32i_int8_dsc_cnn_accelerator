# Native response pipe + vector16 ping-pong shell composition (2026-08-29)

## Scope and ABI

`rtl/cnn/native_word_response_pipe_vector16_shell.v` is a standalone composition
boundary.  It captures the shell's tag/extent alongside the pipe's compact
`{epoch, bank, base_byte_addr, word_count}` fill, connects native memory
requests/responses to the response pipe, and forwards registered write commands
into `feature_tile_vector16_pingpong_shell`.  The pipe's final command is held
through the shell's serialized write drain (`wr_drain_ready`) before the shell
fill-done event is issued.  The aligned vector16 bank scatter now consumes the
registered `{base,data,mask}` command record (`wr_bypass_valid`) rather than
live pipe inputs.  This removes the pipe command address from the BRAM address
cone while retaining one accepted native word per cycle after one-cycle
priming.  The bank exposes its drain state so fill-done cannot retire while a
registered scatter is pending.  These are additive status/interface changes;
existing write/read semantics remain unchanged.

The shell's fill/acquire/consume/release descriptor channels and active-bank
vector read channel are relayed unchanged.  The composition wrapper uses local
tile addresses (base zero in the test); external memory address translation,
if needed, belongs above this ABI.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_native_word_response_pipe_vector16_shell_sim.sh'
```

The Verilator test instantiates both actual layouts: 10x10x3 Stem (75 native
words) and 10x10x48 DS (1,200 native words), with 4-cycle registered memory
response latency, request stalls, stale response injections, two-bank swaps,
ownership fences, and active-bank vector reads.  It performs 360 exact vector
comparisons, checks the drain fence, and records a 52-cycle one-word request acceptance streak (unchanged from the pre-cut composition):

```text
PASS tb_native_word_response_pipe_vector16_shell checks=360 errors=0 max_req_streak=52 cycles=3153
```

## OOC result

Script: `scripts/vivado_native_word_response_pipe_vector16_shell_ooc_20260829.tcl`;
reports: `build/reports/vivado_native_word_response_pipe_vector16_shell_ooc_20260829/`.

| Metric | Result |
|---|---:|
| Device / period | xc7z020clg400-1 / 8.000 ns (125 MHz) |
| WNS / TNS | **-0.081 ns / -0.195 ns** |
| WHS / THS | +0.154 ns / 0.000 ns |
| Setup / hold failing endpoints | 3 / 0 |
| LUT / FF | 5,263 (9.89%) / 5,331 (5.01%) |
| BRAM / DSP | 16 (11.43%) / 0 (0.00%) |
| Total on-chip power | 0.158 W |
| Route status | 0 failed, 0 unrouted, 0 partially routed |

The registered-scatter cut removes the former pipe-command-address failure
family and improves routed WNS by 3.255 ns, from -3.336 ns to -0.081 ns, while
reducing LUTs and power.  The strict candidate gate still requires WNS >= +0.5
ns, TNS = 0, and clean positive hold, so this remains a negative OOC result
and must not be integrated into the full CNN.  The three residual setup
failures are local registered-bank address-to-BRAM paths; the worst is
`u_shell/u_bank1/wr_base_reg_reg[1] -> gen_byte_bank[5].mem_reg/ADDRARDADDR[6]`
with 7.431 ns data delay (2.103 ns logic, 5.328 ns routing).  Broader feeder
composition changes are not justified by this narrow repair; abandon this
composition as a production direction unless the architecture is reconsidered.
