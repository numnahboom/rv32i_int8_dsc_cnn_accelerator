# C10-HWQA-v1 C0 BN-fold software candidate

This is an independent C0 training candidate. BatchNorm is used only in FP32 training and is algebraically folded into the existing C0 convolution biases/weights before INT8 export. C0 production training, RTL, reports, checkpoints, and output paths are untouched.

## Frozen protocol and artifact boundary

- Protocol manifest: `build\c0_bnfold_hwqa_smoke\c0_bnfold_protocol_manifest.json`; official CIFAR-10 45k/5k frozen train/validation split and 10k test.
- Training checkpoint: `build\c0_bnfold_hwqa_smoke\c0_bnfold_folded_fp32.pt` (SHA-256 `fd4966f482df00767b32655cc5fa89de5c22b69904c7dbef5cc6928d6f486edf`).
- Folded FP32 checkpoint: `build\c0_bnfold_hwqa_smoke\c0_bnfold_folded_fp32.pt`; deployment graph contains no BN.
- INT8 export: `build\c0_bnfold_hwqa_smoke\c0_bnfold_export\c0_bnfold_int8.npz` (SHA-256 `7bbc23138d502af6a45aac0e5593be6eb9cdd1953f497359f9d19fc4da491ef4`).
- BN fold equivalence record: `build\c0_bnfold_hwqa_smoke\c0_bnfold_bn_equivalence.json`.
- Recipe: SGD/Nesterov, initial LR `0.1`, cosine schedule, weight decay `0.0005`, pad4+flip augmentation, `2` epochs, seed `20260901`.

## BN fold correctness

- Probe result: `20` images; max absolute FP32 logit difference `2.86102294921875e-06`; allclose `True`.
- Fold equation per output channel: `W' = W * gamma / sqrt(var+eps)`, `b' = (b-running_mean) * gamma / sqrt(var+eps) + beta`.

## Training curve

- Completed epochs: `2`; best validation FP32 top-1 `59.32%` at epoch `2`.

| Split | FP32 correct | INT8 correct | FP32 top-1 | INT8 top-1 | FP32→INT8 drop |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frozen validation 5k | 2966 | 2769 | 59.32% | 55.38% | 3.940 pp |
| Official test 10k | 5880 | 5484 | 58.80% | 54.84% | 3.960 pp |

## Official test per-class result

| ID | Class | FP32 correct | FP32 acc | INT8 correct | INT8 acc |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | airplane | 766 | 76.60% | 681 | 68.10% |
| 1 | automobile | 683 | 68.30% | 568 | 56.80% |
| 2 | bird | 511 | 51.10% | 470 | 47.00% |
| 3 | cat | 203 | 20.30% | 210 | 21.00% |
| 4 | deer | 571 | 57.10% | 752 | 75.20% |
| 5 | dog | 664 | 66.40% | 636 | 63.60% |
| 6 | frog | 546 | 54.60% | 437 | 43.70% |
| 7 | horse | 728 | 72.80% | 570 | 57.00% |
| 8 | ship | 529 | 52.90% | 585 | 58.50% |
| 9 | truck | 679 | 67.90% | 575 | 57.50% |

## Unchanged deployment graph accounting

| Quantity | C0 BN-fold | Original C0 | Delta |
| --- | ---: | ---: | ---: |
| Parameters | 72,010 | 72,010 | 0 |
| Semantic MACs | 5,136,896 | 5,136,896 | 0 |
| Dense 3x3 MACs | 442,368 | 442,368 | 0 |
| PW 1x1 MACs | 3,317,760 | 3,317,760 | 0 |
| DW 3x3 MACs | 1,803,264 | 1,803,264 | 0 |

## Relative quality versus retained C0

- Retained C0 official FP32 anchor: `70.05%`; INT8 anchor: `66.16%` (read-only historical report values).
- C0 BN-fold candidate official FP32 delta: `-11.25 pp`; INT8 delta: `-11.32 pp`.
- Deployment quality gate (INT8 >=90%, FP32→INT8 drop <=0.5 pp): `FAIL`.
- This is software-quality evidence only. It makes no RTL, cycle, timing, power, or energy claim; BN is absent from the deployment primitive graph.

## Reproduction

```powershell
python python/train_c0_bnfold_hwqa.py --data D:\Stuff\data --out build\c0_bnfold_hwqa\c0_bnfold_fp32.pt --epochs 2 --batch-size 256 --lr 0.1 --weight-decay 0.0005 --seed 20260901 --device cuda
python python/c0_bnfold_export.py --checkpoint build\c0_bnfold_hwqa_smoke\c0_bnfold_folded_fp32.pt --data D:\Stuff\data
python python/report_c10_hwqa_c0_bnfold.py --data D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz
```
