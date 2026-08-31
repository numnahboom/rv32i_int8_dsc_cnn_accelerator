# Tagged output-buffer store prefetch (2026-08-27)

## Change

`cnn_layer_runner` now issues output-buffer scalar/vector4 reads through a
registered one-cycle command (`store_rd_valid_reg`, `store_rd_word_reg`, and
`store_rd_addr_reg`).  New read-wait states consume only the corresponding
`cnn_out_buffer.rd_valid` response before writing.  This keeps the existing
wide byte layout, aligned vector4 fast path, scalar misaligned/tail fallback,
single outstanding external request, and stable backpressure payload.  The
old store-index lookahead enable/address cone is no longer connected to the
output-buffer BRAM read enable.

## Functional evidence

The dedicated output-buffer semantic test passed:

```text
powershell -ExecutionPolicy Bypass -File scripts/run_cnn_xsim.ps1 -VivadoBin D:\Software\vivado2025.2\2025.2\Vivado\bin -Tests tb_cnn_out_buffer_store_tag
PASS tb_cnn_out_buffer_store_tag checks=12
```

Runner/top directed XSim tests also passed: SRAM Stem/DS (576 checks), tiled
Stem (16,384), tiled DS (2,256), SRAM tiled DS (480), backpressure (768),
ops (1,290), multilayer (1,866), GAP/FC (10), and tail (10).  Fullnet passed
10/10 exact logits with 1,203,503 hardware cycles, 78,890 reads, 10 writes,
96,272 SRAM reads, and 38,144 SRAM writes.  The generic report helper's
1,000,000-cycle budget is exceeded; this is a material throughput regression
from the prior 949,792-cycle run.

## 8 ns runner OOC

Vivado 2025.2, `xc7z020clg400-1`, RuntimeOptimized, post-route:

```text
vivado.bat -mode batch -notrace -source scripts/vivado_cnn_layer_runner_stride_capture_20260827.tcl
```

Run output: `build/reports/vivado_cnn_layer_runner_store_tag_20260827/`.
The route has zero unrouted nets.  WNS/TNS are `-6.547/-41146.863 ns` for
the full runner OOC, with 32,856 LUT, 34,357 FF, 32 BRAM, and 69 DSP.

The DCP audit command is:

```text
vivado.bat -mode batch -notrace -source scripts/audit_cnn_layer_runner_store_tag_20260827.tcl
```

It reports `store_idx_to_enbwren=0`.  The replacement registered-valid path
has 20 matching paths and worst slack `+3.095 ns` at 8 ns (4.378 ns data,
two LUT levels).  Thus the requested direct C path is eliminated, but this
runner OOC is not a full-top timing-closure result.

`git diff --check` passed.
