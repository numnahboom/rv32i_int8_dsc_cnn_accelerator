# EdgeMBConv HW candidate A — C10-HWQA-v1 result

This is an independent candidate artifact. C0 remains untouched and is not replaced by this result.

## Locked graph and arithmetic

- Variant A: current EdgeMBConv-Hybrid; profile guard passed at 280,122 deployed parameters and 17,211,904 semantic MACs.
- BN is folded into convolution weights/biases before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators and folded biases use the INT32 hardware contract.
- Requantization is nearest-away-from-zero followed by INT8 saturation. The Python evaluator uses INT64 only as an overflow-safe reference and checks every accumulator against INT32 bounds.

## Accuracy (official CIFAR-10 test10k, final evaluation only)

- FP32 top-1: **91.48%**
- Deployment INT8 top-1: **91.30%**
- FP32 → INT8 drop: **0.180 percentage points**
- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **PASS**

### Per-class top-1

| Class | FP32 | INT8 |
| --- | ---: | ---: |
| airplane | 92.40% | 92.80% |
| automobile | 95.90% | 96.10% |
| bird | 88.90% | 89.20% |
| cat | 83.20% | 80.30% |
| deer | 92.90% | 92.30% |
| dog | 85.50% | 86.40% |
| frog | 94.30% | 94.70% |
| horse | 91.70% | 91.80% |
| ship | 94.90% | 95.50% |
| truck | 95.10% | 93.90% |

## Comparison anchors

C0 is retained as the formal baseline (reported FP32 70.05%, INT8 66.16%); its training protocol was not an architecture ceiling. C1 ResNet-20 is a quality anchor (reported FP32 91.63%, INT8 91.29%) and not an automatic replacement.

| Item | Candidate A | C0 anchor | C1 anchor |
| --- | ---: | ---: | ---: |
| FP32 top-1 | 91.48% | 70.05% | 91.63% |
| INT8 top-1 | 91.30% | 66.16% | 91.29% |
| Semantic MAC | 17,211,904 | 5,136,896 | 40,813,184 |
| Parameters | 280,122 | 72,010 | 270,896 |

## Export/evaluator evidence

- Accumulator checks: 2686; maximum absolute accumulator: 132,078,475 (INT32 limit 2,147,483,647).
- Deployment manifest: `edgembconv_hwacandidate_a_int8.npz` and `edgembconv_hwacandidate_a_deploy_manifest.json`.
- Artifact hashes are recorded in `build/edgembconv_hwacandidate/edgembconv_hwacandidate_a_artifact_hashes.json`; the manifest hash is recorded separately.

This result establishes software FP32/INT8 quality and integer export evidence only. Cycle-model, RTL equivalence, synthesis, post-route timing, power, and energy remain separate gates.
