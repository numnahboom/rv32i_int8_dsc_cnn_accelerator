# EdgeMBConv hardware-aware candidate D8 — C10-HWQA-v1 result

D8 is an independent frozen ablation: candidate C with exactly one 8x8 residual MBConv removed (the third block). C0, A, B, C, and D4 artifacts remain untouched.

## Frozen graph guard

- Profile guard: **PASS** — params=254,714, semantic MACs=11,608,576; dense3x3=442,368, PW=10,223,616, DW=940,032.
- D8 removes `mb8.3` and retains `mb8.1`/`mb8.2`; the graph uses only dense3x3 stem, PW1x1, DW3x3, residual add, ReLU6, GAP, and FC primitives.
- Dense 3x3 is 3.81% of semantic MACs (3.81% of convolution MACs); PW+DW are 96.17% of semantic MACs. No Fused-MBConv block exists and no single fused block can dominate.
- BN is folded before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators/folded biases follow the INT32 contract.

## Accuracy (official CIFAR-10 test10k, final evaluation)

- FP32 top-1: **91.37%** (9137/10000)
- Deployment INT8 top-1: **91.17%** (9117/10000)
- FP32 → INT8 drop: **0.200 percentage points**
- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **PASS**

### Per-class top-1

| Class | FP32 | INT8 |
| --- | ---: | ---: |
| airplane | 93.20% | 93.30% |
| automobile | 95.60% | 96.10% |
| bird | 88.10% | 86.60% |
| cat | 82.40% | 81.60% |
| deer | 92.50% | 91.30% |
| dog | 85.10% | 85.10% |
| frog | 93.50% | 94.00% |
| horse | 93.00% | 93.10% |
| ship | 95.20% | 96.30% |
| truck | 95.10% | 94.30% |

## Training and quantization evidence

- FP32 learning curve: `build/edgembconv_hwacandidate_d8/edgembconv_hwacandidate_d8_fp32_learning_curve.json`; 200 epochs, best validation 92.56% at epoch 182.
- QAT learning curve: `build/edgembconv_hwacandidate_d8/edgembconv_hwacandidate_d8_qat_learning_curve.json`; 30 epochs, best validation 92.36% at epoch 1.
- BN-fold equivalence: 16 images, max absolute logit difference 1.33514e-05, allclose=True.
- QAT fake-quant vs exported integer evaluator argmax agreement: 9821/10000 (98.210%).
- Integer overflow audit: 2607 checks; maximum absolute accumulator 203,461,965; INT32 limit 2,147,483,647; overflow=False.
- Requantization: nearest-away-from-zero followed by INT8 saturation; integer reference uses INT64 only to audit the INT32 bound.

## D8 versus candidate C, D4, and retained C0

- Removing `mb8.3` lowers D8 by 1,122,304 semantic MACs (-8.82%) and 17,856 deployed parameters (-6.55%).
- D4 is referenced only as a quality/static-ledger comparison; no D8 cycle, synthesis, post-route, power, or energy claim is made.

| Item | D8 | C | D4 | C0 anchor |
| --- | ---: | ---: | ---: | ---: |
| FP32 top-1 | 91.37% | 91.16% | 91.63% | 70.05% |
| Deployment INT8 top-1 | 91.17% | 91.09% | 91.46% | 66.16% |
| Semantic MAC | 11,608,576 | 12,730,880 | 11,645,440 | 5,136,896 |
| Parameters | 254,714 | 272,570 | 204,090 | 72,010 |

## Artifact hashes and evidence boundary

- D8 artifact hashes: `build/edgembconv_hwacandidate_d8/edgembconv_hwacandidate_d8_artifact_hashes.json`.
- Deployment arrays/manifest: `edgembconv_hwacandidate_d8_int8.npz` and `edgembconv_hwacandidate_d8_deploy_manifest.json`.
- No D8 cycle-model, RTL equivalence, synthesis, post-route, power, or energy claim is made here.
