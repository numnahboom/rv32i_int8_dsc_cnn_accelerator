# C10-HWQA-v1 EdgeDSCNet-C10 (C0) Full-Training Evidence

This is the original EdgeDSCNet-C10 control trained from clean initialization
with the C0-stable recipe documented in the regression diagnosis; it is not the
earlier smoke checkpoint. Dataset split, input mapping, and official test
evaluation follow C10-HWQA-v1.

## Protocol and artifacts

- Dataset manifest: `docs\reports\c10_hwqa_c0_manifest_fixed.json` (schema `C10-HWQA-v1`)
- Frozen split: `45000` train / `5000` validation; combined split SHA-256 `5f76a5597b9eb384deadaa8b43f010bbe8917a7f317cd4cdccf4bb80759fedfb`
- Input: raw CIFAR uint8 NHWC, centered as `(x - 127.5) / 127.5`.
- Training configuration recorded in checkpoint: optimizer `adam`, schedule `none`, augmentation `none`, weight decay `0`, initial LR `0.001`, epochs `200`, seed `20260901`, batch `256`.
- Checkpoint: `build\model\c0_edgedscnet_hwqa_fp32.pt` (SHA-256 `d079aa9b25cef815c62bef3fa416d7ed365cd38c1d56fcce71586a2f3845f841`)
- Training log: `build\c0_edgedscnet_hwqa_train_fixed.log` (SHA-256 `0b8bee808ed0033967310d2803b4560b81c12242463bcb93724d56f7cd289650`)
- INT8 export: `build\c0_hwqa_export_fixed\edgedscnet_c10_int8_smoke.npz` (SHA-256 `87847d6c7dfcd7fda5b50297afe7e1794e58810af00f789eea5d61dc79bae216`)
- Semantic profile: `build\c0_hwqa_profile.json` (SHA-256 `e9ff448c226652b20515536d9daff838f87da8272dea56239c6e1ebe30c2171f`)

## Training curve

- Completed epochs: `200`; best validation top-1: `0.711800` (71.18%) at epoch `124`.

| Epoch | LR | Train loss | Train top-1 | Val loss | Val top-1 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.001000000 | 2.303552 | 10.12% | 2.303297 | 10.00% |
| 50 | 0.001000000 | 0.771953 | 72.67% | 0.931840 | 67.66% |
| 100 | 0.001000000 | 0.536814 | 81.02% | 0.893452 | 71.06% |
| 150 | 0.001000000 | 0.392691 | 86.36% | 0.990915 | 70.38% |
| 200 | 0.001000000 | 0.285589 | 90.39% | 1.128022 | 69.06% |

The validation and official test scores below are freshly evaluated from the saved state dict. The checkpoint metadata score is retained for provenance only.

## Official CIFAR-10 test10k evaluation

| Evaluator | Correct | Total | Top-1 |
| --- | ---: | ---: | ---: |
| FP32 control checkpoint | 7005 | 10000 | 0.700500 (70.05%) |
| Deployment INT8 integer evaluator | 6616 | 10000 | 0.661600 (66.16%) |
| FP32 to INT8 drop |  |  | 3.8900 percentage points |

| ID | Class | Count | FP32 correct | FP32 acc | INT8 correct | INT8 acc |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | airplane | 1000 | 759 | 75.90% | 804 | 80.40% |
| 1 | automobile | 1000 | 823 | 82.30% | 776 | 77.60% |
| 2 | bird | 1000 | 606 | 60.60% | 632 | 63.20% |
| 3 | cat | 1000 | 472 | 47.20% | 450 | 45.00% |
| 4 | deer | 1000 | 674 | 67.40% | 619 | 61.90% |
| 5 | dog | 1000 | 621 | 62.10% | 609 | 60.90% |
| 6 | frog | 1000 | 767 | 76.70% | 583 | 58.30% |
| 7 | horse | 1000 | 728 | 72.80% | 685 | 68.50% |
| 8 | ship | 1000 | 769 | 76.90% | 783 | 78.30% |
| 9 | truck | 1000 | 786 | 78.60% | 675 | 67.50% |

## Semantic compute and storage profile

- Convolution MACs: `5,134,336`; FC MACs: `2,560`; total semantic MACs: `5,136,896`.
- Binary operations at 2 ops/MAC: `10,273,792` (the fixed C10-HWQA-v1 accounting quantity).
- Parameters: `70,880` weights + `1,130` biases = `72,010` trainable values.
- Peak int8 activation: `32,768` elements / `32,768` bytes.

## Reproduction

```powershell
python python/train_c0_hwqa.py --data D:\Stuff\data --out build\model\c0_edgedscnet_hwqa_fp32.pt --epochs 200 --batch-size 256 --lr 0.001 --optimizer adam --schedule none --weight-decay 0 --augmentation none --seed 20260901 --device cuda
python python/quantize_export.py --ckpt build\model\c0_edgedscnet_hwqa_fp32.pt --out build\c0_hwqa_export_fixed --vectors build\c0_hwqa_vectors_fixed --accuracy-samples 10000 --accuracy-batch-size 128
python python/c10_hwqa_v1.py --data-dir D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz --checkpoint build\model\c0_edgedscnet_hwqa_fp32.pt --export build\c0_hwqa_export_fixed\edgedscnet_c10_int8_smoke.npz --manifest docs\reports\c10_hwqa_c0_manifest_fixed.json --report docs\reports\c10_hwqa_c0_full_training_report_fixed.md --batch-size 128
```
