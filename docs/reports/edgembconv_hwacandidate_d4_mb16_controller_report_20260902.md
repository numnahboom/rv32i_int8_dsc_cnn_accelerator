# EdgeMBConv D4 `mb16_down` composite-backed controller gate

This is an independent D4 candidate artifact.  It does not modify C0, the
production runner, the block shell, or legacy DS RTL.  The existing D4
composite datapath received one minimal RQ transaction-lifetime fence: it
blocks a new RQ input on the cycle in which its shared pool result is copied
to the composite output register.  Arithmetic and quantization are unchanged.

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

Vivado 2025.2 `xvlog` and `xelab` both succeeded for the standalone composite
regression and the controller regression.  The existing composite test passed
its PW/RQ mode switch and DW stride/stall cases:

```text
D4_COMPOSITE_DW stride=1 out=(3,3) cycles=43
D4_COMPOSITE_DW stride=2 out=(2,2) cycles=44
PASS edgembconv_hwacandidate_d4_composite_datapath mapping=112PW+16dual+18DW stalls=checked
```

The full real-vector controller gate then passed:

```text
D4_MB16 block=mb16_down output_bytes=8192 cycles=280901 pw_mac=786432 dw_mac=73728 dw_seen=512 dw_starts=512 req=4868 resp=4418 last=(15,15,1) overlap=0 scratch=00/00 errors=0
PASS edgembconv_hwacandidate_d4_mb16_controller exact=8192 random_backpressure=checked
```

The `req`/`resp` counts include registered in-bounds source traffic; SAME
halo taps are handled inside the composite scheduler.  The observed
`overlap=0` is intentionally measured serialization, not a theoretical
credit.  The exact preserved console is under
`build/edgembconv_hwacandidate_d4_mb16_controller_sim/console_latest.txt`.

## Fixed transaction hazard

The initial controller exposed two independent issues: a DW group traversal
increment skipped group zero for `x>0`, and the composite RQ boundary accepted
a new pool transaction while forwarding the prior pool result.  The first is
fixed in the controller; the second is fixed by the one-cycle
`!pool_valid_out` acceptance fence in
`rtl/cnn/edgembconv_hwacandidate_d4_composite_datapath.v`.  The resulting
complete score is byte-exact under randomized scratch-read and output
backpressure.  This remains a functional/cycle gate only; no OOC, post-route,
power, or full-network conclusion is drawn.

## Artifacts

- RTL: `rtl/cnn/edgembconv_hwacandidate_d4_mb16_controller.v`
- Composite alignment fix: `rtl/cnn/edgembconv_hwacandidate_d4_composite_datapath.v`
- Testbench/filelist: `sim/tb_edgembconv_hwacandidate_d4_mb16_controller.v`,
  `sim/filelist_edgembconv_hwacandidate_d4_mb16_controller.f`
- Launcher: `scripts/run_edgembconv_hwacandidate_d4_mb16_controller_sim.ps1`
