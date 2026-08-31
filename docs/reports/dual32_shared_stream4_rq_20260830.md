# dual32 shared stream4 requant candidate — 2026-08-30

## Disposition

**NEGATIVE_RESULT for promotion.** The candidate is functionally correct in its
standalone differential test and routes cleanly at 125 MHz, but it does not
meet the physical screening margin required before a full-top run:
`WNS >= +0.5 ns` and `WHS >= +0.1 ns`. It was not connected to
`cnn_layer_runner`, `cnn_top`, or the retained CSA full-top baseline.

## Files and reproducible commands

Candidate RTL and wrapper:

- `rtl/cnn/dual32_shared_stream4_rq.v`
- `rtl/cnn/dual32_shared_stream4_rq_ooc_wrapper.v`

Standalone verification and build files:

- `sim/tb_dual32_shared_stream4_rq.v`
- `sim/filelist_dual32_shared_stream4_rq.f`
- `scripts/run_dual32_shared_stream4_rq_sim.sh`
- `scripts/vivado_dual32_shared_stream4_rq_ooc_20260830.tcl`
- `scripts/dual32_shared_stream4_rq_ooc.xdc`

Verilator 5.020 command (from WSL):

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && scripts/run_dual32_shared_stream4_rq_sim.sh > build/dual32_shared_sim.log 2>&1'
```

Vivado 2025.2 OOC command:

```text
& 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts/vivado_dual32_shared_stream4_rq_ooc_20260830.tcl -nolog -nojournal -notrace
```

Reports and checkpoint are under
`build/reports/vivado_dual32_shared_stream4_rq_ooc_20260830/`.

## Functional and traffic evidence

The TB drives three separated blocks while holding input until both the
retained `dual32_mac_local_island` reference and the candidate accept the
token. It computes an independent signed mathematical reference with 32-bit
accumulator wrap and the exact requant round/shift/clamp rule. It checks word,
mask, pixel, channel, group, tag, mode, FIFO order, and output count. A second
`requant_activation_stream4` instance is attached to the candidate raw FIFO as
the four-lane arithmetic reference.

| mode | K | island groups | 32-bit output words | active scalar bytes |
|---|---:|---:|---:|---:|
| PW | 16 | 2 | 16 | 64 |
| STEM | 27 | 2 | 16 | 64 |
| DW | 9 | 1 | 8 | 32 |
| **total** | — | — | **40** | **160** |

Each output word is four int8 results (a 4-byte drain beat). The shared
`requant_activation_stream4` accepts one 4-lane FIFO entry per cycle (II=1)
and its ten tag stages preserve metadata; output backpressure is injected by
the TB. Thus `outputs=40 cycles=212` means 40 accepted 4-byte beats over the
whole reset/configure/compute/copy/requant/drain transaction, not 40 scalar
results and not a claim of 212 cycles for a full CNN inference.

Observed result:

```text
PASS dual32_shared_stream4_rq outputs=40 cycles=212
```

## Routed OOC result

Device `xc7z020clg400-1`, Vivado 2025.2, 8.000 ns clock (125 MHz),
`RuntimeOptimized` synthesis followed by `Explore` opt/place/phys-opt/route:

| metric | result |
|---|---:|
| WNS / TNS | +0.120 ns / 0.000 ns |
| setup failing endpoints | 0 |
| WHS / THS | +0.046 ns / 0.000 ns |
| hold failing endpoints | 0 |
| LUT | 13,399 (25.19%) |
| FF | 32,767 (30.80%) |
| DSP | 80 (36.36%) |
| BRAM | 0 (0%) |
| total on-chip power | 0.528 W (dynamic 0.419 W, static 0.109 W) |
| route errors | 0 |

The saved routed checkpoint was reopened and `report_route_status` was run:
56,874 logical nets, 44,464 routable nets, all 44,464 fully routed, and 0
nets with routing errors. The 12,410 nets not needing routing are constant or
otherwise unroutable-by-definition nets, not failed routes.

The first three setup paths are all the same FIFO-pointer-to-accumulator
family:

1. `u_dut/u_island0/result_wr_ptr_reg/C` ->
   `u_dut/u_island0/result_acc_reg[0][407]/D`, slack +0.120 ns, data delay
   7.675 ns = 0.718 ns logic (9.355%) + 6.957 ns route (90.645%), one LUT5.
2. `u_dut/u_island0/result_wr_ptr_reg/C` ->
   `u_dut/u_island0/result_acc_reg[0][14]/D`, slack +0.141 ns, data delay
   7.656 ns = 0.718 ns logic (9.379%) + 6.938 ns route (90.621%), one LUT5.
3. `u_dut/u_island0/result_wr_ptr_reg/C` ->
   `u_dut/u_island0/result_acc_reg[0][938]/D`, slack +0.148 ns, data delay
   7.697 ns = 0.718 ns logic (9.328%) + 6.979 ns route (90.672%), one LUT5.

The second island has the corresponding same-cone paths. This is not a
deep arithmetic failure; the critical delay is overwhelmingly physical
routing from a distributed write-pointer control signal.

## Physical cause and RTL correlation

The raw island stores wide two-entry result arrays in
`rtl/cnn/dual32_shared_stream4_rq.v` lines 316--323 and writes them on commit
at lines 417--431. The selected wide descriptor and dynamic island selection
are at lines 136--139. The copy loop dynamically slices the selected 1024-bit
accumulator/bias/multiplier and 192-bit shift descriptor into the raw FIFO at
lines 240--253; the RQ then reads the FIFO through `raw_rd_ptr` at lines
186--198. This is the descriptor/FIFO mux and storage structure under test.

The post-route high-fanout report identifies:

| net | fanout |
|---|---:|
| `u_dut/u_island1/result_shift[0][191]_i_1_n_0` | 9,345 |
| `u_dut/u_island0/result_shift[0][191]_i_1_n_0` | 9,344 |
| `u_dut/raw_max_fifo[15][31]_i_1_n_0` | 8,674 |
| `u_dut/u_island0/result_acc[1023]` / island1 counterpart | 2,240 each |
| `u_dut/u_island0/result_shift[1][191]_i_1_n_0` / island1 counterpart | 2,240 each |
| `u_dut/u_island0/result_wr_ptr` / island1 counterpart | 1,030 each |

These loads arise from wide array bit writes, dynamic read/slice muxing, and
the shared FIFO/RQ metadata path. The timing worst path itself is the
1,030-load `result_wr_ptr` net, while the 9,345/8,674-load descriptor/FIFO
signals show that the structure has a broader routing problem than a single
endpoint.

## Comparison with the old dual32 modulo candidate

The previous `dual32_mac_local_island` modulo version measured 96 DSP,
0.404 W, WNS -2.091 ns, and WHS -0.502 ns. The shared-stream4 candidate
changes those to 80 DSP, 0.528 W, WNS +0.120 ns, and WHS +0.046 ns:

- DSP improves by 16.7% (96 -> 80).
- Setup improves by 2.211 ns and hold becomes positive.
- LUT increases 5,843; in the saved OOC reports it is 13,399 versus 7,556
  (+77.3%), and FF is 32,767 versus 13,322 (+145.9%).
- Power is worse by 0.124 W (+30.7%), not an improvement; the wide FIFO,
  sideband storage, and switching dominate the DSP reduction.

The +0.120 ns result is therefore a real local timing improvement, but it is
not a robust promotion result. To reach the +0.5 ns screen without changing
logic delay, the current 6.957 ns route component would need to fall below
about 6.577 ns, while the same pointer family has several near-worst paths.
Hold also needs another 54 ps to reach +0.1 ns. A single endpoint-local
register or one pointer replication may move the worst endpoint, but it does
not remove the 9k-load descriptor/FIFO nets and can simply expose the next
member of the same family. A viable follow-up requires beat-localized
registers/banking and a fresh OOC screen, not a one-line timing exception or
one local path tweak.

## Stop line

Keep the candidate and its test as an auditable functional experiment, but do
not integrate it into the full top. Any descendant must first show lower
fanout and at least the +0.5/+0.1 ns OOC margin, then be evaluated against
full-top timing, cycles, resource, power, and exact logits together.
