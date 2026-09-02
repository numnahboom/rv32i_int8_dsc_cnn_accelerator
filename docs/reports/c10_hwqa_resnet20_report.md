# C10-HWQA-v1 ResNet-20 quality anchor

This is the C1 hardware-friendly redesign evaluated against the frozen
`docs/reports/c10_hwqa_v1_manifest.json`.  The official CIFAR-10 Python batches,
the manifest's per-class `default_rng(20260901)` 45,000/5,000 split, and the
unmodified official 10,000-image test set are used.  No test image is used for
training, calibration, or design selection.

## Network contract

The model is CIFAR ResNet-20 (19 dense 3x3 convolutions plus 2 required 1x1
stride/channel projection convolutions and a 64-to-10 FC).  Channel widths are
16/32/64, spatial widths are 32/16/8, and the only operators are dense 3x3,
projection 1x1, ReLU, residual add, GAP, and FC.  BatchNorm is used only in
FP32 training and is folded into convolution weights/biases before QAT export.
There is no attention, SE, dynamic operator, dropout, or test-time augmentation.

## Reproduction

```powershell
python python/resnet20_hwqa.py --data D:\Stuff\data --out build/model/resnet20_hwqa_fp32.pt --epochs 200 --batch-size 256 --lr 0.1 --seed 20260901 --device cuda
python python/qat_resnet20_hwqa.py --data D:\Stuff\data --fp32 build/model/resnet20_hwqa_fp32.pt --out build/model/resnet20_hwqa_qat.pt --epochs 30 --batch-size 256 --lr 0.001 --seed 20260901 --device cuda
python python/export_resnet20_hwqa.py --qat build/model/resnet20_hwqa_qat.pt --fp32 build/model/resnet20_hwqa_fp32.pt --out build/resnet20_hwqa_deploy --data D:\Stuff\data --batch-size 128
python python/profile_resnet20_hwqa.py --out build/resnet20_hwqa_deploy/resnet20_hwqa_profile.json
```

The FP32 stage uses standard pad-4 random crop and horizontal flip, SGD with
momentum 0.9, Nesterov, weight decay 5e-4, and cosine learning rate over 200
epochs.  QAT folds BN, uses per-output-channel symmetric weight fake quant and
per-tensor activation fake quant, and fine-tunes for 30 epochs.  Augmentation
and all RNG seeds are deterministic.

## Quality evidence

The exporter runs the complete integer golden evaluator over all 10,000 test
images.  Current result (`build/resnet20_hwqa_deploy/resnet20_hwqa_test10k.json`):

| evaluator | correct | top-1 |
| --- | ---: | ---: |
| FP32 | 9,163 / 10,000 | 91.63% |
| deployment INT8 | 9,129 / 10,000 | 91.29% |
| FP32 -> INT8 drop |  | 0.34 percentage points |

This satisfies the C1 quality gates of INT8 top-1 >=90.0% and drop <=0.5pp.
The validation peak observed during the fixed 5,000-image design split was
92.40% for FP32 and 92.20% during QAT (the final QAT epoch was 91.80%).

## Deployment numeric contract

Input is `q=clip(raw_uint8-128,-128,127)`, scale `1/127.5`, zero point 0.
Weights are symmetric per-output-channel signed INT8 in [-127,127].  Biases
are INT32 in input-scale times weight-scale units.  Convolution and FC products
are accumulated as INT32 in hardware; the Python reference uses INT64 only to
detect overflow.  Requantization is nearest-away-from-zero
`round(acc*multiplier/2^shift)`, followed by saturation.  ReLU outputs use
[0,127]; residual branch tensors use [-128,127].  Residual adds explicitly
requantize each branch to the block output scale.

## Cost/profile

`build/resnet20_hwqa_deploy/resnet20_hwqa_profile.json` reports 40,813,184
semantic MACs, 270,896 parameters, 172,032 residual additions, and peak INT8
activation storage of 16,384 elements (16 KiB), with no depthwise or dynamic
operator hidden from the count.

## Frozen artifacts

- `build/model/resnet20_hwqa_fp32.pt`: FP32 checkpoint and full learning curve.
- `build/model/resnet20_hwqa_qat.pt`: folded/QAT checkpoint, scales, and full learning curve.
- `build/resnet20_hwqa_deploy/resnet20_hwqa_int8.npz`: INT8 weights, INT32 biases, multipliers, shifts.
- `build/resnet20_hwqa_deploy/resnet20_hwqa_deploy_manifest.json`: frozen RTL-facing manifest.
- `build/resnet20_hwqa_deploy/resnet20_hwqa_profile.json`: semantic cost and peak activation profile.
- `build/resnet20_hwqa_deploy/resnet20_hwqa_test10k.json`: complete official test evidence.

SHA-256 for the current frozen files:

```text
resnet20_hwqa_fp32.pt F2EA988927A1A5B825C436C92E5DD20AE2823784128D5F180618A02E65D69654
resnet20_hwqa_qat.pt 97ECFDD97C5B348C831194DE50E2AC4C342EB9BD05ABD7B2A710C5A99B2F2D26
resnet20_hwqa_int8.npz 7BB9400EB1F923584681C6AD50DF1A3B6B27A2CE1DBB5435428BB11E4D7A55C3
resnet20_hwqa_deploy_manifest.json F506D97B15F76DB6BE03A4D9F77600ECA22EE0F62AA81D46BFFDCF5B633BDF61
resnet20_hwqa_profile.json 43A4B1BF8B7A567D2E4CFA7C17C5A86220D1F130E8BFCC5499EB30620DE5178B
resnet20_hwqa_test10k.json A807143015C4A52915A212A2B4B3FAF7E7F28659BB29E611AAF05C59A265E66D
```

## Boundary

These are quality/software artifacts only.  They do not claim XC7Z020 timing,
cycles, resource, power, or energy closure; those require a separate RTL
integration and full-top post-route run.
