#!/usr/bin/env python3
"""C10-HWQA-v1 frozen data manifest and checkpoint/export evaluation."""

from __future__ import annotations

import argparse
import hashlib
import json
import pickle
import warnings
from pathlib import Path

import numpy as np


CLASS_NAMES = [
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck",
]
SPLIT_SEED = 20260901


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_cifar_batch(path: Path) -> tuple[np.ndarray, np.ndarray]:
    with path.open("rb") as stream:
        batch = pickle.load(stream, encoding="latin1")
    images = np.asarray(batch["data"], dtype=np.uint8).reshape(-1, 3, 32, 32).transpose(0, 2, 3, 1)
    return images, np.asarray(batch["labels"], dtype=np.int64)


def load_cifar(data_dir: Path, split: str) -> tuple[np.ndarray, np.ndarray]:
    names = [f"data_batch_{i}" for i in range(1, 6)] if split == "train" else ["test_batch"]
    image_parts, label_parts = zip(*(load_cifar_batch(data_dir / name) for name in names))
    return np.concatenate(image_parts), np.concatenate(label_parts)


def stratified_split_hash(labels: np.ndarray) -> dict[str, object]:
    labels = np.asarray(labels, dtype=np.int64)
    rng = np.random.default_rng(SPLIT_SEED)
    train_parts = []
    val_parts = []
    for class_id in range(10):
        indices = np.flatnonzero(labels == class_id)
        if len(indices) != 5000:
            raise ValueError(f"expected 5000 samples for class {class_id}, got {len(indices)}")
        shuffled = indices[rng.permutation(len(indices))]
        train_parts.append(shuffled[:4500])
        val_parts.append(shuffled[4500:])
    train_indices = np.concatenate(train_parts).astype("<i8", copy=False)
    val_indices = np.concatenate(val_parts).astype("<i8", copy=False)
    encoded = train_indices.tobytes() + val_indices.tobytes()
    return {
        "algorithm": "default_rng(20260901), per-class permutation; first 4500 train, last 500 validation",
        "seed": SPLIT_SEED,
        "train_count": int(train_indices.size),
        "validation_count": int(val_indices.size),
        "train_index_sha256": hashlib.sha256(train_indices.tobytes()).hexdigest(),
        "validation_index_sha256": hashlib.sha256(val_indices.tobytes()).hexdigest(),
        "combined_split_sha256": hashlib.sha256(encoded).hexdigest(),
        "class_counts_train": [int(np.sum(labels[train_indices] == c)) for c in range(10)],
        "class_counts_validation": [int(np.sum(labels[val_indices] == c)) for c in range(10)],
    }


def make_manifest(data_dir: Path, archive: Path, train_images: np.ndarray, train_labels: np.ndarray, test_images: np.ndarray, test_labels: np.ndarray) -> dict[str, object]:
    test_file = data_dir / "test_batch"
    train_files = [data_dir / f"data_batch_{i}" for i in range(1, 6)]
    if not archive.exists() or not test_file.exists():
        raise FileNotFoundError(f"missing archive or test batch: archive={archive} test_batch={test_file}")
    canonical_test = test_images.tobytes(order="C") + test_labels.astype("<i8", copy=False).tobytes()
    canonical_train = train_images.tobytes(order="C") + train_labels.astype("<i8", copy=False).tobytes()
    return {
        "schema": "C10-HWQA-v1",
        "dataset": "CIFAR-10 python batches, official 50,000 train / 10,000 test",
        "data_dir": str(data_dir),
        "archive": {"path": str(archive), "sha256": sha256_file(archive), "size_bytes": archive.stat().st_size},
        "batch_sha256": {path.name: sha256_file(path) for path in [*train_files, test_file]},
        "decoded_arrays": {
            "train_shape": list(train_images.shape),
            "test_shape": list(test_images.shape),
            "train_canonical_sha256": hashlib.sha256(canonical_train).hexdigest(),
            "test_canonical_sha256": hashlib.sha256(canonical_test).hexdigest(),
        },
        "stratified_45k_5k": stratified_split_hash(train_labels),
        "deploy_preprocessing": {
            "input": "raw CIFAR uint8 NHWC, each channel x in [0,255]",
            "mapping": "i8 = clip(int16(x) - 128, -128, 127), cast signed int8",
            "zero_point": 128,
            "scale": "1/127.5",
            "examples": {"0": -128, "1": -127, "127": -1, "128": 0, "255": 127},
        },
    }


def make_model(checkpoint: dict[str, object]):
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    class DSBlock(nn.Module):
        def __init__(self, cin: int, cout: int, stride: int) -> None:
            super().__init__()
            self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=True)
            self.pw = nn.Conv2d(cin, cout, 1, bias=True)

        def forward(self, x):
            return F.relu6(self.pw(F.relu6(self.dw(x))))

    class EdgeDSCNetC10(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
            self.blocks = nn.Sequential(
                DSBlock(16, 32, 1), DSBlock(32, 64, 2), DSBlock(64, 64, 1),
                DSBlock(64, 128, 2), DSBlock(128, 128, 1), DSBlock(128, 256, 2),
            )
            self.fc = nn.Linear(256, 10)

        def forward(self, x):
            x = F.relu6(self.stem(x))
            x = self.blocks(x)
            return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))

    model = EdgeDSCNetC10()
    model.load_state_dict(checkpoint["model_state"])
    model.eval()
    return model


