#!/usr/bin/env python3
"""Export the C0 BN-fold QAT checkpoint with the unchanged INT8 contract."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import numpy as np
import torch

from c0_bnfold_export import export_int8
from c0_bnfold_model import C0FoldedNet
from c0_bnfold_qat_model import C0BNFoldQAT
from quantize_export import evaluate_exported_int8_model, run_exported_int8_model, run_exported_int8_model_batch
from resnet20_hwqa import load_cifar10


def load_state(path: Path) -> dict[str, Any]:
    try:
        value = torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        value = torch.load(path, map_location="cpu")
    if not isinstance(value, dict) or "model_state" not in value:
        raise ValueError(f"invalid QAT checkpoint: {path}")
    return value


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, default=Path("build/c0_bnfold_qat/c0_bnfold_qat.pt"))
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=Path("build/c0_bnfold_qat/c0_bnfold_qat_export"))
    p.add_argument("--accuracy-samples", type=int, default=0)
    p.add_argument("--batch-size", type=int, default=128)
    args = p.parse_args()
    ckpt = load_state(args.checkpoint)
    folded = C0FoldedNet(); folded.load_state_dict(ckpt["model_state"]); folded.eval()
    test_images, test_labels = load_cifar10(args.data, "test")
    export = export_int8(folded, test_images[0], ckpt, args.out, filename="c0_bnfold_qat_int8.npz")
    with np.load(export["path"], allow_pickle=True) as z:
        params = {key: z[key] for key in z.files}
    count = int(args.accuracy_samples) if args.accuracy_samples > 0 else int(test_labels.size)
    count = min(count, int(test_labels.size))
    int8_pred, int8_correct = evaluate_exported_int8_model(test_images[:count], test_labels[:count], params, args.batch_size)
    qat = C0BNFoldQAT(folded).eval()
    qat_pred = np.empty(count, dtype=np.int64)
    with torch.inference_mode():
        for start in range(0, count, max(1, args.batch_size)):
            stop = min(start + max(1, args.batch_size), count)
            x = torch.from_numpy(test_images[start:stop].transpose(0, 3, 1, 2)).float() * (1.0 / 127.5) - 1.0
            qat_pred[start:stop] = qat(x).argmax(1).numpy()
    qat_correct = int(np.sum(qat_pred == test_labels[:count]))
    scalar_logits = np.asarray([run_exported_int8_model(image, params)[0] for image in test_images[:4]], dtype=np.int16)
    batch_logits = run_exported_int8_model_batch(test_images[:4], params).astype(np.int16)
    if not np.array_equal(scalar_logits, batch_logits):
        raise RuntimeError("QAT INT8 scalar/batch evaluator mismatch")
    agreement = int(np.sum(qat_pred == int8_pred))
    result = {
        "schema": "C10-HWQA-v1-c0-bnfold-qat-export",
        "checkpoint": str(args.checkpoint), "export": export,
        "samples": count, "qat_fake_quant_correct": qat_correct,
        "qat_fake_quant_top1": qat_correct / max(1, count),
        "int8_correct": int8_correct, "int8_top1": int8_correct / max(1, count),
        "qat_vs_int8_prediction_agreement": agreement / max(1, count),
        "scalar_batch_logits_equal": True,
        "runtime_bn": False,
        "primitive_contract": "original C0 stem/DW/PW/ReLU6/GAP/FC; INT8 activations/weights, INT32 accumulators",
    }
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = args.out / "c0_bnfold_qat_export_manifest.json"
    manifest.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
