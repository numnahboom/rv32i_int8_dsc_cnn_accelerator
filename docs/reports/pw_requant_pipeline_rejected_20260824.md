# Rejected PW requant pipeline experiment (2026-08-24)

## Candidate

The candidate temporarily replaced `u_pw_requant` in
`rtl/cnn/ds_block_tile_engine_new.v` with the existing fixed-latency
`requant_activation_pipeline`, forced `rq_ready_in=1`, and extended the output
tag/drain pipeline to ten entries.  The intended latency increase was seven
cycles per full 8x8 PW tile without changing PW issue cadence.

The candidate was reverted after the routed timing gate failed.  The RTL file
is identical to `HEAD` after the experiment.

## Verification

- `tb_requant_activation_pipeline`: 100/100 PASS.
- `tb_ds_block_tile_engine_new`: 7 cases, 2191 checks PASS.
- DSBlock measured deltas versus the pre-candidate logs were +56, +28, 0,
  +3, 0, +10, and 0 cycles for cases 0..6 respectively; `pw_issue` counts
  were unchanged (64, 64, 256, 2, 14, 68, 4064).
- Fresh non-resume Verilator selected failures matched an isolated `383847a`
  worktree exactly: the same nine tests and the same mismatch signatures.
- Fresh XSim full-16 baseline in the isolated worktree also reproduced the
  same six pre-existing failures; no candidate-specific XSim failure was
  observed.

## Routed OOC gate

Command used:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/vivado_cnn_top_impl.tcl -tclargs cnn_top xc7z020clg400-1
```

Fresh Vivado 2025.2 `RuntimeOptimized`, routed OOC result:

| Metric | Candidate | Baseline | Gate |
|---|---:|---:|---:|
| WNS (ns) | -7.788 | -7.768 | gain >= 0.25 |
| WHS (ns) | +0.016 | +0.058 | hold clean |
| TNS | negative path present | -28665.969 | gain >= 500 |

Resource snapshot from the routed reports was DSP 50 (baseline 56), Slice
LUT 29976 (baseline 29974), and Slice Registers 20059 (baseline 19052).
Thus the resource limits were met, but timing was not.

The candidate lost 0.020 ns WNS and did not satisfy the required timing or
hold/resource acceptance gates.  It was therefore rejected and reverted.

Evidence: `build/reports/vivado_cnn_top_impl/runs/20260824T125803485-27428/manifest.txt`.

## Option 2: registered accumulator+bias pre-add (rejected)

The existing elastic `requant_activation_unit` was temporarily changed to
register `acc+bias` before the multiplier, with matching four-deep valid/tag
plumbing in `ds_block_tile_engine_new`.  The candidate preserved the existing
single-lane issue protocol and held all operands under backpressure.  It was
reverted after the direct timing gate; both RTL files are identical to `HEAD`.

Verification passed before rejection:

- `tb_requant_activation_unit`: 100/100.
- `tb_requant_activation_pipeline`: 100/100.
- `tb_requant_activation_core`: 7/7.
- `tb_ds_block_tile_engine_new`: 7 cases, 2191 checks; measured PW issue
  counts were unchanged.

Fresh Vivado 2025.2 `RuntimeOptimized` routed OOC (`xc7z020clg400-1`) gave:

| Metric | Candidate | Baseline | Delta |
|---|---:|---:|---:|
| WNS (ns) | -7.989 | -7.768 | -0.221 |
| TNS (ns) | -30883.736 | -28665.969 | -2217.767 |
| WHS (ns) | +0.016 | +0.058 | -0.042 |

The candidate fails the required WNS/TNS improvement gate and is not kept.
Next strategy should avoid adding a full elastic stage; investigate localized
DSP/LUTRAM boundary or multiplier operand registration while preserving the
current three-stage protocol and tag depth.

Evidence: `build/reports/vivado_cnn_top_impl_pw_preadd_20260824/manifest.txt`.
