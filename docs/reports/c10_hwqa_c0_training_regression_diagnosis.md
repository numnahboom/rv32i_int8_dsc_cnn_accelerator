# C0 training regression diagnosis and repaired full-test evidence

## Outcome

The 10.00% C0 result was a training failure, not a model-capacity result. The
old smoke checkpoint still evaluates at `5038/10000 = 50.38%` with both the
legacy and C10-HWQA-v1 FP32 evaluator paths. The repaired clean C0 run evaluates
at `7005/10000 = 70.05%` FP32 and `6616/10000 = 66.16%` with the deployment
INT8 integer evaluator.

## Minimal reproducible diagnosis

The evidence is in `build/c0_training_diagnosis_fixed.json`, produced by
`python/diagnose_c0_training.py`.

| Check | Evidence | Interpretation |
| --- | --- | --- |
| Architecture/state load | Both checkpoints load into the same 28-key C0 state dict; missing/unexpected keys are empty | No key mismatch or wrong model definition |
| Old evaluator vs current evaluator | Old checkpoint: `5038/10000` in both paths; loss differs only by `2e-8` | Input mapping, logits, labels, and `eval()` behavior agree |
| Dataset/split | CIFAR arrays are `50000/10000`, frozen split is `45000/5000` | No truncated or malformed dataset |
| Gradient health | Initial FC mean absolute gradient `5.98e-3`; stem `8.07e-8` | The unnormalized deep ReLU6 stack has a severe early-layer gradient scale imbalance |
| Parameter update/overfit | FC norm changed `1.79568 -> 1.83481`; 64-sample overfit reached `100%`, loss `0.00917` | Backprop, loss, labels, and optimizer updates work |

The old smoke trainer uses Adam with LR `0.001`, no weight decay, no
augmentation, and ten epochs. The failed fair run used SGD/Nesterov LR `0.1`,
weight decay `5e-4`, pad-4 crop/flip augmentation, and cosine decay. Those are
the C10 ResNet recipe settings, but they are not trainable settings for this
normalization-free C0 graph: its first epoch remained at chance and the
checkpoint converged to constant logits. BatchNorm is absent by design and was
not silently added; `model.train()`/`model.eval()` were checked and there are
no running-stat buffers.

## Repair boundary

Only the C0 Python training/diagnostic chain was changed. RTL and C1 files were
not touched. `python/train_c0_hwqa.py` now records schema, optimizer,
schedule, augmentation, weight decay, and fresh test metadata in the
checkpoint. Its default C0-stable recipe is Adam, LR `0.001`, zero weight
decay, no scheduler, no augmentation, while retaining the C10-HWQA-v1 raw
uint8 input mapping, labels, frozen `20260901` stratified split, and batch size
256. The optional ResNet settings remain available for explicit comparison;
they must not be used to interpret the 10% checkpoint as model capability.

## Clean full retraining and official 10k evaluation

The checkpoint was initialized from scratch and trained for 200 epochs. The
training log ended at train `90.39%`, validation `69.06%`, and GPU-side test
metadata `70.03%`. The authoritative CPU evaluator then ran all 10,000 official
CIFAR-10 test samples:

| Evaluator | Correct | Total | Top-1 |
| --- | ---: | ---: | ---: |
| FP32 C0 checkpoint | 7005 | 10000 | 70.05% |
| Deployment INT8 integer evaluator | 6616 | 10000 | 66.16% |
| FP32 -> INT8 |  |  | -3.89 percentage points |

The corresponding full output is
`docs/reports/c10_hwqa_c0_full_training_report_fixed.md`; its manifest and
export are `docs/reports/c10_hwqa_c0_manifest_fixed.json` and
`build/c0_hwqa_export_fixed/edgedscnet_c10_int8_smoke.npz`.

## Reproduction

```powershell
$env:PYTHONPATH = "python"
python python/diagnose_c0_training.py --data D:\Stuff\data --old-checkpoint build\model\edgedscnet_c10_torch_cifar10.npz --new-checkpoint build\model\c0_edgedscnet_hwqa_fp32.pt --out build\c0_training_diagnosis_fixed.json
python python/train_c0_hwqa.py --data D:\Stuff\data --out build\model\c0_edgedscnet_hwqa_fp32.pt --epochs 200 --batch-size 256 --lr 0.001 --optimizer adam --schedule none --weight-decay 0 --augmentation none --seed 20260901 --device cuda
python python/quantize_export.py --ckpt build\model\c0_edgedscnet_hwqa_fp32.pt --out build\c0_hwqa_export_fixed --vectors build\c0_hwqa_vectors_fixed --accuracy-samples 10000 --accuracy-batch-size 128
python python/c10_hwqa_v1.py --data-dir D:\Stuff\data\cifar-10-batches-py --archive D:\Stuff\data\cifar-10-python.tar.gz --checkpoint build\model\c0_edgedscnet_hwqa_fp32.pt --export build\c0_hwqa_export_fixed\edgedscnet_c10_int8_smoke.npz --manifest docs\reports\c10_hwqa_c0_manifest_fixed.json --report docs\reports\c10_hwqa_c0_full_training_report_fixed.md --batch-size 128
```

The 10k evaluator is the acceptance gate; the checkpoint's stored test score
is metadata only. Quantization remains post-training integer export, so the
3.89-point FP32-to-INT8 gap is a separate PTQ limitation rather than the
original chance-level training regression.
