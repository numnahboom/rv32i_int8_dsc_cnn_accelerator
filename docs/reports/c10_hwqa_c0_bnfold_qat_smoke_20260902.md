# C10-HWQA-v1 C0 BN-fold QAT smoke evidence

This is an independent short functional check for deployment QAT on the
fixed BN-folded C0 graph. It does not replace the completed PTQ report and is
not a final quality result.

## Scope and contract

- Source folded checkpoint: `build/c0_bnfold_hwqa/c0_bnfold_folded_fp32.pt`.
- QAT graph: `python/c0_bnfold_qat_model.py`; BN is absent because it was
  folded before QAT.
- Deployment primitives remain the original C0 stem/DW/PW/ReLU6/GAP/FC graph.
- Quantization contract: signed INT8 activation/weight, per-output-channel
  symmetric weight quantization, INT32 accumulator/bias semantics, and
  nearest-away-from-zero INT8 reference saturation.
- Static graph accounting remains unchanged: 72,010 parameters and 5,136,896
  semantic MACs.

## Two-epoch smoke

The run used the fixed C10-HWQA split, pad4+flip augmentation, batch 256,
seed 20260901, SGD/Nesterov, LR 1e-4, and weight decay 1e-5. The QAT
checkpoint and export remain untracked under `build/c0_bnfold_qat_smoke2/`.

| Evaluator | Samples | Correct | Top-1 |
| --- | ---: | ---: | ---: |
| Fake-QAT model | 256 | 222 | 86.72% |
| Exported INT8 evaluator | 256 | 194 | 75.78% |

- QAT fake-quant versus exported INT8 prediction agreement: 209/256
  (81.64%). This is a short diagnostic, not an equivalence requirement for
  logits because the exporter applies integer Q31 requantization and bias
  rounding.
- INT8 scalar and batch evaluator logits: **equal** on four real test images.
- Export manifest: `build/c0_bnfold_qat_smoke2/c0_bnfold_qat_export/c0_bnfold_qat_export_manifest.json`.

The previously completed BN-fold PTQ result remains the authoritative
full-test negative evidence: folded FP32 88.43%, PTQ INT8 79.23%, and a 9.20
percentage-point drop. Full QAT training is required before judging whether
this drop is recovered.

