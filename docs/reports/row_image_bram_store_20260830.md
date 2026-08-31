# Row-image BRAM36 store — 2026-08-30

This is a standalone, non-production prerequisite primitive.  It does not
modify the CNN runner, DS pipeline, or full-network filelists.

## Contract

`row_image_bram_store` stores eight `{mask[3:0],data[31:0]}` planes at each
8-bit address `{row[2:0],group[3:0],half}`.  A registered write updates one
plane per cycle.  A read request is synchronous and returns the reconstructed
256-bit data and 32-bit mask one cycle later.  The response is elastic under
`rd_ready` backpressure; requests are accepted when the single response slot
is empty or being retired.  Reset clears protocol valid state only and never
initializes the array.  Same-cycle read/write collisions are READ_FIRST.

The implementation uses eight explicit `RAMB36E1` SDP primitives, one per
logical plane.  This avoids Vivado's legal but undesirable packing of two
logical planes into one tile and gives a clear eight-bank placement boundary.
The read reconstruction is a static concatenation of registered BRAM outputs;
there is no asynchronous variable-address array mux.

## Functional validation

Command:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_row_image_bram_store_sim.sh'
```

Result: PASS.  The Verilator test performs 4,098 accepted writes and 3,002
gathers, with 8,966 output/data checks.  It covers every row/group/half address,
all eight planes, arbitrary masks and payloads, repeated overwrites,
read-response backpressure and stability, one-cycle latency, and two explicit
same-cycle collision checks for READ_FIRST behavior.  The testbench does not
present writes until after its abstract ownership-fence point.

## XC7Z020 OOC post-route screen

Command:

```text
vivado.bat -mode batch -source scripts/vivado_row_image_bram_store_ooc_20260830.tcl
```

Target: `xc7z020clg400-1`, 8.000 ns clock, out-of-context synthesis/place/route,
`general.maxThreads=2`.

| Metric | Post-route result |
|---|---:|
| WNS / TNS | +4.293 ns / 0.000 ns |
| WHS / THS | +0.295 ns / 0.000 ns |
| LUT | 8 (0.02%) |
| FF | 1 (<0.01%) |
| RAMB36E1 | 8 (5.71%) |
| RAMB18 | 0 |
| DSP | 0 |
| Total on-chip power | 0.108 W |
| Routing errors | 0 |

The timing, resource, and power reports are under
`build/reports/vivado_row_image_bram_store_ooc_20260830/`.  These are OOC
primitive results only and are not evidence of full-top closure.

## Remaining risk

The explicit primitive is intentionally wasteful in BRAM capacity (8 tiles for
9,216 bits of logical payload) to preserve independent bank placement.  Any
future integration must prove that this placement boundary outweighs the BRAM
cost and must re-run exact DS/fullnet simulation plus fresh full-top post-route
timing and power.
