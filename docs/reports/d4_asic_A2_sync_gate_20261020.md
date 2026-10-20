# D4 A2 sync-reset mapped-gate evidence

The fixed A2 TT 10 ns mapping preserves `hdlin_ff_always_sync_set_reset=1`, matching the A3 sync-reset policy. The real mapped netlist passed a bounded startup probe and four specify-mode full-network cases with the frozen port-level scoreboard. The selected matrix is the same sample/mode matrix used for the A3 backend comparison.

Source identity SHA-256: `b5f28d47848212a0d00b36ed40b61c63ed0f3b8d506ddd33bfa761ab4673fef6`

Mapped netlist SHA-256: `7a42e9c61090181cee0c8212e0cf65f83693f1bdfb1027948b108290dbd5c0bd`

Mapped area including macros: 9,147,690.068825 µm² (pre-route synthesis)

| Sample | Mode | Epoch 0 cycles | Epoch 1 cycles | Stalls (epoch 0 / 1) |
|---|---:|---:|---:|---:|
| `sample_0` | 0 | 255,740 | 255,740 | 0 / 0 |
| `sample_0` | 2 | 257,890 | 257,818 | 104 / 94 |
| `sample_synthetic_checkerboard` | 0 | 255,740 | 255,740 | 0 / 0 |
| `sample_synthetic_checkerboard` | 2 | 257,890 | 257,818 | 104 / 94 |

Each epoch checked 24,336 intermediate words, 10 logits, and 11,645,440 MACs. Both mode-0 epochs completed at 255,740 cycles. Mode 2 completed at 257,890 and 257,818 cycles, with 104 and 94 logit stalls. The startup probe passed at cycle 34 after 16 accepted input beats with known controls.

The simulation used Cadence Xcelium 20.03-s001, the real standard-cell model default specify propagation behavior, and real SRAM/ROM simulation models. It used `-notimingchecks`, no SDF, no `+define+functional`, and the passive memory diagnostic. This is an exact-inference gate only: it establishes no timing-check, STA, routed, power, 14-sample, or board result. The A2 mapped area is pre-route synthesis data. The historical 84-run actual-model RTL baseline remains a separate evidence layer.

The public archive contains five original raw logs (the startup probe and four full-network cases), source identity and run evidence, this report, and the A2 runner/collector/acceptor. It excludes the PDK model, mapped netlist, and SVF. Raw case logs were checked byte-for-byte against hashes computed on the lab host.

See [`artifacts/d4_asic_A2_sync_gate_acceptance_20261020.json`](../../artifacts/d4_asic_A2_sync_gate_acceptance_20261020.json) for the machine-checked package result.
