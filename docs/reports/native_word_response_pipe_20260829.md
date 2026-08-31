# Native 32-bit response alignment pipe (2026-08-29)

## Scope

`rtl/cnn/native_word_response_pipe.v` is an isolated protocol primitive for a
future vector feeder.  It is not connected to the CNN runner or any production
shell.  The fill record captures `{epoch, bank, base_byte_addr, word_count}`;
each `issue_valid && issue_ready` handshake reserves one in-order token and
drives an aligned native-word `mem_req_addr`.  Responses may have any bubbles
or latency; the token FIFO matches them by order, and the elastic command FIFO
holds registered write records under `wr_ready` backpressure.

The API intentionally has no response-ready signal: the attached native memory
must return every accepted request in order.  The combined token/command
capacity limits issued requests to what can be absorbed.  A response with no
outstanding token is discarded and increments `stale_resp_count`.  Because the
response has no epoch tag, `fill_start_ready` is fenced until the old epoch's
tokens and commands have drained; this is the stale-epoch guarantee that a
native untagged memory can actually provide.

`word_count` is a count of complete 32-bit words.  Thus `wr_byte_mask` is
`4'b1111` for every command, `wr_byte_addr` preserves an unaligned base, and
`mem_req_addr` aligns the corresponding source request down to a 4-byte
boundary.  `wr_last` marks the final native word (including a short/tail
transaction at the protocol level).

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_native_word_response_pipe_sim.sh'
```

The Verilator test drives 4,200 words in two epochs (1,900 + 2,300), bases
`0x103` and `0x007`, randomized request acceptance, variable in-order memory
latencies (1--8 cycles), response bubbles, output stalls, and two stale
responses.  It checks every command's epoch/bank/address/data/mask/last order,
then drains both FIFOs:

```text
PASS tb_native_word_response_pipe issues=4200 responses=4200 checks=4200 stale=2 cycles=5659
```

## XC7Z020 8 ns post-route OOC

Script: `scripts/vivado_native_word_response_pipe_ooc_20260829.tcl`;
report directory:
`build/reports/vivado_native_word_response_pipe_ooc_20260829/`.

| Metric | Result |
|---|---:|
| Device / period | xc7z020clg400-1 / 8.000 ns (125 MHz) |
| WNS / TNS | +1.009 ns / 0.000 ns |
| WHS / THS | +0.186 ns / 0.000 ns |
| Setup / hold failing endpoints | 0 / 0 |
| LUT / FF | 1,967 (3.70%) / 6,114 (5.75%) |
| BRAM / DSP | 0 (0.00%) / 0 (0.00%) |
| Total on-chip power | 0.147 W |
| Route status | 0 failed, 0 unrouted, 0 partially routed |

This is an OOC primitive gate only; it does not establish full-top timing,
resource, power, or end-to-end CNN acceptance.

## Shell integration notes

Capture `fill_*` on `fill_start_valid && fill_start_ready`, keep `issue_valid`
high while the feeder has work, and connect `mem_req_valid/addr` to the native
memory request port (`mem_req_ready` is its request acceptance).  Return each
accepted request's 32-bit data on `mem_rvalid/mem_rdata` in issue order.  Consume
`wr_*` only on `wr_valid && wr_ready`; completion is the registered
`fill_done_valid` pulse, which occurs only after the final `wr_last` command is
accepted.  Do not begin a new untagged-memory epoch until that completion and
the response source's own pipeline are drained.
