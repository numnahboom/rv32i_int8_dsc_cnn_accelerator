# C10-HWQA-v1 C0 BN-fold QAT result

This is an independent QAT experiment on the fixed BN-folded C0 graph. It is
reported separately from the completed PTQ result; it does not modify or
replace C0, the BN-fold checkpoint, or the PTQ report.

## Contract and training

- Source: `build/c0_bnfold_hwqa/c0_bnfold_folded_fp32.pt`.
- QAT checkpoint: `build/c0_bnfold_qat/c0_bnfold_qat.pt` (untracked).
- Training: 30 epochs, fixed C10-HWQA-v1 45k/5k split, pad4+flip, SGD/Nesterov,
  initial LR 1e-4, cosine schedule, weight decay 1e-5, seed 20260901.
- Best validation fake-QAT accuracy: 88.54% at epoch 20.
- BN is absent throughout QAT and deployment; all source BN was folded before
  QAT.

## Official CIFAR-10 test10k

| Evaluator | Correct | Top-1 |
| --- | ---: | ---: |
| Folded FP32 source (prior PTQ report) | 8,843 | 88.43% |
| QAT fake-quant model | 8,770 | 87.70% |
| Exported INT8 evaluator | 7,761 | 77.61% |

- QAT fake-quant → exported INT8 drop: 10.09 percentage points.
- Folded FP32 → exported QAT INT8 drop: 10.82 percentage points.
- Prior folded-PTQ INT8 result: 79.23%; QAT INT8 delta is **-1.62 pp**, so
  this 30-epoch QAT run does not recover the PTQ loss and is a negative
  quality result.
- Fake-QAT versus exported INT8 prediction agreement: 8,004/10,000 (80.04%).
  This is diagnostic only; the exported evaluator is authoritative for
  deployment quality.
- INT8 scalar and batch evaluator logits matched on four real test images.

## Unchanged graph accounting

| Quantity | BN-fold/QAT | Original C0 | Delta |
| --- | ---: | ---: | ---: |
| Parameters | 72,010 | 72,010 | 0 |
| Semantic MACs | 5,136,896 | 5,136,896 | 0 |
| Dense 3x3 MACs | 442,368 | 442,368 | 0 |
| PW 1x1 MACs | 3,317,760 | 3,317,760 | 0 |
| DW 3x3 MACs | 1,803,264 | 1,803,264 | 0 |

The exported bundle contains the original C0 stem/DW/PW/ReLU6/GAP/FC
primitive graph with INT8 activation/weight and INT32 accumulator semantics;
there is no runtime BN. This software result supplies no RTL, cycle, timing,
power, or energy evidence.

## Artifacts

- Learning curve: `build/c0_bnfold_qat/c0_bnfold_qat_learning_curve.json`
- Training log: `build/c0_bnfold_qat/c0_bnfold_qat_training.log`
- Export manifest: `build/c0_bnfold_qat/c0_bnfold_qat_export/c0_bnfold_qat_export_manifest.json`
- Exported parameters: `build/c0_bnfold_qat/c0_bnfold_qat_export/c0_bnfold_qat_int8.npz`

