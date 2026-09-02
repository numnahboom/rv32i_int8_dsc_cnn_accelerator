# EdgeMBConv hardware-aware candidate B — C10-HWQA-v1 result

Candidate B is an independent ablation artifact. C0 and candidate A paths, checkpoints, RTL, and reports remain untouched.

## Locked graph and static guard

- B definition: replace only A's 32x32 residual fused block with `MBConv(16,32,16)`; retain the 16x16 fused downsample and all later MBConv blocks.
- Profile guard: **PASS** — 276,346 deployed parameters, 13,312,512 semantic MACs; dense3x3=1,622,016, PW=10,747,904, DW=940,032.
- Operator narrative: predominantly DW/PW, but the retained stem and fused downsample remain explicitly accounted for; no claim is made that dense3x3 work maps directly to the DW/PW path.
- BN is folded into convolution weights and biases before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; folded biases and accumulators follow the INT32 hardware contract.

## Accuracy (official CIFAR-10 test10k, final evaluation)

- FP32 top-1: **91.51%** (9151/10000)
- Deployment INT8 top-1: **91.36%** (9136/10000)
- FP32 → INT8 drop: **0.150 percentage points**
- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **PASS**

### Per-class top-1

| Class | FP32 | INT8 |
| --- | ---: | ---: |
| airplane | 91.90% | 92.50% |
| automobile | 96.30% | 95.90% |
| bird | 90.10% | 89.70% |
| cat | 80.20% | 80.60% |
| deer | 92.40% | 92.00% |
| dog | 86.60% | 86.50% |
| frog | 95.50% | 94.20% |
| horse | 92.60% | 92.70% |
| ship | 95.40% | 94.80% |
| truck | 94.10% | 94.70% |

## Training and quantization evidence

- FP32 learning curve: `build/edgembconv_hwacandidate_b/edgembconv_hwacandidate_b_fp32_learning_curve.json`; 200 epochs, best validation 92.06% at epoch 184.
- QAT learning curve: `build/edgembconv_hwacandidate_b/edgembconv_hwacandidate_b_qat_learning_curve.json`; 30 epochs, best validation 91.80% at epoch 17.
- BN-fold equivalence sample: 16 images, max absolute logit difference 1.21593e-05, allclose(atol=2e-5, rtol=1e-5)=True
- QAT fake-quant vs exported integer evaluator argmax agreement: 9792/10000 (97.920%).
- Integer overflow audit: 2765 accumulator checks; maximum absolute accumulator 157,265,325; INT32 limit 2,147,483,647; overflow=False
- Requantization: nearest-away-from-zero followed by INT8 saturation; integer evaluator uses INT64 intermediates only to check the INT32 bound.

## Comparison anchors (not a superiority claim)

C0 remains the formal baseline; its 70.05% result is not treated as an architectural ceiling. Candidate A remains an independent trained reference, and neither anchor is replaced by B.

| Item | Candidate B | Candidate A | C0 anchor |
| --- | ---: | ---: | ---: |
| FP32 top-1 | 91.51% | 91.48% | 70.05% |
| Deployment INT8 top-1 | 91.36% | 91.30% | 66.16% |
| Semantic MAC | 13,312,512 | 17,211,904 | 5,136,896 |
| Parameters | 276,346 | 280,122 | 72,010 |

## Artifact hashes and evidence boundary

- B artifact hashes: `build/edgembconv_hwacandidate_b/edgembconv_hwacandidate_b_artifact_hashes.json`.
- Deployment manifest: `edgembconv_hwacandidate_b_int8.npz` and `edgembconv_hwacandidate_b_deploy_manifest.json`.
- No cycle-model, RTL-equivalence, synthesis, post-route timing, power, or energy evidence is claimed by this software-only B evaluation.
