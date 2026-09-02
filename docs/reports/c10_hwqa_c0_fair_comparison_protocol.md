# C0 fair-comparison protocol (prepared, not executed in the C1 GPU run)

`python/train_c0_hwqa.py` preserves the original EdgeDSCNet-C10 control
operator graph and uses the exact C10-HWQA-v1 45k/5k stratified split, raw
uint8-to-centered input mapping, labels, and seed `20260901`. The C0 graph has
no normalization layers; the C10 ResNet optimizer/augmentation recipe leaves
this stack at chance, so C0 uses its measured stable recipe (Adam, LR 1e-3,
zero weight decay, no augmentation, no scheduler). This is a documented
architecture-specific training exception, not a change to the fixed 10k test
protocol or a comparison against C1's full training using the old smoke
checkpoint.

```powershell
python python/train_c0_hwqa.py --data D:\Stuff\data --out build/model/c0_edgedscnet_hwqa_fp32.pt --epochs 200 --batch-size 256 --lr 0.001 --optimizer adam --schedule none --weight-decay 0 --augmentation none --seed 20260901 --device cuda
python python/quantize_export.py --ckpt build/model/c0_edgedscnet_hwqa_fp32.pt --out build/c0_hwqa_export --vectors build/c0_hwqa_vectors --accuracy-samples 10000 --accuracy-batch-size 128
```

The existing C0 exporter is the control PTQ/integer evaluator.  A C0-specific
QAT/export pass should be run by a separate worker if it is needed for the
final architecture comparison: C1's 200-epoch FP32 plus 30-epoch QAT used the
available RTX 4060 continuously, and launching C0 concurrently would create
GPU memory/time contention.  The C1 quality result and artifacts are frozen
independently; C0 must not change the quality threshold or the official test
protocol.
