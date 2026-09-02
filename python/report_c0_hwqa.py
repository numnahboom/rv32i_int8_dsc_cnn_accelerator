#!/usr/bin/env python3
"""Create the auditable C0 full-training and deployment comparison report."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from c10_hwqa_v1 import (
    CLASS_NAMES,
    evaluate_float,
    load_cifar,
    per_class,
    sha256_file,
)
from quantize_export import evaluate_exported_int8_model


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--vectors", type=Path, default=Path("build/c0_hwqa_vectors"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--train-log", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=128)
    args = parser.parse_args()

    test_images, test_labels = load_cifar(args.data_dir, "test")
    fp32_predictions = evaluate_float(args.checkpoint, test_images, test_labels, args.batch_size)
    with np.load(args.export, allow_pickle=True) as exported:
        params = {key: exported[key] for key in exported.files}
    int8_predictions, int8_correct = evaluate_exported_int8_model(
        test_images, test_labels, params, args.batch_size
    )
    fp32_correct = int(np.sum(fp32_predictions == test_labels))
    total = len(test_labels)

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    history = checkpoint["history"]
    optimizer = str(checkpoint.get("optimizer", "unknown"))
    schedule = str(checkpoint.get("schedule", "unknown"))
    augmentation = str(checkpoint.get("augmentation", "unknown"))
    batch_size = int(checkpoint.get("batch_size", 256))
    lr = float(checkpoint.get("lr", float("nan")))
    weight_decay = float(checkpoint.get("weight_decay", float("nan")))
    best = max(history, key=lambda row: (row["val_acc"], -row["epoch"]))
    sample_epochs = {1, 50, 100, 150, 200}
    curve = [row for row in history if row["epoch"] in sample_epochs]
    with args.profile.open("r", encoding="utf-8") as stream:
        profile = json.load(stream)
    with args.manifest.open("r", encoding="utf-8") as stream:
        manifest = json.load(stream)

    fp32_rows = per_class(fp32_predictions, test_labels)
    int8_rows = per_class(int8_predictions, test_labels)
    report: list[str] = [
        "# C10-HWQA-v1 EdgeDSCNet-C10 (C0) Full-Training Evidence",
        "",
        "This is the original EdgeDSCNet-C10 control trained for the complete fixed protocol; it is not the earlier smoke checkpoint.",
        "",
        "## Protocol and artifacts",
        "",
        f"- Dataset manifest: `{args.manifest}` (schema `{manifest['schema']}`)",
        f"- Frozen split: `{manifest['stratified_45k_5k']['train_count']}` train / `{manifest['stratified_45k_5k']['validation_count']}` validation; combined split SHA-256 `{manifest['stratified_45k_5k']['combined_split_sha256']}`",
        "- Input: raw CIFAR uint8 NHWC, centered as `(x - 127.5) / 127.5`.",
        f"- Training configuration recorded in checkpoint: optimizer `{optimizer}`, schedule `{schedule}`, augmentation `{augmentation}`, weight decay `{weight_decay:g}`, initial LR `{lr:g}`, epochs `{checkpoint.get('epochs', len(history))}`, seed `{checkpoint.get('seed', 'unknown')}`, batch `{batch_size}`.",
        f"- Checkpoint: `{args.checkpoint}` (SHA-256 `{sha256_file(args.checkpoint)}`)",
        f"- Training log: `{args.train_log}` (SHA-256 `{sha256_file(args.train_log)}`)",
        f"- INT8 export: `{args.export}` (SHA-256 `{sha256_file(args.export)}`)",
        f"- Semantic profile: `{args.profile}` (SHA-256 `{sha256_file(args.profile)}`)",
        "",
        "## Training curve",
        "",
        f"- Completed epochs: `{len(history)}`; best validation top-1: `{best['val_acc']:.6f}` ({100*best['val_acc']:.2f}%) at epoch `{best['epoch']}`.",
        "",
        "| Epoch | LR | Train loss | Train top-1 | Val loss | Val top-1 |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in curve:
        report.append(
            f"| {row['epoch']} | {row['lr']:.9f} | {row['train_loss']:.6f} | {100*row['train_acc']:.2f}% | {row['val_loss']:.6f} | {100*row['val_acc']:.2f}% |"
        )
    report += [
        "",
        "The validation and official test scores below are freshly evaluated from the saved state dict. The checkpoint metadata score is retained for provenance only.",
        "",
        "## Official CIFAR-10 test10k evaluation",
        "",
        "| Evaluator | Correct | Total | Top-1 |",
        "| --- | ---: | ---: | ---: |",
        f"| FP32 control checkpoint | {fp32_correct} | {total} | {fp32_correct/total:.6f} ({100*fp32_correct/total:.2f}%) |",
        f"| Deployment INT8 integer evaluator | {int8_correct} | {total} | {int8_correct/total:.6f} ({100*int8_correct/total:.2f}%) |",
        f"| FP32 to INT8 drop |  |  | {(fp32_correct-int8_correct)/total*100:.4f} percentage points |",
        "",
        "| ID | Class | Count | FP32 correct | FP32 acc | INT8 correct | INT8 acc |",
        "| ---: | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for fp_row, i8_row in zip(fp32_rows, int8_rows):
        report.append(
            f"| {fp_row['class_id']} | {CLASS_NAMES[fp_row['class_id']]} | {fp_row['count']} | {fp_row['correct']} | {100*fp_row['accuracy']:.2f}% | {i8_row['correct']} | {100*i8_row['accuracy']:.2f}% |"
        )

    report += [
        "",
        "## Semantic compute and storage profile",
        "",
        f"- Convolution MACs: `{profile['conv_mac']:,}`; FC MACs: `{profile['fc_mac']:,}`; total semantic MACs: `{profile['semantic_macs']:,}`.",
        f"- Binary operations at 2 ops/MAC: `{profile['binary_ops']:,}` (the fixed C10-HWQA-v1 accounting quantity).",
        f"- Parameters: `{profile['weight_params']:,}` weights + `{profile['bias_params']:,}` biases = `{profile['trainable_params']:,}` trainable values.",
        f"- Peak int8 activation: `{profile['peak_activation_elements']:,}` elements / `{profile['peak_activation_bytes_int8']:,}` bytes.",
        "",
        "## Reproduction",
        "",
        "```powershell",
        f"python python/train_c0_hwqa.py --data D:\\Stuff\\data --out {args.checkpoint} --epochs {checkpoint.get('epochs', 200)} --batch-size {batch_size} --lr {lr:g} --optimizer {optimizer} --schedule {schedule} --weight-decay {weight_decay:g} --augmentation {augmentation} --seed {checkpoint.get('seed', 20260901)} --device cuda",
        f"python python/quantize_export.py --ckpt {args.checkpoint} --out {args.export.parent} --vectors {args.vectors} --accuracy-samples 10000 --accuracy-batch-size {args.batch_size}",
        f"python python/c10_hwqa_v1.py --data-dir {args.data_dir} --archive D:\\Stuff\\data\\cifar-10-python.tar.gz --checkpoint {args.checkpoint} --export {args.export} --manifest {args.manifest} --report {args.out} --batch-size {args.batch_size}",
        "```",
    ]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(f"fp32_top1={fp32_correct}/{total}={fp32_correct/total:.6f}")
    print(f"int8_top1={int8_correct}/{total}={int8_correct/total:.6f}")
    print(f"best_val={best['val_acc']:.6f}@epoch{best['epoch']}")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
