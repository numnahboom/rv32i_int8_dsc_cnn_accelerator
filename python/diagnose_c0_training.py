#!/usr/bin/env python3
"""Reproduce the C0 50.38%-versus-10% training regression evidence.

This is deliberately independent of RTL and does not modify checkpoints.  It
checks state-dict compatibility, preprocessing/labels, evaluator agreement,
initial gradient/update health, and a tiny-batch overfit test.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

from c10_hwqa_v1 import evaluate_float, load_cifar
from resnet20_hwqa import CifarDataset, frozen_split, load_cifar10, seed_everything
from train_c0_hwqa import EdgeDSCNetC10


class LegacyDataset(Dataset):
    """The original smoke evaluator's exact uint8 -> centered FP32 path."""

    def __init__(self, images: np.ndarray, labels: np.ndarray) -> None:
        self.images, self.labels = images, labels

    def __len__(self) -> int:
        return int(self.labels.size)

    def __getitem__(self, index: int):
        x = torch.from_numpy(self.images[index].transpose(2, 0, 1)).float() / 255.0
        return (x - 0.5) / 0.5, torch.tensor(int(self.labels[index]), dtype=torch.long)


def eval_loader(model: torch.nn.Module, loader: DataLoader) -> tuple[int, int, float]:
    model.eval()
    correct = total = 0
    loss_sum = 0.0
    with torch.inference_mode():
        for x, y in loader:
            logits = model(x)
            loss_sum += float(F.cross_entropy(logits, y)) * y.numel()
            correct += int((logits.argmax(1) == y).sum())
            total += int(y.numel())
    return correct, total, loss_sum / max(1, total)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--old-checkpoint", type=Path, default=Path("build/model/edgedscnet_c10_torch_cifar10.npz"))
    p.add_argument("--new-checkpoint", type=Path, default=Path("build/model/c0_edgedscnet_hwqa_fp32.pt"))
    p.add_argument("--out", type=Path, default=Path("build/c0_training_diagnosis.json"))
    p.add_argument("--overfit-samples", type=int, default=64)
    args = p.parse_args()

    seed_everything(20260901)
    images, labels = load_cifar10(args.data, "train")
    test_images, test_labels = load_cifar(args.data / "cifar-10-batches-py", "test")
    legacy_test_images, legacy_test_labels = load_cifar10(args.data, "test")
    tr, va = frozen_split(labels)
    result: dict[str, object] = {
        "dataset": {"train_shape": list(images.shape), "test_shape": list(test_images.shape), "legacy_loader_images_equal": bool(np.array_equal(test_images, legacy_test_images)), "legacy_loader_labels_equal": bool(np.array_equal(test_labels, legacy_test_labels)), "split_train": int(tr.size), "split_validation": int(va.size)},
        "checkpoints": {},
    }

    for name, path in (("old", args.old_checkpoint), ("new", args.new_checkpoint)):
        if not path.exists():
            continue
        ckpt = torch.load(path, map_location="cpu", weights_only=False)
        model = EdgeDSCNetC10()
        incompatible = model.load_state_dict(ckpt["model_state"], strict=False)
        legacy = DataLoader(LegacyDataset(test_images, test_labels), batch_size=256, shuffle=False)
        current = DataLoader(CifarDataset(test_images, test_labels, False, 17), batch_size=256, shuffle=False)
        old_correct, total, old_loss = eval_loader(model, legacy)
        new_correct, _, new_loss = eval_loader(model, current)
        result["checkpoints"][name] = {
            "path": str(path), "backend": ckpt.get("backend"), "architecture": ckpt.get("architecture"),
            "state_keys": len(ckpt["model_state"]), "missing_keys": list(incompatible.missing_keys), "unexpected_keys": list(incompatible.unexpected_keys),
            "legacy_eval": {"correct": old_correct, "total": total, "accuracy": old_correct / total, "loss": old_loss},
            "current_eval": {"correct": new_correct, "total": total, "accuracy": new_correct / total, "loss": new_loss},
            "evaluator_equal": bool(old_correct == new_correct and abs(old_loss - new_loss) < 1e-7),
            "metadata": {k: ckpt.get(k) for k in ("seed", "epochs", "batch_size", "lr", "optimizer", "schedule", "weight_decay", "augmentation", "eval_acc") if k in ckpt},
        }

    # The critical optimizer/batch evidence is measured on the same 64 samples.
    over_images, over_labels = images[tr[: args.overfit_samples]], labels[tr[: args.overfit_samples]]
    ds = CifarDataset(over_images, over_labels, False, 101)
    loader = DataLoader(ds, batch_size=min(32, args.overfit_samples), shuffle=False)
    model = EdgeDSCNetC10()
    first = next(iter(loader))
    logits = model(first[0])
    loss = F.cross_entropy(logits, first[1])
    loss.backward()
    grad_fc = float(model.fc.weight.grad.abs().mean())
    grad_stem = float(model.stem.weight.grad.abs().mean())
    before = float(model.fc.weight.detach().norm())
    opt = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=5e-4)
    for _ in range(20):
        for x, y in loader:
            opt.zero_grad(set_to_none=True)
            out = model(x)
            F.cross_entropy(out, y).backward()
            opt.step()
    after = float(model.fc.weight.detach().norm())
    correct, total, overfit_loss = eval_loader(model, DataLoader(LegacyDataset(over_images, over_labels), batch_size=64))
    result["gradient_and_overfit"] = {"samples": args.overfit_samples, "initial_loss": float(loss.detach()), "fc_grad_mean": grad_fc, "stem_grad_mean": grad_stem, "fc_norm_before": before, "fc_norm_after": after, "parameter_changed": bool(before != after), "overfit_loss": overfit_loss, "overfit_accuracy": correct / total}

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
