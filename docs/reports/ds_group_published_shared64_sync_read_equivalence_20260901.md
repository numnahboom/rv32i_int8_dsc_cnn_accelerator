# Group-published shared64 synchronous-read equivalence (2026-09-01)

## Scope

This slice closes the physical-memory semantic gap in the isolated
`ds_group_published_shared64_sweep` validation vehicle.  The synthesis view
uses XPM SDP memories with `READ_LATENCY_B(1)`, while the former Verilator
view directly dereferenced unpacked arrays.  The latter could therefore hide
an address/data alignment bug.

The RTL now uses registered read-response data in the Verilator view and
look-ahead read addresses for the physical XPM view.  Each clock edge samples
the address and the response is visible during the following cycle.  The PW
schedule advances only on shared-array input acceptance.  When it accepts a
response, the next schedule address is presented to the BRAMs at that same
edge, preserving the existing initiation interval.  During output
backpressure the schedule and address remain fixed, so the registered
response remains stable.  Publication is still gated by the descriptor FIFO:
the final row write precedes publication, and `first_k/last_k` remain based on
the complete-K schedule rather than individual groups.

The BRAM read ports remain enabled by the registered `S_RUN` state rather
than the wide scheduler-valid expression.  This preserves the synchronous
read contract while avoiding a long scheduler-to-ENARDEN timing path.

## Functional evidence

Command (WSL, Verilator 5.020):

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_group_published_shared64_sweep_sim.sh"
```

The six-layer producer-driven sweep passed with exact signed outputs and the
following aggregate counts:

| metric | result |
|---|---:|
| cycles | 87,553 |
| DW writes | 13,824 |
| group descriptors | 864 |
| PW tokens | 65,536 |
| output writes checked | 86,016 |
| MACs | 4,194,304 |
| operations | 8,388,608 |
| intermediate requantizations | 0 |

The layers exercise different session/epoch values, Cin 16/32/64/128,
Cout 32/64/128/256, P 16/64/256/1024, K tails, output masks, descriptor
publication and deterministic output backpressure.  First/last-K counts and
descriptor/output-group counts matched every layer.  The simulation output is
captured in `build/reports/ds_group_published_shared64_sync_read_sim4.log`.

## Fresh post-route OOC evidence

Reproduction script:

```text
scripts/vivado_ds_group_published_shared64_sweep_ooc_20260901_rerun10.tcl
```

Reports:

```text
build/reports/vivado_ds_group_published_shared64_sweep_ooc_20260901_rerun10/
```

Vivado 2025.2, XC7Z020CLG400-1, 8 ns clock, RuntimeOptimized synthesis,
Explore place/phys-opt/route, `general.maxThreads=1`:

| metric | result |
|---|---:|
| WNS / TNS | +0.032 ns / 0.000 ns |
| setup failing endpoints | 0 |
| WHS / THS | +0.083 ns / 0.000 ns |
| hold failing endpoints | 0 |
| LUT | 7,698 (14.47%) |
| FF | 19,650 (18.47%) |
| DSP | 81 (36.82%) |
| RAMB36 | 24 (17.14%) |
| total on-chip power | 0.367 W |
| fully routed nets | 26,470 |
| route errors | 0 |

The worst setup path is a PW group counter to a synchronous scratch BRAM
address input, 7.318 ns data-path delay (2.161 ns logic, 5.157 ns routing).
The timing reports contain no setup or hold failures.  The final checkpoint is
`ds_group_published_shared64_sweep_ooc_post_route.dcp` in the same directory.

## Boundary

This is a fresh isolated OOC closure and physical memory mapping proof.  It is
not a full-top result and does not authorize runner or fullnet integration by
itself.  The next parent-level action is to compare this exact synchronous-read
vehicle against the integration contract before any runner change.

