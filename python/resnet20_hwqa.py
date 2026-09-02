#!/usr/bin/env python3
"""C10-HWQA-v1 hardware-friendly CIFAR-10 ResNet-20 training.

This module deliberately keeps the model in the deployable operator subset:
dense 3x3 convolutions, 1x1 projection convolutions, ReLU, global average
pooling, and a linear classifier.  BatchNorm is used only during the FP32
training stage and is folded before QAT/export.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pickle
import random
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

CLASS_NAMES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]
INPUT_SCALE = 1.0 / 127.5


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def find_cifar_dir(data_root: Path) -> Path:
    for candidate in (data_root / "cifar-10-batches-py", data_root):
        if (candidate / "data_batch_1").exists() and (candidate / "test_batch").exists():
            return candidate
    raise FileNotFoundError(f"CIFAR-10 batches not found under {data_root}")


def load_cifar10(data_root: Path, split: str) -> tuple[np.ndarray, np.ndarray]:
    root = find_cifar_dir(data_root)
    names = [f"data_batch_{i}" for i in range(1, 6)] if split == "train" else ["test_batch"]
    xs, ys = [], []
    for name in names:
        with (root / name).open("rb") as f:
            item = pickle.load(f, encoding="latin1")
        xs.append(np.asarray(item["data"], dtype=np.uint8).reshape(-1, 3, 32, 32).transpose(0, 2, 3, 1))
        ys.extend(item["labels"])
    return np.concatenate(xs), np.asarray(ys, dtype=np.int64)


def frozen_split(labels: np.ndarray, seed: int = 20260901) -> tuple[np.ndarray, np.ndarray]:
    """Exactly the manifest algorithm: per-class permutation, 4500/500."""
    rng = np.random.default_rng(seed)
    train, valid = [], []
    for cls in range(10):
        idx = np.flatnonzero(labels == cls)
        perm = idx[rng.permutation(idx.size)]
        train.extend(perm[:4500].tolist())
        valid.extend(perm[4500:].tolist())
    return np.asarray(train, dtype=np.int64), np.asarray(valid, dtype=np.int64)


class CifarDataset(Dataset):
    def __init__(self, images: np.ndarray, labels: np.ndarray, augment: bool, seed: int) -> None:
        self.images, self.labels = images, labels
        self.augment, self.seed, self.epoch = augment, seed, 0

    def __len__(self) -> int:
        return int(self.labels.size)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        image = self.images[index]
        if self.augment:
            # Per-sample deterministic RNG keeps runs reproducible with workers=0.
            rng = np.random.default_rng(self.seed + self.epoch * 1_000_003 + int(index))
            image = np.pad(image, ((4, 4), (4, 4), (0, 0)), mode="constant")
            y = int(rng.integers(0, 9))
            x = int(rng.integers(0, 9))
            image = image[y : y + 32, x : x + 32]
            if bool(rng.integers(0, 2)):
                image = image[:, ::-1]
        x = torch.from_numpy(np.ascontiguousarray(image.transpose(2, 0, 1))).float() * (1.0 / 127.5) - 1.0
        return x, torch.tensor(int(self.labels[index]), dtype=torch.long)


class BasicBlock(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=False)
        self.bn1 = nn.BatchNorm2d(cout)
        self.conv2 = nn.Conv2d(cout, cout, 3, padding=1, bias=False)
        self.bn2 = nn.BatchNorm2d(cout)
        self.proj = nn.Conv2d(cin, cout, 1, stride=stride, bias=False) if (stride != 1 or cin != cout) else None
        self.proj_bn = nn.BatchNorm2d(cout) if self.proj is not None else None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        identity = x
        y = F.relu(self.bn1(self.conv1(x)), inplace=False)
        y = self.bn2(self.conv2(y))
        if self.proj is not None:
            identity = self.proj_bn(self.proj(identity))
        return F.relu(y + identity, inplace=False)


class ResNet20(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Sequential(nn.Conv2d(3, 16, 3, padding=1, bias=False), nn.BatchNorm2d(16), nn.ReLU(inplace=False))
        self.stage1 = nn.Sequential(BasicBlock(16, 16, 1), BasicBlock(16, 16, 1), BasicBlock(16, 16, 1))
        self.stage2 = nn.Sequential(BasicBlock(16, 32, 2), BasicBlock(32, 32, 1), BasicBlock(32, 32, 1))
        self.stage3 = nn.Sequential(BasicBlock(32, 64, 2), BasicBlock(64, 64, 1), BasicBlock(64, 64, 1))
        self.fc = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.stem(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False


def make_loaders(data: Path, batch: int, seed: int) -> tuple[DataLoader, DataLoader, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    train_x, train_y = load_cifar10(data, "train")
    test_x, test_y = load_cifar10(data, "test")
    tr, va = frozen_split(train_y)
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, seed), batch_size=batch, shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, seed + 1), batch_size=batch, shuffle=False, num_workers=0, pin_memory=True)
    return train, valid, test_x, test_y, tr, va


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> tuple[float, float]:
    model.eval(); total = correct = 0; loss_sum = 0.0
    for x, y in loader:
        x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
        logits = model(x); loss = F.cross_entropy(logits, y)
        loss_sum += float(loss) * y.numel(); correct += int((logits.argmax(1) == y).sum()); total += y.numel()
    return loss_sum / max(1, total), correct / max(1, total)


def train_fp32(args: argparse.Namespace) -> None:
    seed_everything(args.seed)
    device = torch.device(args.device)
    train, valid, _, _, tr, va = make_loaders(args.data, args.batch_size, args.seed)
    model = ResNet20().to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=5e-4, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch
        model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad(set_to_none=True); logits = model(x); loss = F.cross_entropy(logits, y)
            loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel(); correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step(); vl, va_acc = evaluate(model, valid, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / seen, "train_acc": correct / seen, "val_loss": vl, "val_acc": va_acc}
        history.append(row); print(json.dumps(row), flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"schema": "C10-HWQA-v1-resnet20-fp32", "architecture": "resnet20", "seed": args.seed, "epochs": args.epochs, "history": history, "model_state": model.cpu().state_dict(), "train_indices": tr, "validation_indices": va}, args.out)
    print(f"wrote {args.out}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=Path("build/model/resnet20_hwqa_fp32.pt"))
    p.add_argument("--epochs", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.1)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return p.parse_args()


if __name__ == "__main__":
    train_fp32(parse_args())
