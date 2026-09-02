# C10-HWQA-v1 Baseline Evidence

This report is a complete official CIFAR-10 test10k evaluation of the existing control checkpoint and its existing deployment int8 export.

## Frozen inputs

- Manifest: `docs\reports\c10_hwqa_v1_manifest.json`
- Checkpoint: `build\model\edgedscnet_c10_torch_cifar10.npz` (SHA-256 `f3a5b4ad7917c78c67485b20568a31cef829121a39e172f3d3d43fad9ee89476`)
- Export: `build\c10_hwqa_v1_export\edgedscnet_c10_int8_smoke.npz` (SHA-256 `eee5339b0762dda4a614e01812f17c1cd8d060e4a468edf7a44d1167b46c44d0`)
- Test samples evaluated: `10000`
- Checkpoint stored eval_acc metadata: `0.503700`; fresh all-test evaluation below is authoritative for this QA run
- Deploy mapping: `i8 = clip(int16(raw_uint8) - 128, -128, 127)`; signed int8; zero point 128; scale 1/127.5

## Accuracy

| Evaluator | Correct | Total | Top-1 |
| --- | ---: | ---: | ---: |
| FP32 control checkpoint | 5038 | 10000 | 0.503800 (50.38%) |
| Deployment INT8 integer evaluator | 4731 | 10000 | 0.473100 (47.31%) |
| FP32 to INT8 drop |  |  | 3.0700 percentage points |

## Per-class statistics

| ID | Class | Count | FP32 correct | FP32 acc | INT8 correct | INT8 acc |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | airplane | 1000 | 425 | 42.50% | 427 | 42.70% |
| 1 | automobile | 1000 | 691 | 69.10% | 494 | 49.40% |
| 2 | bird | 1000 | 318 | 31.80% | 449 | 44.90% |
| 3 | cat | 1000 | 235 | 23.50% | 210 | 21.00% |
| 4 | deer | 1000 | 484 | 48.40% | 582 | 58.20% |
| 5 | dog | 1000 | 514 | 51.40% | 447 | 44.70% |
| 6 | frog | 1000 | 550 | 55.00% | 490 | 49.00% |
| 7 | horse | 1000 | 588 | 58.80% | 474 | 47.40% |
| 8 | ship | 1000 | 729 | 72.90% | 718 | 71.80% |
| 9 | truck | 1000 | 504 | 50.40% | 440 | 44.00% |

## Reproduction commands

```powershell
python python/quantize_export.py --ckpt build\model\edgedscnet_c10_torch_cifar10.npz --out build/c10_hwqa_v1_export --vectors build/c10_hwqa_v1_vectors --accuracy-samples 10000 --accuracy-batch-size 8
python python/c10_hwqa_v1.py --data-dir D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz --checkpoint build\model\edgedscnet_c10_torch_cifar10.npz --export build\c10_hwqa_v1_export\edgedscnet_c10_int8_smoke.npz --manifest docs\reports\c10_hwqa_v1_manifest.json --report docs\reports\c10_hwqa_v1_baseline.md --batch-size 8
```

The INT8 batch path uses the same deployment quantization equations and integer parameters as `run_exported_int8_model`; a scalar-vs-batch logits check was performed on three test images before the full run.
