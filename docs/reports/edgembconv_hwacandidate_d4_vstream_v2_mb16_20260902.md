# D4 persistent vector-stream v2 `mb16_down`

Date: 2026-09-02

## Scope and implementation boundary

This is an independent candidate. C0, the production runner, the legacy D4
composite/controller, and the v1 vstream controller are untouched. The v2
arithmetic boundary contains:

- seven-pixel dedicated PW island (112 DSP products);
- one 16-DSP elastic PW/RQ shared pool;
- one 16-DSP DW tile and two explicit scheduler DSP cells;
- a one-entry DW source response FIFO contract which permits response plus
  next-request on one edge;
- persistent DW weight configuration: 144 bytes for each of the two groups,
  288 bytes total, rather than configuration per tile.

The output-side response tag is the accepted request metadata. RQ writeback
decodes `rq_base` from the returned tag, so it does not assume a fixed latency
or use a controller issue cursor as a response address.

## Frozen-vector evidence

Command:

```text
bash scripts/run_edgembconv_hwacandidate_d4_vstream_v2_mb16_controller_sim.sh
```

The testbench uses the frozen real `mb16_down` vector set, deterministic source
and output backpressure, and checks all 8,192 output bytes. Result:

```text
output=8192 cycles=48848 pw_mac=786432 dw_mac=73728
rq_accept=12288 dw_cfg=288 dw_start=512 dw_req=4418 dw_resp=4418 final=8192 errors=0
PASS ... exact=8192 random_backpressure=checked
```

With both source and output ready continuously:

```text
output=8192 cycles=47646 pw_mac=786432 dw_mac=73728
rq_accept=12288 dw_cfg=288 dw_start=512 dw_req=4418 dw_resp=4418 final=8192 errors=0
PASS ... exact=8192
```

The accepted arithmetic ledger is therefore:

| stream | exact work |
|---|---:|
| PW expand | 524,288 MAC |
| PW project | 262,144 MAC |
| DW | 73,728 MAC |
| RQ | 12,288 four-lane transactions |
| DW requests/responses | 4,418 / 4,418 |
| DW padding/taps | 190 / 4,608 |
| DW starts | 512 |
| DW configuration | 288 bytes |
| final sink commits | 2,048 four-byte commits = 8,192 bytes |

No mismatch, dropped output, duplicate output, stale tag, or protocol error was
observed. The v2 source-ready contract is capacity-based and consumes a
response and accepts the next request on the same edge when available.

## Cycle gate and remaining risk

The no-backpressure result is 47,646 cycles, so this milestone does **not** pass
the requested 25,000-cycle gate. The 8,192-byte sink is measured as a visible
part of the transaction (8,192 sink cycles with no backpressure); it is not
hidden from the cycle count. The present controller fences each PW tile and DW
tile before the next tile, and emits one byte per sink cycle. Consequently the
measured phase state counts show the structural gap: 4,096 expand-PW cycles,
11,008 expand-RQ cycles, 7,920 DW-wait cycles, 7,680 DW-RQ cycles, 2,048
project-PW cycles, 2,752 project-RQ cycles, and 8,192 output cycles, plus
pipeline fences. A full ≤25k result requires a parent-level multi-tile
ping-pong scheduler and a wider/streaming final sink contract; this v2 result
must not be presented as timing/cycle closure.

No OOC, post-route, synthesis, power, or DSP-topology claim is made by this
functional milestone.
