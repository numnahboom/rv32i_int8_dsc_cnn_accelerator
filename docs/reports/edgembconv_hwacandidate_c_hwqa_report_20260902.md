# EdgeMBConv hardware-aware candidate C — C10-HWQA-v1 result

Candidate C is the independent DW/PW-oriented ablation. C0, A, and B artifacts remain untouched.

## Locked graph and static guard

- C definition: replace both early fused blocks with `MBConv` while retaining the dense 3x3 stem; no Fused-MBConv remains in C.
- Profile guard: **PASS** — 272,570 deployed parameters, 12,730,880 semantic MACs; dense3x3=442,368, PW=11,272,192, DW=1,013,760.
- PW+DW are 96.53% of semantic MACs; the sole dense 3x3 stem is 3.47%. No single fused block exists, so no fused block dominates total work.
- BN is folded before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators and folded biases follow the INT32 contract.

## Accuracy (official CIFAR-10 test10k, final evaluation)

- FP32 top-1: **91.16%** (9116/10000)
- Deployment INT8 top-1: **91.09%** (9109/10000)
- FP32 → INT8 drop: **0.070 percentage points**
- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **PASS**

### Per-class top-1

| Class | FP32 | INT8 |
| --- | ---: | ---: |
| airplane | 92.10% | 92.60% |
| automobile | 95.90% | 96.20% |
| bird | 88.90% | 89.90% |
| cat | 81.50% | 82.10% |
| deer | 92.40% | 91.30% |
| dog | 83.60% | 86.00% |
| frog | 94.20% | 93.10% |
| horse | 93.30% | 93.30% |
| ship | 95.00% | 91.30% |
| truck | 94.70% | 95.10% |

## Training and quantization evidence

- FP32 learning curve: `build/edgembconv_hwacandidate_c/edgembconv_hwacandidate_c_fp32_learning_curve.json`; 200 epochs, best validation 91.68% at epoch 184.
- QAT learning curve: `build/edgembconv_hwacandidate_c/edgembconv_hwacandidate_c_qat_learning_curve.json`; 30 epochs, best validation 91.58% at epoch 2.
- BN-fold equivalence sample: 16 images, max absolute logit difference 8.58307e-06, allclose(atol=2e-5, rtol=1e-5)=True
- QAT fake-quant vs exported integer evaluator argmax agreement: 9791/10000 (97.910%).
- Integer overflow audit: 2844 accumulator checks; maximum absolute accumulator 489,404,107; INT32 limit 2,147,483,647; overflow=False
- Requantization: nearest-away-from-zero followed by INT8 saturation; integer evaluator uses INT64 intermediates only to check the INT32 bound.

## Comparison with A, B, and the retained C0 baseline

C0 remains the formal baseline; its 70.05% result is not an architectural ceiling because its training protocol lacked augmentation, BN, and a scheduler. These are quality/MAC comparisons only; no hardware superiority is claimed.

| Item | C | B | A | C0 anchor |
| --- | ---: | ---: | ---: | ---: |
| FP32 top-1 | 91.16% | 91.51% | 91.48% | 70.05% |
| Deployment INT8 top-1 | 91.09% | 91.36% | 91.30% | 66.16% |
| Semantic MAC | 12,730,880 | 13,312,512 | 17,211,904 | 5,136,896 |
| Parameters | 272,570 | 276,346 | 280,122 | 72,010 |

## Artifact hashes and evidence boundary

- C artifact hashes: `build/edgembconv_hwacandidate_c/edgembconv_hwacandidate_c_artifact_hashes.json`.
- Deployment manifest: `edgembconv_hwacandidate_c_int8.npz` and `edgembconv_hwacandidate_c_deploy_manifest.json`.
- This software evaluation provides no cycle model, RTL equivalence, synthesis, post-route timing, power, or energy evidence; C is not declared a hardware winner until those independent gates are run.
