# C10-HWQA-v1 EdgeDSCNet-C10 (C0) Full-Training Evidence

This is the original EdgeDSCNet-C10 control trained for the complete fixed protocol; it is not the earlier smoke checkpoint.

## Protocol and artifacts

- Dataset manifest: `docs\reports\c10_hwqa_c0_manifest.json` (schema `C10-HWQA-v1`)
- Frozen split: `45000` train / `5000` validation; combined split SHA-256 `5f76a5597b9eb384deadaa8b43f010bbe8917a7f317cd4cdccf4bb80759fedfb`
- Input: raw CIFAR uint8 NHWC, centered as `(x - 127.5) / 127.5`; training augmentation is pad-4 random crop plus horizontal flip.
- Optimizer/schedule: SGD, Nesterov momentum 0.9, weight decay 5e-4, initial LR 0.1, cosine schedule, 200 epochs, seed 20260901, batch 256.
- Checkpoint: `build\model\c0_edgedscnet_hwqa_fp32.pt` (SHA-256 `ea4728cd65fd172dd807ec91e74ec5a9f21ae52f0b251679a559255329d37eae`)
- Training log: `build\c0_edgedscnet_hwqa_train.log` (SHA-256 `b28af0de425a3011826ffddd0be650354bf4e67a394184b1a434c54d7b38174a`)
- INT8 export: `build\c0_hwqa_export\edgedscnet_c10_int8_smoke.npz` (SHA-256 `190a030fc89f38acb109eb1eaf157421819341ef5838cd6ca4be47a62a6c3f27`)
- Semantic profile: `build\c0_hwqa_profile.json` (SHA-256 `e9ff448c226652b20515536d9daff838f87da8272dea56239c6e1ebe30c2171f`)

## Training curve

- Completed epochs: `200`; best validation top-1: `0.100000` (10.00%) at epoch `1`.

| Epoch | LR | Train loss | Train top-1 | Val loss | Val top-1 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.099993832 | 2.304270 | 10.26% | 2.304344 | 10.00% |
| 50 | 0.085355339 | 2.303226 | 10.07% | 2.303230 | 10.00% |
| 100 | 0.050000000 | 2.302996 | 9.97% | 2.303109 | 10.00% |
| 150 | 0.014644661 | 2.302797 | 9.65% | 2.302594 | 10.00% |
| 200 | 0.000000000 | 2.302585 | 10.00% | 2.302585 | 10.00% |

The fixed run is therefore complete, but the C0 graph did not optimize under this recipe: its validation curve remained at chance level. This is a measured control result, not a smoke-training result.

## Official CIFAR-10 test10k evaluation

| Evaluator | Correct | Total | Top-1 |
| --- | ---: | ---: | ---: |
| FP32 control checkpoint | 1000 | 10000 | 0.100000 (10.00%) |
| Deployment INT8 integer evaluator | 1000 | 10000 | 0.100000 (10.00%) |
| FP32 to INT8 drop |  |  | 0.0000 percentage points |

| ID | Class | Count | FP32 correct | FP32 acc | INT8 correct | INT8 acc |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | airplane | 1000 | 0 | 0.00% | 0 | 0.00% |
| 1 | automobile | 1000 | 0 | 0.00% | 1000 | 100.00% |
| 2 | bird | 1000 | 0 | 0.00% | 0 | 0.00% |
| 3 | cat | 1000 | 0 | 0.00% | 0 | 0.00% |
| 4 | deer | 1000 | 0 | 0.00% | 0 | 0.00% |
| 5 | dog | 1000 | 0 | 0.00% | 0 | 0.00% |
| 6 | frog | 1000 | 0 | 0.00% | 0 | 0.00% |
| 7 | horse | 1000 | 0 | 0.00% | 0 | 0.00% |
| 8 | ship | 1000 | 1000 | 100.00% | 0 | 0.00% |
| 9 | truck | 1000 | 0 | 0.00% | 0 | 0.00% |

## Semantic compute and storage profile

- Convolution MACs: `5,134,336`; FC MACs: `2,560`; total semantic MACs: `5,136,896`.
- Binary operations at 2 ops/MAC: `10,273,792` (the fixed C10-HWQA-v1 accounting quantity).
- Parameters: `70,880` weights + `1,130` biases = `72,010` trainable values.
- Peak int8 activation: `32,768` elements / `32,768` bytes.

## Reproduction

```powershell
python python/train_c0_hwqa.py --data D:\Stuff\data --out build\model\c0_edgedscnet_hwqa_fp32.pt --epochs 200 --batch-size 256 --lr 0.1 --seed 20260901 --device cuda
python python/quantize_export.py --ckpt build\model\c0_edgedscnet_hwqa_fp32.pt --out build\c0_hwqa_export --vectors build\c0_hwqa_vectors --accuracy-samples 10000 --accuracy-batch-size 128
python python/c10_hwqa_v1.py --data-dir D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz --checkpoint build\model\c0_edgedscnet_hwqa_fp32.pt --export build\c0_hwqa_export\edgedscnet_c10_int8_smoke.npz --manifest docs\reports\c10_hwqa_c0_manifest.json --report docs\reports\c10_hwqa_c0_full_training_report.md --batch-size 128
```
