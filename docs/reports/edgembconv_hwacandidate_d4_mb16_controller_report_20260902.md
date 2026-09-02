# EdgeMBConv D4 `mb16_down` composite-backed controller gate

This is an independent D4 candidate artifact.  It does not modify C0, the
production runner, the existing D4 composite datapath, the block shell, or
legacy DS RTL.

## Intended contract

`edgembconv_hwacandidate_d4_mb16_controller` drives the complete
`32x32x16 -> 16x16x32` stride-2 block through one instance of
`edgembconv_hwacandidate_d4_composite_datapath`:

```text
PW expand -> scratch0 (FREE/FILL/READY/ACTIVE fence)
          -> DW16 (9-tap SAME halo, two 16-channel groups)
          -> scratch1 (READY/ACTIVE fence)
          -> PW project -> output stream
```

PW, DW, and four-lane INT32 requantization are connected to the composite
interface; the controller does not instantiate or copy a second DSP array.
The local scratch read response is registered and its `scratch_read_ready`
input is randomized by the testbench.  The output stream also has
deterministic randomized backpressure and checks index/data stability while
stalled.

## Validation command

```text
scripts\\run_edgembconv_hwacandidate_d4_mb16_controller_sim.ps1
```

Vivado 2025.2 `xvlog` and `xelab` both succeeded.  The complete controller
transaction reached the output stream and emitted all 8,192 output indices;
the testbench then failed its byte-exact scoreboard:

```text
D4_MB16 block=mb16_down output_bytes=8192 cycles=208412 pw_mac=786432 dw_mac=39168 overlap=0 ... errors=8166
FAIL edgembconv_hwacandidate_d4_mb16_controller errors=8166
```

The semantic expected totals are 786,432 PW MACs and 73,728 DW MACs.  The
observed `dw_mac=39,168` is 272 completed DW vectors (at 144 MACs each), not
the required 512 vectors.  The output therefore contains unwritten/incorrect
bytes.  This is a real functional failure, not a timing, OOC, or optimistic
cycle-model result.  The exact preserved console is under
`build/edgembconv_hwacandidate_d4_mb16_controller_sim/console_latest.txt`.

## Current blocker

The composite-backed DW controller handshake loses or prematurely completes
part of the 16x16x32 DW output traversal under the registered local-scratch
response path.  The next bounded iteration must first instrument and repair
the DW scheduler/controller event ownership, then rerun the same full-vector
scoreboard.  No performance or implementation conclusion is drawn from this
failed gate; `overlap=0` remains an honest measured value.

## Artifacts

- RTL: `rtl/cnn/edgembconv_hwacandidate_d4_mb16_controller.v`
- Testbench/filelist: `sim/tb_edgembconv_hwacandidate_d4_mb16_controller.v`,
  `sim/filelist_edgembconv_hwacandidate_d4_mb16_controller.f`
- Launcher: `scripts/run_edgembconv_hwacandidate_d4_mb16_controller_sim.ps1`

