# C10-HWQA-v1 C0 BN-fold software candidate

This is an independent C0 training candidate. BatchNorm is used only in FP32 training and is algebraically folded into the existing C0 convolution biases/weights before INT8 export. C0 production training, RTL, reports, checkpoints, and output paths are untouched.

## Frozen protocol and artifact boundary

- Protocol manifest: `build\c0_bnfold_hwqa\c0_bnfold_protocol_manifest.json`; official CIFAR-10 45k/5k frozen train/validation split and 10k test.
- BN training checkpoint: `build\c0_bnfold_hwqa\c0_bnfold_fp32.pt` (SHA-256 `9a661274e0f7009f6904d5717b5c9b4655a15efe7bffeaf32ceaf4e04c0a9726`).
- Folded FP32 checkpoint: `build\c0_bnfold_hwqa\c0_bnfold_folded_fp32.pt` (SHA-256 `c1f1d36eeeda63fdd0f7f1faf62316ecfaca08f0b885e58c8d31719dde98be0c`); deployment graph contains no BN.
- INT8 export: `build\c0_bnfold_hwqa\c0_bnfold_export\c0_bnfold_int8.npz` (SHA-256 `fdc93d5960ec4f6d4ff3fe800fff4ab58011fad4517e9544ec383c95cac0a68d`).
- BN fold equivalence record: `build\c0_bnfold_hwqa\c0_bnfold_bn_equivalence.json`.
- Recipe: SGD/Nesterov, initial LR `0.1`, cosine schedule, weight decay `0.0005`, pad4+flip augmentation, `200` epochs, seed `20260901`.

## BN fold correctness

- Probe result: `20` images; max absolute FP32 logit difference `1.4424324035644531e-05`; allclose `True`.
- Fold equation per output channel: `W' = W * gamma / sqrt(var+eps)`, `b' = (b-running_mean) * gamma / sqrt(var+eps) + beta`.

## Training curve

- Completed epochs: `200`; best validation FP32 top-1 `88.94%` at epoch `197`.

| Split | BN-training FP32 | Folded FP32 | INT8 | BN→fold delta | Folded→INT8 drop |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frozen validation 5k | 4434 (88.68%) | 4434 (88.68%) | 3984 (79.68%) | 0.000 pp | 9.000 pp |
| Official test 10k | 8843 (88.43%) | 8843 (88.43%) | 7923 (79.23%) | 0.000 pp | 9.200 pp |

## Official test per-class result

| ID | Class | FP32 correct | FP32 acc | INT8 correct | INT8 acc |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | airplane | 893 | 89.30% | 893 | 89.30% |
| 1 | automobile | 945 | 94.50% | 851 | 85.10% |
| 2 | bird | 861 | 86.10% | 635 | 63.50% |
| 3 | cat | 772 | 77.20% | 868 | 86.80% |
| 4 | deer | 897 | 89.70% | 839 | 83.90% |
| 5 | dog | 829 | 82.90% | 473 | 47.30% |
| 6 | frog | 920 | 92.00% | 884 | 88.40% |
| 7 | horse | 882 | 88.20% | 771 | 77.10% |
| 8 | ship | 927 | 92.70% | 856 | 85.60% |
| 9 | truck | 917 | 91.70% | 853 | 85.30% |

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
- C0 BN-fold candidate official folded FP32 delta: `+18.38 pp`; INT8 delta: `+13.07 pp`.
- Deployment quality gate (INT8 >=90%, FP32→INT8 drop <=0.5 pp): `FAIL`.
- This is software-quality evidence only. It makes no RTL, cycle, timing, power, or energy claim; BN is absent from the deployment primitive graph.

## Reproduction

```powershell
python python/train_c0_bnfold_hwqa.py --data D:\Stuff\data --out build\c0_bnfold_hwqa\c0_bnfold_fp32.pt --epochs 200 --batch-size 256 --lr 0.1 --weight-decay 0.0005 --seed 20260901 --device cuda
python python/c0_bnfold_export.py --checkpoint build\c0_bnfold_hwqa\c0_bnfold_folded_fp32.pt --data D:\Stuff\data
python python/report_c10_hwqa_c0_bnfold.py --data D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz
```
