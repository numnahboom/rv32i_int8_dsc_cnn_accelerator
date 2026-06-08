#!/usr/bin/env python3
"""Lightweight training smoke for EdgeDSCNet-C10.

The preferred path uses PyTorch and trains the actual MobileNetV1-like network.
If PyTorch is not installed, the script automatically falls back to a small
NumPy softmax trainer on CIFAR-10. The fallback is intentionally simple: it
verifies dataset loading, batching, loss/accuracy plumbing, checkpoint writing,
and downstream quantize/export scripts without requiring network installs.
"""

from __future__ import annotations

import argparse
import pickle
import warnings
from pathlib import Path
from typing import Any

import numpy as np


CLASS_NAMES = [
    "airplane",
    "automobile",
    "bird",
    "cat",
    "deer",
    "dog",
    "frog",
    "horse",
    "ship",
    "truck",
]

try:
    VISIBLE_DEPRECATION_WARNING = np.exceptions.VisibleDeprecationWarning
except AttributeError:
    VISIBLE_DEPRECATION_WARNING = getattr(np, "VisibleDeprecationWarning", Warning)


def find_cifar_dir(data_root: Path) -> Path:
    candidates = [
        data_root / "cifar-10-batches-py",
        data_root,
        data_root / "CIFAR-10" / "cifar-10-batches-py",
    ]
    for candidate in candidates:
        if (candidate / "data_batch_1").exists():
            return candidate
    raise FileNotFoundError(f"cannot find CIFAR-10 python batches under {data_root}")


def load_cifar10(data_root: Path, split: str = "train") -> tuple[np.ndarray, np.ndarray]:
    cifar_dir = find_cifar_dir(data_root)
    batch_names = [f"data_batch_{i}" for i in range(1, 6)] if split == "train" else ["test_batch"]
    images = []
    labels = []
    for name in batch_names:
        with (cifar_dir / name).open("rb") as f:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", VISIBLE_DEPRECATION_WARNING)
                batch = pickle.load(f, encoding="latin1")
        data = batch["data"].reshape(-1, 3, 32, 32).transpose(0, 2, 3, 1)
        images.append(data.astype(np.uint8))
        labels.extend(batch["labels"])
    return np.concatenate(images, axis=0), np.asarray(labels, dtype=np.int64)


def limit_dataset(
    images: np.ndarray,
    labels: np.ndarray,
    max_samples: int,
    seed: int,
) -> tuple[np.ndarray, np.ndarray]:
    if max_samples <= 0 or max_samples >= len(labels):
        return images, labels
    rng = np.random.default_rng(seed)
    indices = rng.permutation(len(labels))[:max_samples]
    return images[indices], labels[indices]


def softmax_cross_entropy(logits: np.ndarray, labels: np.ndarray) -> tuple[float, np.ndarray]:
    logits = logits - np.max(logits, axis=1, keepdims=True)
    exp_logits = np.exp(logits)
    probs = exp_logits / np.sum(exp_logits, axis=1, keepdims=True)
    loss = -np.log(probs[np.arange(labels.shape[0]), labels] + 1e-12).mean()
    probs[np.arange(labels.shape[0]), labels] -= 1.0
    probs /= labels.shape[0]
    return float(loss), probs


def train_numpy_smoke(args: argparse.Namespace) -> dict[str, Any]:
    train_images, train_labels = load_cifar10(args.data, "train")
    test_images, test_labels = load_cifar10(args.data, "test")
    train_images, train_labels = limit_dataset(train_images, train_labels, args.max_samples, args.seed)
    test_images, test_labels = limit_dataset(test_images, test_labels, args.eval_samples, args.seed + 1)

    x_train = train_images.astype(np.float32).reshape(train_images.shape[0], -1)
    x_eval = test_images.astype(np.float32).reshape(test_images.shape[0], -1)
    x_train = (x_train - 127.5) / 127.5
    x_eval = (x_eval - 127.5) / 127.5

    rng = np.random.default_rng(args.seed)
    weight = rng.normal(0.0, 0.01, size=(x_train.shape[1], 10)).astype(np.float32)
    bias = np.zeros(10, dtype=np.float32)
    history: list[tuple[int, float, float]] = []

    for epoch in range(args.epochs):
        perm = rng.permutation(x_train.shape[0])
        total_loss = 0.0
        total_correct = 0
        total_seen = 0
        for start in range(0, x_train.shape[0], args.batch_size):
            batch_idx = perm[start : start + args.batch_size]
            xb = x_train[batch_idx]
            yb = train_labels[batch_idx]
            logits = xb @ weight + bias
            loss, grad_logits = softmax_cross_entropy(logits, yb)
            grad_w = xb.T @ grad_logits
            grad_b = np.sum(grad_logits, axis=0)
            weight -= args.lr * grad_w.astype(np.float32)
            bias -= args.lr * grad_b.astype(np.float32)

            total_loss += loss * len(batch_idx)
            total_correct += int(np.sum(np.argmax(logits, axis=1) == yb))
            total_seen += len(batch_idx)

        train_loss = total_loss / max(1, total_seen)
        train_acc = total_correct / max(1, total_seen)
        history.append((epoch + 1, train_loss, train_acc))
        print(f"numpy epoch={epoch + 1} loss={train_loss:.4f} acc={train_acc:.3f}")

    eval_logits = x_eval @ weight + bias
    eval_acc = float(np.mean(np.argmax(eval_logits, axis=1) == test_labels))
    print(f"numpy eval_acc={eval_acc:.3f} samples={len(test_labels)}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        args.out,
        backend=np.asarray("numpy_softmax"),
        class_names=np.asarray(CLASS_NAMES),
        seed=np.asarray(args.seed, dtype=np.int64),
        max_samples=np.asarray(args.max_samples, dtype=np.int64),
        eval_samples=np.asarray(args.eval_samples, dtype=np.int64),
        epochs=np.asarray(args.epochs, dtype=np.int64),
        train_history=np.asarray(history, dtype=np.float32),
        eval_acc=np.asarray(eval_acc, dtype=np.float32),
        linear_weight=weight,
        linear_bias=bias,
        sample_image_uint8=train_images[0],
        sample_label=np.asarray(train_labels[0], dtype=np.int64),
        eval_images_uint8=test_images,
        eval_labels=test_labels,
    )
    print(f"wrote {args.out}")
    return {"backend": "numpy_softmax", "eval_acc": eval_acc}