def evaluate_float(checkpoint_path: Path, images: np.ndarray, labels: np.ndarray, batch_size: int) -> np.ndarray:
    import torch

    try:
        checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    except TypeError:
        checkpoint = torch.load(checkpoint_path, map_location="cpu")
    model = make_model(checkpoint)
    predictions = np.empty(labels.shape[0], dtype=np.int64)
    with torch.inference_mode():
        for start in range(0, labels.shape[0], max(1, batch_size)):
            stop = min(start + max(1, batch_size), labels.shape[0])
            x = torch.from_numpy(images[start:stop].transpose(0, 3, 1, 2)).float() / 255.0
            x = (x - 0.5) / 0.5
            predictions[start:stop] = torch.argmax(model(x), dim=1).numpy()
    return predictions


def per_class(predictions: np.ndarray, labels: np.ndarray) -> list[dict[str, object]]:
    return [
        {
            "class_id": c,
            "class_name": CLASS_NAMES[c],
            "count": int(np.sum(labels == c)),
            "correct": int(np.sum((labels == c) & (predictions == labels))),
            "accuracy": float(np.mean(predictions[labels == c] == c)),
        }
        for c in range(10)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=256)
    args = parser.parse_args()

    train_images, train_labels = load_cifar(args.data_dir, "train")
    test_images, test_labels = load_cifar(args.data_dir, "test")
    manifest = make_manifest(args.data_dir, args.archive, train_images, train_labels, test_images, test_labels)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    float_predictions = evaluate_float(args.checkpoint, test_images, test_labels, args.batch_size)
    import torch
    try:
        checkpoint_metadata = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    except TypeError:
        checkpoint_metadata = torch.load(args.checkpoint, map_location="cpu")
    with np.load(args.export, allow_pickle=True) as exported:
        params = {key: exported[key] for key in exported.files}
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from quantize_export import evaluate_exported_int8_model, run_exported_int8_model, run_exported_int8_model_batch
    check_count = min(3, len(test_labels))
    scalar_logits = np.asarray([run_exported_int8_model(test_images[i], params)[0] for i in range(check_count)], dtype=np.int16)
    batch_logits = run_exported_int8_model_batch(test_images[:check_count], params).astype(np.int16)
    if not np.array_equal(scalar_logits, batch_logits):
        raise RuntimeError("INT8 scalar and batch evaluator logits differ")
    int8_predictions, int8_correct = evaluate_exported_int8_model(test_images, test_labels, params, args.batch_size)

    float_correct = int(np.sum(float_predictions == test_labels))
    float_acc = float(float_correct / len(test_labels))
    int8_acc = float(int8_correct / len(test_labels))
    report_lines = [
        "# C10-HWQA-v1 Baseline Evidence",
        "",
        "This report is a complete official CIFAR-10 test10k evaluation of the existing control checkpoint and its existing deployment int8 export.",
        "",
        "## Frozen inputs",
        "",
        f"- Manifest: `{args.manifest}`",
        f"- Checkpoint: `{args.checkpoint}` (SHA-256 `{sha256_file(args.checkpoint)}`)",
        f"- Export: `{args.export}` (SHA-256 `{sha256_file(args.export)}`)",
        f"- Test samples evaluated: `{len(test_labels)}`",
        f"- Checkpoint stored eval_acc metadata: `{float(checkpoint_metadata.get('eval_acc', float('nan'))):.6f}`; fresh all-test evaluation below is authoritative for this QA run",
        f"- Deploy mapping: `i8 = clip(int16(raw_uint8) - 128, -128, 127)`; signed int8; zero point 128; scale 1/127.5",
        "",
        "## Accuracy",
        "",
        "| Evaluator | Correct | Total | Top-1 |",
        "| --- | ---: | ---: | ---: |",
        f"| FP32 control checkpoint | {float_correct} | {len(test_labels)} | {float_acc:.6f} ({100*float_acc:.2f}%) |",
        f"| Deployment INT8 integer evaluator | {int8_correct} | {len(test_labels)} | {int8_acc:.6f} ({100*int8_acc:.2f}%) |",
        f"| FP32 to INT8 drop |  |  | {100*(float_acc-int8_acc):.4f} percentage points |",
        "",
        "## Per-class statistics",
        "",
        "| ID | Class | Count | FP32 correct | FP32 acc | INT8 correct | INT8 acc |",
        "| ---: | --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    float_rows = per_class(float_predictions, test_labels)
    int8_rows = per_class(int8_predictions, test_labels)
    for frow, irow in zip(float_rows, int8_rows):
        report_lines.append(f"| {frow['class_id']} | {frow['class_name']} | {frow['count']} | {frow['correct']} | {100*frow['accuracy']:.2f}% | {irow['correct']} | {100*irow['accuracy']:.2f}% |")
    report_lines += [
        "",
        "## Reproduction commands",
        "",
        "```powershell",
        f"python python/quantize_export.py --ckpt {args.checkpoint} --out build/c10_hwqa_v1_export --vectors build/c10_hwqa_v1_vectors --accuracy-samples 10000 --accuracy-batch-size {args.batch_size}",
        f"python python/c10_hwqa_v1.py --data-dir {args.data_dir} --archive {args.archive} --checkpoint {args.checkpoint} --export {args.export} --manifest {args.manifest} --report {args.report} --batch-size {args.batch_size}",
        "```",
        "",
        "The INT8 batch path uses the same deployment quantization equations and integer parameters as `run_exported_int8_model`; a scalar-vs-batch logits check was performed on three test images before the full run.",
    ]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    print(f"manifest={args.manifest}")
    print(f"report={args.report}")
    print(f"fp32_top1={float_correct}/{len(test_labels)}={float_acc:.6f}")
    print(f"int8_top1={int8_correct}/{len(test_labels)}={int8_acc:.6f}")
    print(f"drop_pp={(float_acc-int8_acc)*100:.4f}")


if __name__ == "__main__":
    main()
