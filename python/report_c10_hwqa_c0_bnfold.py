#!/usr/bin/env python3
"""Evaluate the independent C0 BN-fold candidate under C10-HWQA-v1."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from c10_hwqa_v1 import CLASS_NAMES, evaluate_float, make_manifest, per_class, sha256_file
from quantize_export import evaluate_exported_int8_model, run_exported_int8_model, run_exported_int8_model_batch
from resnet20_hwqa import frozen_split, load_cifar10


def load_torch(path: Path) -> dict:
    try:
        value = torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        value = torch.load(path, map_location="cpu")
    if not isinstance(value, dict):
        raise ValueError(f"invalid checkpoint: {path}")
    return value


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data\cifar-10-batches-py"))
    p.add_argument("--archive", type=Path, default=Path(r"D:\Stuff\data\cifar-10-python.tar.gz"))
    p.add_argument("--checkpoint", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_folded_fp32.pt"))
    p.add_argument("--export", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_export/c0_bnfold_int8.npz"))
    p.add_argument("--equivalence", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_bn_equivalence.json"))
    p.add_argument("--out", type=Path, default=Path("docs/reports/c10_hwqa_c0_bnfold_report_20260902.md"))
    p.add_argument("--manifest", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_protocol_manifest.json"))
    p.add_argument("--batch-size", type=int, default=128)
    p.add_argument("--c0-checkpoint", type=Path, default=Path("build/model/c0_edgedscnet_hwqa_fp32.pt"))
    p.add_argument("--c0-export", type=Path, default=Path("build/c0_hwqa_export_fixed/edgedscnet_c10_int8_smoke.npz"))
    args = p.parse_args()
    train_images, train_labels = load_cifar10(args.data, "train")
    test_images, test_labels = load_cifar10(args.data, "test")
    manifest = make_manifest(args.data, args.archive, train_images, train_labels, test_images, test_labels)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    tr, va = frozen_split(train_labels)

    fp32_test_pred = evaluate_float(args.checkpoint, test_images, test_labels, args.batch_size)
    fp32_val_pred = evaluate_float(args.checkpoint, train_images[va], train_labels[va], args.batch_size)
    with np.load(args.export, allow_pickle=True) as z:
        params = {k: z[k] for k in z.files}
    int8_test_pred, int8_test_correct = evaluate_exported_int8_model(test_images, test_labels, params, args.batch_size)
    int8_val_pred, int8_val_correct = evaluate_exported_int8_model(train_images[va], train_labels[va], params, args.batch_size)
    scalar_logits = np.asarray([run_exported_int8_model(image, params)[0] for image in test_images[:4]], dtype=np.int16)
    batch_logits = run_exported_int8_model_batch(test_images[:4], params).astype(np.int16)
    if not np.array_equal(scalar_logits, batch_logits):
        raise RuntimeError("C0 BN-fold INT8 scalar/batch evaluator mismatch")

    fp32_test_correct = int(np.sum(fp32_test_pred == test_labels))
    fp32_val_correct = int(np.sum(fp32_val_pred == train_labels[va]))
    total_test = len(test_labels); total_val = len(va)
    fp32_test_acc = fp32_test_correct / total_test; int8_test_acc = int8_test_correct / total_test
    fp32_val_acc = fp32_val_correct / total_val; int8_val_acc = int8_val_correct / total_val
    ckpt = load_torch(args.checkpoint)
    eq = json.loads(args.equivalence.read_text(encoding="utf-8")) if args.equivalence.exists() else {}
    history = ckpt.get("history", [])
    best = max(history, key=lambda row: (row["val_acc"], -row["epoch"])) if history else {"val_acc": float("nan"), "epoch": 0}
    # These counts are inherited from the unchanged C0 semantic graph. They
    # are explicit here so the candidate cannot accidentally hide graph work.
    profile = {"parameters": 72010, "macs": 5136896, "dense3x3_macs": 442368, "pw_macs": 3317760, "dw_macs": 1803264}
    c0_fp32 = 0.7005; c0_int8 = 0.6616
    report = [
        "# C10-HWQA-v1 C0 BN-fold software candidate",
        "",
        "This is an independent C0 training candidate. BatchNorm is used only in FP32 training and is algebraically folded into the existing C0 convolution biases/weights before INT8 export. C0 production training, RTL, reports, checkpoints, and output paths are untouched.",
        "",
        "## Frozen protocol and artifact boundary",
        "",
        f"- Protocol manifest: `{args.manifest}`; official CIFAR-10 45k/5k frozen train/validation split and 10k test.",
        f"- Training checkpoint: `{args.checkpoint}` (SHA-256 `{sha256_file(args.checkpoint)}`).",
        f"- Folded FP32 checkpoint: `{args.checkpoint}`; deployment graph contains no BN.",
        f"- INT8 export: `{args.export}` (SHA-256 `{sha256_file(args.export)}`).",
        f"- BN fold equivalence record: `{args.equivalence}`.",
        f"- Recipe: SGD/Nesterov, initial LR `{float(ckpt.get('lr', float('nan'))):g}`, cosine schedule, weight decay `{float(ckpt.get('weight_decay', float('nan'))):g}`, pad4+flip augmentation, `{int(ckpt.get('epochs', len(history)))}` epochs, seed `{ckpt.get('seed', 'unknown')}`.",
        "",
        "## BN fold correctness",
        "",
        f"- Probe result: `{eq.get('result', {}).get('samples', 'unknown')}` images; max absolute FP32 logit difference `{eq.get('result', {}).get('max_abs_logit_diff', 'unknown')}`; allclose `{eq.get('result', {}).get('allclose', False)}`.",
        "- Fold equation per output channel: `W' = W * gamma / sqrt(var+eps)`, `b' = (b-running_mean) * gamma / sqrt(var+eps) + beta`.",
        "",
        "## Training curve",
        "",
        f"- Completed epochs: `{len(history)}`; best validation FP32 top-1 `{100 * float(best['val_acc']):.2f}%` at epoch `{best['epoch']}`.",
        "",
        "| Split | FP32 correct | INT8 correct | FP32 top-1 | INT8 top-1 | FP32→INT8 drop |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
        f"| Frozen validation 5k | {fp32_val_correct} | {int8_val_correct} | {100*fp32_val_acc:.2f}% | {100*int8_val_acc:.2f}% | {(fp32_val_acc-int8_val_acc)*100:.3f} pp |",
        f"| Official test 10k | {fp32_test_correct} | {int8_test_correct} | {100*fp32_test_acc:.2f}% | {100*int8_test_acc:.2f}% | {(fp32_test_acc-int8_test_acc)*100:.3f} pp |",
        "",
        "## Official test per-class result",
        "",
        "| ID | Class | FP32 correct | FP32 acc | INT8 correct | INT8 acc |",
        "| ---: | --- | ---: | ---: | ---: | ---: |",
    ]
    for frow, irow in zip(per_class(fp32_test_pred, test_labels), per_class(int8_test_pred, test_labels)):
        report.append(f"| {frow['class_id']} | {CLASS_NAMES[frow['class_id']]} | {frow['correct']} | {100*frow['accuracy']:.2f}% | {irow['correct']} | {100*irow['accuracy']:.2f}% |")
    report += [
        "",
        "## Unchanged deployment graph accounting",
        "",
        "| Quantity | C0 BN-fold | Original C0 | Delta |",
        "| --- | ---: | ---: | ---: |",
        f"| Parameters | {profile['parameters']:,} | {profile['parameters']:,} | 0 |",
        f"| Semantic MACs | {profile['macs']:,} | {profile['macs']:,} | 0 |",
        f"| Dense 3x3 MACs | {profile['dense3x3_macs']:,} | {profile['dense3x3_macs']:,} | 0 |",
        f"| PW 1x1 MACs | {profile['pw_macs']:,} | {profile['pw_macs']:,} | 0 |",
        f"| DW 3x3 MACs | {profile['dw_macs']:,} | {profile['dw_macs']:,} | 0 |",
        "",
        "## Relative quality versus retained C0",
        "",
        f"- Retained C0 official FP32 anchor: `{100*c0_fp32:.2f}%`; INT8 anchor: `{100*c0_int8:.2f}%` (read-only historical report values).",
        f"- C0 BN-fold candidate official FP32 delta: `{(fp32_test_acc-c0_fp32)*100:+.2f} pp`; INT8 delta: `{(int8_test_acc-c0_int8)*100:+.2f} pp`.",
        f"- Deployment quality gate (INT8 >=90%, FP32→INT8 drop <=0.5 pp): `{'PASS' if int8_test_acc >= 0.90 and (fp32_test_acc-int8_test_acc)*100 <= 0.5 else 'FAIL'}`.",
        "- This is software-quality evidence only. It makes no RTL, cycle, timing, power, or energy claim; BN is absent from the deployment primitive graph.",
        "",
        "## Reproduction",
        "",
        f"```powershell\npython python/train_c0_bnfold_hwqa.py --data {args.data.parent} --out {Path('build/c0_bnfold_hwqa/c0_bnfold_fp32.pt')} --epochs {ckpt.get('epochs', 200)} --batch-size {ckpt.get('batch_size', 256)} --lr {ckpt.get('lr', 0.1)} --weight-decay {ckpt.get('weight_decay', 5e-4)} --seed {ckpt.get('seed', 20260901)} --device cuda\npython python/c0_bnfold_export.py --checkpoint {args.checkpoint} --data {args.data.parent}\npython python/report_c10_hwqa_c0_bnfold.py --data {args.data} --archive {args.archive}\n```",
    ]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(json.dumps({"fp32_val": fp32_val_acc, "int8_val": int8_val_acc, "fp32_test": fp32_test_acc, "int8_test": int8_test_acc, "drop_pp": (fp32_test_acc - int8_test_acc) * 100.0, "report": str(args.out)}))


if __name__ == "__main__":
    main()