def train_torch(args: argparse.Namespace) -> dict[str, Any]:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from torch.utils.data import DataLoader, Dataset

    class CifarArrayDataset(Dataset):
        def __init__(self, images: np.ndarray, labels: np.ndarray) -> None:
            self.images = images
            self.labels = labels

        def __len__(self) -> int:
            return int(self.labels.shape[0])

        def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
            x = torch.from_numpy(self.images[idx].transpose(2, 0, 1)).float() / 255.0
            x = (x - 0.5) / 0.5
            y = torch.tensor(int(self.labels[idx]), dtype=torch.long)
            return x, y

    class DSBlock(nn.Module):
        def __init__(self, cin: int, cout: int, stride: int) -> None:
            super().__init__()
            self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=True)
            self.pw = nn.Conv2d(cin, cout, 1, bias=True)

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            x = F.relu6(self.dw(x))
            x = F.relu6(self.pw(x))
            return x

    class EdgeDSCNetC10(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
            self.blocks = nn.Sequential(
                DSBlock(16, 32, 1),
                DSBlock(32, 64, 2),
                DSBlock(64, 64, 1),
                DSBlock(64, 128, 2),
                DSBlock(128, 128, 1),
                DSBlock(128, 256, 2),
            )
            self.fc = nn.Linear(256, 10)

        def forward(self, x: torch.Tensor) -> torch.Tensor:
            x = F.relu6(self.stem(x))
            x = self.blocks(x)
            x = F.adaptive_avg_pool2d(x, 1).flatten(1)
            return self.fc(x)

    train_images, train_labels = load_cifar10(args.data, "train")
    test_images, test_labels = load_cifar10(args.data, "test")
    train_images, train_labels = limit_dataset(train_images, train_labels, args.max_samples, args.seed)
    test_images, test_labels = limit_dataset(test_images, test_labels, args.eval_samples, args.seed + 1)

    torch.manual_seed(args.seed)
    device = torch.device(args.device)
    model = EdgeDSCNetC10().to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    train_loader = DataLoader(
        CifarArrayDataset(train_images, train_labels),
        batch_size=args.batch_size,
        shuffle=True,
    )
    eval_loader = DataLoader(
        CifarArrayDataset(test_images, test_labels),
        batch_size=args.batch_size,
        shuffle=False,
    )

    history = []
    for epoch in range(args.epochs):
        model.train()
        total_loss = 0.0
        total_correct = 0
        total_seen = 0
        for xb, yb in train_loader:
            xb = xb.to(device)
            yb = yb.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(xb)
            loss = F.cross_entropy(logits, yb)
            loss.backward()
            optimizer.step()
            total_loss += float(loss.detach().cpu()) * xb.shape[0]
            total_correct += int((torch.argmax(logits, dim=1) == yb).sum().detach().cpu())
            total_seen += xb.shape[0]
        train_loss = total_loss / max(1, total_seen)
        train_acc = total_correct / max(1, total_seen)
        history.append((epoch + 1, train_loss, train_acc))
        print(f"torch epoch={epoch + 1} loss={train_loss:.4f} acc={train_acc:.3f}")

    model.eval()
    total_correct = 0
    total_seen = 0
    with torch.no_grad():
        for xb, yb in eval_loader:
            logits = model(xb.to(device))
            total_correct += int((torch.argmax(logits.cpu(), dim=1) == yb).sum())
            total_seen += xb.shape[0]
    eval_acc = total_correct / max(1, total_seen)
    print(f"torch eval_acc={eval_acc:.3f} samples={total_seen}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "backend": "torch_edgedscnet_c10",
            "class_names": CLASS_NAMES,
            "seed": args.seed,
            "epochs": args.epochs,
            "max_samples": args.max_samples,
            "eval_samples": args.eval_samples,
            "history": history,
            "eval_acc": eval_acc,
            "model_state": model.cpu().state_dict(),
            "sample_image_uint8": train_images[0],
            "sample_label": int(train_labels[0]),
            "eval_images_uint8": test_images,
            "eval_labels": test_labels,
        },
        args.out,
    )
    print(f"wrote {args.out}")
    return {"backend": "torch_edgedscnet_c10", "eval_acc": eval_acc}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=Path("/mnt/d/Stuff/data"))
    parser.add_argument("--out", type=Path, default=Path("build/model/edgedscnet_c10_smoke.npz"))
    parser.add_argument("--backend", choices=["auto", "torch", "numpy"], default="auto")
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--max-samples", type=int, default=256)
    parser.add_argument("--eval-samples", type=int, default=128)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-2)
    parser.add_argument("--seed", type=int, default=20260601)
    parser.add_argument("--device", default="cpu")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.backend in ("auto", "torch"):
        try:
            train_torch(args)
            return
        except ModuleNotFoundError as exc:
            if args.backend == "torch":
                raise
            print(f"PyTorch unavailable ({exc}); falling back to NumPy smoke trainer.")
    train_numpy_smoke(args)


if __name__ == "__main__":
    main()
