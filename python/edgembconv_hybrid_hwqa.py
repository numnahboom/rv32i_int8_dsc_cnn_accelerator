#!/usr/bin/env python3
"""C10-HWQA-v1 EdgeMBConv-Hybrid model and FP32 training entry point.

The graph is intentionally restricted to the fixed, hardware-oriented
operator contract used by the deployment exporter:

* dense 3x3 stem and fused blocks;
* 1x1 expansion/projection and depthwise 3x3 MBConv blocks;
* ReLU6 only on expansion/spatial outputs;
* linear projection, common-scale residual add, GAP and FC.

BatchNorm is present while training and is folded by the QAT/export stages.
This file does not depend on, or change, the RTL implementation.
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader

from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


INPUT_SCALE = 1.0 / 127.5
NUM_CLASSES = 10


class FusedBlock(nn.Module):
    """Dense 3x3 expansion followed by a linear 1x1 projection."""

    def __init__(self, cin: int, hidden: int, cout: int, stride: int = 1, residual: bool = False) -> None:
        super().__init__()
        self.expand = nn.Conv2d(cin, hidden, 3, stride=stride, padding=1, bias=False)
        self.expand_bn = nn.BatchNorm2d(hidden)
        self.project = nn.Conv2d(hidden, cout, 1, bias=False)
        self.project_bn = nn.BatchNorm2d(cout)
        self.residual = bool(residual)
        if self.residual and (cin != cout or stride != 1):
            raise ValueError("residual fused block requires equal channels and stride 1")

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.expand_bn(self.expand(x)), inplace=False)
        y = self.project_bn(self.project(y))
        return y + x if self.residual else y


class MBConv(nn.Module):
    """Mobile inverted bottleneck: expand, spatial DW, linear projection."""

    def __init__(self, cin: int, hidden: int, cout: int, stride: int = 1, residual: bool = False) -> None:
        super().__init__()
        self.expand = nn.Conv2d(cin, hidden, 1, bias=False)
        self.expand_bn = nn.BatchNorm2d(hidden)
        self.spatial = nn.Conv2d(hidden, hidden, 3, stride=stride, padding=1, groups=hidden, bias=False)
        self.spatial_bn = nn.BatchNorm2d(hidden)
        self.project = nn.Conv2d(hidden, cout, 1, bias=False)
        self.project_bn = nn.BatchNorm2d(cout)
        self.residual = bool(residual)
        if self.residual and (cin != cout or stride != 1):
            raise ValueError("residual MBConv requires equal channels and stride 1")

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = F.relu6(self.expand_bn(self.expand(x)), inplace=False)
        y = F.relu6(self.spatial_bn(self.spatial(y)), inplace=False)
        y = self.project_bn(self.project(y))
        return y + x if self.residual else y


class EdgeMBConvHybrid(nn.Module):
    """The fixed EdgeMBConv-Hybrid CIFAR-10 graph."""

    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 16, 3, padding=1, bias=False),
            nn.BatchNorm2d(16),
        )
        # Keep named modules stable for folding/export and for the profile.
        self.fused1 = FusedBlock(16, 32, 16, stride=1, residual=True)
        self.fused2 = FusedBlock(16, 32, 32, stride=2, residual=False)
        self.mb16 = nn.Sequential(
            MBConv(32, 64, 32, stride=1, residual=True),
            MBConv(32, 64, 32, stride=1, residual=True),
        )
        self.mb8_down = MBConv(32, 64, 64, stride=2, residual=False)
        self.mb8 = nn.Sequential(
            MBConv(64, 128, 64, stride=1, residual=True),
            MBConv(64, 128, 64, stride=1, residual=True),
            MBConv(64, 128, 64, stride=1, residual=True),
        )
        self.mb4_down = MBConv(64, 128, 128, stride=2, residual=False)
        self.mb4 = nn.Sequential(
            MBConv(128, 256, 128, stride=1, residual=True),
            MBConv(128, 256, 128, stride=1, residual=True),
        )
        self.head = nn.Sequential(nn.Conv2d(128, 256, 1, bias=False), nn.BatchNorm2d(256))
        self.fc = nn.Linear(256, NUM_CLASSES)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu6(self.stem[1](self.stem[0](x)), inplace=False)
        x = self.fused1(x)
        x = self.fused2(x)
        x = self.mb16(x)
        x = self.mb8_down(x)
        x = self.mb8(x)
        x = self.mb4_down(x)
        x = self.mb4(x)
        x = self.head[1](self.head[0](x))
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def make_loaders(data: Path, batch_size: int, seed: int) -> tuple[DataLoader, DataLoader, DataLoader, np.ndarray, np.ndarray]:
    train_x, train_y = load_cifar10(data, "train")
    test_x, test_y = load_cifar10(data, "test")
    tr, va = frozen_split(train_y)
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, seed + 101), batch_size=batch_size,
                       shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, seed + 102), batch_size=batch_size,
                       shuffle=False, num_workers=0, pin_memory=True)
    test = DataLoader(CifarDataset(test_x, test_y, False, seed + 103), batch_size=batch_size,
                      shuffle=False, num_workers=0, pin_memory=True)
    return train, valid, test, tr, va


def train_fp32(args: argparse.Namespace) -> None:
    seed_everything(args.seed)
    device = torch.device(args.device)
    train, valid, test, tr, va = make_loaders(args.data, args.batch_size, args.seed)
    model = EdgeMBConvHybrid().to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=args.weight_decay,
                          nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []
    best_val = -1.0
    best_epoch = 0
    best_state: dict[str, torch.Tensor] | None = None
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch
        model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad(set_to_none=True)
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel()
            correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step()
        val_loss, val_acc = evaluate(model, valid, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / max(1, seen),
               "train_acc": correct / max(1, seen), "val_loss": val_loss, "val_acc": val_acc}
        history.append(row); print(json.dumps(row), flush=True)
        if val_acc > best_val:
            best_val, best_epoch = val_acc, epoch + 1
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    if best_state is None:
        best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state); model.eval()
    test_loss, test_acc = evaluate(model, test, torch.device("cpu"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "schema": "C10-HWQA-v1-edgembconv-hybrid-fp32",
        "architecture": "EdgeMBConv-Hybrid",
        "seed": args.seed, "epochs": args.epochs, "batch_size": args.batch_size,
        "lr": args.lr, "weight_decay": args.weight_decay,
        "history": history, "best_epoch": best_epoch, "best_val_acc": best_val,
        "eval_acc": test_acc, "eval_loss": test_loss,
        "model_state": model.state_dict(), "train_indices": tr, "validation_indices": va,
    }, args.out)
    print(json.dumps({"best_epoch": best_epoch, "best_val_acc": best_val, "test_acc": test_acc}))
    print(f"wrote {args.out}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=Path("build/model/edgembconv_hybrid_hwqa_fp32.pt"))
    p.add_argument("--epochs", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.1)
    p.add_argument("--weight-decay", type=float, default=5e-4)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return p.parse_args()


if __name__ == "__main__":
    train_fp32(parse_args())
