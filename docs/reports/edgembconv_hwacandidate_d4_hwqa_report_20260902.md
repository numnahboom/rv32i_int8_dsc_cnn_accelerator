# EdgeMBConv hardware-aware candidate D4 — C10-HWQA-v1 result

D4 is an independent frozen ablation: candidate C with exactly one 4x4 residual MBConv removed (the second block). C0, A, B, and C artifacts remain untouched.

## Frozen graph guard

- Profile guard: **PASS** — params=204,090, semantic MACs=11,645,440; dense3x3=442,368, PW=10,223,616, DW=976,896.
- The removed block is `mb4.2`; D4 retains `mb4.1`. The graph uses only the prescribed dense3x3 stem, PW1x1, DW3x3, residual add, ReLU6, GAP, and FC primitives.
- Dense 3x3 is 3.80% of semantic MACs (3.80% of convolution MACs); PW+DW are 96.18% of semantic MACs. No Fused-MBConv block exists and no single fused block can dominate.
- BN is folded before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators/folded biases follow the INT32 contract.

## Accuracy (official CIFAR-10 test10k, final evaluation)

- FP32 top-1: **91.63%** (9163/10000)
- Deployment INT8 top-1: **91.46%** (9146/10000)
- FP32 → INT8 drop: **0.170 percentage points**
- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **PASS**

### Per-class top-1

| Class | FP32 | INT8 |
| --- | ---: | ---: |
| airplane | 92.60% | 92.50% |
| automobile | 96.70% | 96.40% |
| bird | 89.90% | 89.00% |
| cat | 82.10% | 81.20% |
| deer | 92.30% | 92.40% |
| dog | 85.40% | 86.20% |
| frog | 93.50% | 93.70% |
| horse | 94.30% | 93.90% |
| ship | 94.70% | 94.40% |
| truck | 94.80% | 94.90% |

## Training and quantization evidence

- FP32 learning curve: `build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_fp32_learning_curve.json`; 200 epochs, best validation 91.50% at epoch 197.
- QAT learning curve: `build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_qat_learning_curve.json`; 30 epochs, best validation 91.48% at epoch 29.
- BN-fold equivalence: 16 images, max absolute logit difference 1.19209e-05, allclose=True.
- QAT fake-quant vs exported integer evaluator argmax agreement: 9834/10000 (98.340%).
- Integer overflow audit: 2607 checks; maximum absolute accumulator 43,275,427; INT32 limit 2,147,483,647; overflow=False.
- Requantization: nearest-away-from-zero followed by INT8 saturation; integer reference uses INT64 only to audit the INT32 bound.

## D4 versus candidate C and retained C0

- Removing `mb4.2` lowers D4 by 1,085,440 semantic MACs (-8.53%) and 68,480 deployed parameters (-25.12%).
- C comparison is a quality/MAC anchor only; this D4 software run provides no cycle, RTL, synthesis, post-route timing, power, or energy conclusion.

| Item | D4 | C | C0 anchor |
| --- | ---: | ---: | ---: |
| FP32 top-1 | 91.63% | 91.16% | 70.05% |
| Deployment INT8 top-1 | 91.46% | 91.09% | 66.16% |
| Semantic MAC | 11,645,440 | 12,730,880 | 5,136,896 |
| Parameters | 204,090 | 272,570 | 72,010 |

## Artifact hashes and evidence boundary

- D4 artifact hashes: `build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_artifact_hashes.json`.
- Deployment arrays/manifest: `edgembconv_hwacandidate_d4_int8.npz` and `edgembconv_hwacandidate_d4_deploy_manifest.json`.
- No D4 cycle-model, RTL equivalence, synthesis, post-route, power, or energy claim is made here.
