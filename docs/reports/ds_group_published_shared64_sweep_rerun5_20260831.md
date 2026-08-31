# Group-published shared64 sweep: descriptor cursor timing rerun (2026-08-31)

## Change

`rtl/cnn/ds_group_published_shared64_sweep.v` now registers the descriptor-pop
acknowledgement in `desc_pop_pending`.  Publication still occurs on the pop
cycle, while `desc_rd_ptr` advances from the registered pulse on the next
cycle.  This removes the dynamic descriptor-array match cone from the
pointer's next-state path.  The only added state is one bit; the simulation
view and external interface are unchanged.

The OOC reproduction is
`scripts/vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun5.tcl`.
It uses Vivado 2025.2, XC7Z020CLG400-1, 8 ns, `general.maxThreads=1`,
`RuntimeOptimized` synthesis, and Explore place/phys-opt/route.

## Functional evidence

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_group_published_shared64_sweep_sim.sh"
```

Verilator 5.020 PASS.  Six-layer exact signed-output sweep remained:

| metric | total |
|---|---:|
| cycles | 87,553 |
| DW writes | 13,824 |
| descriptors | 864 |
| PW tokens | 65,536 |
| RQ writes | 21,504 |
| output writes checked | 86,016 |
| MACs | 4,194,304 |
| operations | 8,388,608 |
| intermediate RQ | 0 |

All six layers retained exact outputs, `first_k/last_k` counts, and zero
intermediate requantization.  The cursor bubble did not change the reported
layer cycle counts and the total remains below the 90,000-cycle local screen.

## OOC post-route evidence

Reports are under
`build/reports/vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun5/`.

| metric | result |
|---|---:|
| WNS / TNS | +0.175 ns / 0.000 ns |
| setup failing endpoints | 0 |
| WHS / THS | +0.087 ns / 0.000 ns |
| hold failing endpoints | 0 |
| LUT | 7,670 (14.42%) |
| FF | 19,662 (18.48%) |
| DSP | 81 (36.82%) |
| RAMB36 | 24 (17.14%) |
| total on-chip power | 0.369 W |
| route errors | 0 |
| unrouted / partially routed | 0 / 0 |

The worst setup path is now `desc_rd_ptr_reg[1]/C` to
`published1_reg[3][4]/D`: 7.770 ns, of which 1.845 ns is logic and 5.925 ns
is routing (76.254%); source fanout is 123. The RTL source is the dynamic
`desc_bank/desc_row/desc_group[desc_rd_ptr]` publication select at lines
524-529.  The former pointer-to-pointer path was 7.510 ns with -0.023 ns
slack; this rerun clears it with +0.175 ns slack.

The routed congestion report has no windows above level 5, although the
router log reports local East/West 1x1 maxima of 95.59%/86.76%.  These are
local hotspots, not unrouted nets.

The prior maxThreads=2 attempt reached 2,455.023 MB peak and stopped at
Technology Mapping.  The documented maxThreads=1 rerun1 failed in
`synth_design` with out-of-memory after 531.262 MB reported at read/elaboration
(host had approximately 1.5 GB free).  Rerun5 completed with 2,225.047 MB
peak, so the memory failure is no longer reproduced.

## Boundary and remaining risk

The four scratch memories are 256-bit x 64 synchronous XPM SDP instances
(16 RAMB36 total), and the weight memory is 64-bit x 4096 synchronous XPM SDP
(8 RAMB36), for 24 RAMB36 total.  The OOC netlist proves physical mapping and
route closure for this vehicle, not hardware protocol equivalence.

In the `SYNTHESIS` branch, `READ_LATENCY_B(1)` makes `scratch*_rd` and
`weight_mem_rd` one cycle behind `pw_scratch_addr` and `pw_weight_addr`, while
the consumer currently uses those wires as if reads were combinational.  The
untimed Verilator branch reads the register arrays directly and therefore does
not exercise this latency mismatch.  A registered read-response stage or
narrow response FIFO must be integrated and then re-run against the producer
contract before this vehicle can be promoted to the real DS path.

This slice is isolated and is not a full-top post-route result; the existing
authoritative full-top baseline remains unchanged.
