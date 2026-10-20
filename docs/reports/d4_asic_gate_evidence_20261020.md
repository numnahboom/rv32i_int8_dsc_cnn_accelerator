# D4 A3 sync-reset mapped-gate evidence

The existing specify-mode run produced **8 exact inferences across 4 cases**, with two epochs per case. Each epoch checked 24,336 intermediate tap words, 10 logits, and 11,645,440 MACs.

| Input | Mode | Epoch 0 cycles | Epoch 1 cycles |
|---|---:|---:|---:|
| `sample_0` | 0 | 255,740 | 255,740 |
| `sample_0` | 2 | 257,890 | 257,818 |
| `sample_synthetic_checkerboard` | 0 | 255,740 | 255,740 |
| `sample_synthetic_checkerboard` | 2 | 257,890 | 257,818 |

The run used the real standard-cell model's default specify propagation behavior and real SRAM/ROM simulation models, with `-notimingchecks` and no SDF. It validates these mapped inference checks; it does not establish a timing gate, STA result, routed timing, power result, board result, or 14-sample gate. The earlier four-case `+define+functional` attempt remains a separate negative result: zero exact inferences, with the first mismatch at op 0, word 990 (`X` versus golden).

The archive contains only these four raw `.log` files, their SHA-256 checked against the server, source/run identity metadata, this report, and the two packaging scripts. The logs remain byte-for-byte original, including remote absolute project paths. The archive excludes console duplicates, PDK model files, the mapped netlist, and SVF. The private mapped netlist is identified by SHA-256 only. See `artifacts/d4_asic_gate_specify_acceptance_20261020.json` for the checked package digest and machine-readable acceptance record.
