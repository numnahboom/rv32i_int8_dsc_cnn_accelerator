# DS persistent feed BRAM adapter (2026-08-31)

This report covers the independent physical replacement proof vehicle
`rtl/cnn/ds_persistent_feed_contract_bram.v`.  It does not modify
`cnn_top`/`cnn_layer_runner` and is not a full-network result.

## Contract and implementation

The module keeps the legacy `ds_persistent_feed_contract` port ABI and the
same DS1/DS3/DS6 PW shapes, external loader counts, commit fence, epoch/session
stale rejection, source-window reuse, tail masks, and token ready/valid
semantics.  The original contract source is not in this test filelist; the
legacy testbench therefore exercises the new implementation directly.

The physical changes are:

- Source storage is a 32-bit synchronous-read SDP XPM block RAM.  The gather
  address is a registered linear cursor (`win_source_addr_reg`) and advances
  by one; no runtime spatial multiplication is on the read address path.
- Parameters are two fixed 32-bit block-RAM banks (`param_lo`/`param_hi`).
  Loader state explicitly tracks `param_tile_idx`, `param_k_in_tile`,
  `param_row_addr`, and `param_half`; a tile boundary advances by the constant
  `MAX_CIN` stride.  There is no division/modulo or variable part-select in
  the parameter write path.
- The gathered 8-pixel window is four fixed 64-bit channel rows per group,
  generated for 32 groups.  Each write chooses a fixed byte case and each
  token chooses a shallow fixed group/channel case; no variable-indexed RAM or
  multi-port variable part-select write is used.
- Source and parameter BRAM outputs have explicit one-cycle capture.  A
  parameter row is read ahead only when the current token is accepted, so
  payload remains stable under output backpressure.
- Job metadata is captured at the external handshake and launched one cycle
  later.  Reuse is decided before replacing the window owner, while the
  committed configuration registers remain the epoch/session fence.

## Functional and traffic evidence

Reproduce with:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_persistent_feed_contract_bram_sim.sh"
```

`sim/tb_ds_persistent_feed_contract_bram.v` is the independent adapter
testbench entry; it includes the original nonzero source/weight checker so
traffic and value comparisons cannot drift.  The regression is the same
reference test with
independent source/parameter request bubbles, token backpressure, tail masks,
window reuse, and stale epoch/session rejection.

| probe | cfg/load cycles | job cycles | external source words | external parameter words | local source reads | local parameter rows | reused windows |
|---|---:|---:|---:|---:|---:|---:|---:|
| DS1 PW, 3 jobs | 9563 | 260 | 4096 | 128 | 112 | 48 | 1 |
| DS3 PW, 2 jobs | 9563 | 535 | 4096 | 1024 | 256 | 128 | 2 |
| DS6 PW, 2 jobs | 18029 | 1057 | 512 | 8192 | 512 | 256 | 3 |

Final simulation result: `PASS ds_persistent_feed_contract`, 432 accepted
tokens, 880 local source reads, 432 local parameter rows, and 3 reuses.
The external traffic exactly matches the original contract test:
DS1 4096/128, DS3 4096/1024, and DS6 512/8192 source/parameter words.  The
extra cycles are the explicit BRAM response and source-data staging latency;
traffic and token values are unchanged.

## XC7Z020 routed OOC

Reproduce with Vivado 2025.2:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -source scripts/vivado_ds_persistent_feed_contract_bram_ooc_20260831.tcl
```

The run targets `xc7z020clg400-1`, an 8.000 ns clock, and completes through
route with zero route errors.  Reports are under
`build/reports/vivado_ds_persistent_feed_contract_bram_ooc_20260831/`.

| metric | routed result | gate |
|---|---:|---:|
| WNS | **+0.626 ns** | >= +0.5 ns |
| TNS / setup failing endpoints | **0.000 ns / 0** | 0 |
| WHS | **+0.106 ns** | >= +0.1 ns |
| THS / hold failing endpoints | **0.000 ns / 0** | 0 |
| LUT | 3,096 (5.82%) | <70% |
| FF | 8,651 (8.13%) | <70% |
| DSP | 0 (0%) | <70% |
| RAMB36 | 40 (28.57%) | <70% |
| total on-chip power | 0.148 W | <3 W |
| route errors | 0 | 0 |

The worst setup path is a local `win_pixel_slot` to row-register data path,
with 7.123 ns data delay (0.580 ns logic, 6.543 ns routing) and 0.626 ns
slack in `timing_max.rpt`; the summary WNS is also +0.626 ns across all
18,457 endpoints.  The worst hold path is a local `win_source_addr_reg`
feedback path, reported at +0.106 ns in `timing_min.rpt` and in the summary.
No setup or hold endpoint fails.

The top fanout is the unused/external `source_base_reg` decode at about 8.6k
loads; the active token/window control nets are at most about 180 loads in the
reported top-50 list.  This is substantially different from the rejected
contract's 38.124 ns path: the rejected design used runtime `cin` division and
variable writes that became 2,048 distributed RAM primitives.  The adapter
has zero LUT-as-memory and its source/parameter banks are mapped to 40
RAMB36E1 primitives.

## BRAM accounting boundary

The generic 32,768 x 32-bit source capacity maps to 32 RAMB36E1 primitives on
7-series because of the legal depth/width granularity; the two 4,096 x
32-bit parameter banks use 4 primitives each, for 40 total.  This is below
70% but above the earlier idealized 37-RAMB36 estimate.  C10 DS traffic in the
contract uses at most 4,096 source words per configured layer (DS6 uses 512),
so a production replacement should instantiate stage-sized source banks
(16k words or smaller, depending on the runner's lifetime/fence scope): that
projects 16 source + 8 parameter = **24 RAMB36E1**, before any optional
double-bank overlap.  The current generic proof keeps 32k capacity to avoid
silently narrowing the ABI and is not promoted as a resource-final design.

## Promotion boundary and remaining risk

This adapter passes the local functional and 8 ns physical gate and is a
usable replacement candidate for integration experiments.  It does not prove
DW 3x3 token scheduling, DW/PW overlap, fullnet logits, full-network cycles,
or full-top post-route timing.  Promotion still requires a real producer-driven
DS integration, exact fullnet MAC/logit/cycle regression, stage-sized BRAM
selection, then a fresh `cnn_top` Explore implementation and energy calculation.
