# Wordstream feasibility harness (2026-08-29)

## Result

`NEGATIVE_RESULT` for the bounded standalone feasibility slice.  The harness
is functionally correct and proves the native-word feeder, the first Stem
shape, the first traffic-heavy DS shape, shared MAC mode ownership, and
loading bank N+1 while consuming bank N.  The complete harness does not pass
the requested 8 ns OOC timing gate and is not a full-network candidate.

## Scope and ABI

`rtl/cnn/wordstream_feasibility_harness.v` is a standalone fixed-shape model
of the real first layers:

* Stem: 32x32x3 to 32x32x16, 3x3, padding 1, NHWC bytes;
* DS1: 32x32x16 to 32x32x32, depthwise 3x3, padding 1, then PW;
* source words use the feeder's synchronous 32-bit native-word ABI, with
  unaligned bases 0x000003 and 0x004003 and realistic row strides 96 and
  512 bytes;
* weights are signed int8 and outputs use the identity Q31/zero-bias
  quantization boundary with int8 activation clamp [-128,127].

The first bank is activated for Stem consumption before DS1 is filled into
the other bank.  The DS bank fill overlaps Stem compute and is only activated
after its fill-done fence.  `mac16_stream_shared_wrapper` is the sole shared
16-lane MAC and the existing `pw_direct_8x8_dsp` is used for PW blocks.

## Functional evidence

Command:

```text
bash scripts/run_wordstream_feasibility_sim.sh
```

Verilator 5.020 passed:

* 65,536 exact byte comparisons covering Stem, DW, and PW output memories;
* 45,056 accepted MAC/PW tokens;
* 4,930 accepted native-word requests and 4,930 responses;
* 4,827 cycles with DS-bank loading concurrent with active Stem consumption;
* memory responses are generated one cycle after accepted requests, with
  deterministic request backpressure.

## 8 ns XC7Z020 OOC evidence

Final source-matching command:

```text
vivado.bat -mode batch -source scripts/vivado_wordstream_feasibility_ooc_20260829.tcl
```

Reports are under
`build/reports/vivado_wordstream_feasibility_ooc_20260829/`, target
`xc7z020clg400-1`, with `general.maxThreads=2`:

* setup WNS **-1.003 ns**, TNS **-3.738 ns**, 6 failing endpoints;
* route status: 3,667 fully routed nets, 0 routing-error nets;
* hold is positive (no hold violations in the post-route summary);
* LUT 2,130 (4.00%), FF 1,802 (1.69%), BRAM 8.5 (6.07%), DSP 16 (7.27%);
* vectorless on-chip power 0.138 W;
* DRC reports no related violations.

The OOC screen therefore fails the required +0.5 ns feasibility gate by
1.503 ns.  The critical cost is not the feeder BRAM itself: exposing the
shared MAC result checksum retains the 16 DSP lanes, and the registered
control/accumulator fanout then produces a small but timing-negative OOC
cluster.  The storage arrays are simulation-only in the OOC wrapper so the
resource result is a datapath/control screen, not a production memory map.

## Follow-up

Do not integrate this harness into `cnn_layer_runner` or run full-top from
this result.  A useful next experiment is an independent timing wrapper for
the shared MAC plus registered per-lane output reduction, followed by a
dedicated storage/commit design; the current serialized byte gather also
projects to roughly 0.56M cycles for just the first Stem+DS slice and cannot
support the 150k-cycle full-network projection.
