#!/usr/bin/env python3
"""C0 EdgeDSCNet-C10 trainer with an auditable, deployable checkpoint.

The C0 graph has no normalization layers.  In particular, the C10 ResNet
recipe (SGD at LR 0.1) leaves this deep ReLU6 stack at chance, so the default
recipe intentionally matches the known-good C0 smoke trainer (Adam, LR 1e-3,
zero weight decay, no augmentation).  The split, input mapping, checkpoint
schema, and evaluator remain C10-HWQA-v1 compatible.  ``--augmentation
pad4_flip`` and ``--optimizer sgd`` are available for controlled comparisons.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F

from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything
from torch.utils.data import DataLoader


class DSBlock(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int) -> None:
        super().__init__()
        self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=True)
        self.pw = nn.Conv2d(cin, cout, 1, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
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

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu6(self.stem(x)); x = self.blocks(x)
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data")); p.add_argument("--out", type=Path, default=Path("build/model/c0_edgedscnet_hwqa_fp32.pt"))
    p.add_argument("--epochs", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--optimizer", choices=("adam", "sgd"), default="adam")
    p.add_argument("--schedule", choices=("none", "cosine"), default="none")
    p.add_argument("--weight-decay", type=float, default=0.0)
    p.add_argument("--augmentation", choices=("none", "pad4_flip"), default="none")
    p.add_argument("--seed", type=int, default=20260901); p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu"); args = p.parse_args()
    seed_everything(args.seed); device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train"); tr, va = frozen_split(train_y)
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], args.augmentation == "pad4_flip", args.seed + 101), batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, args.seed + 102), batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    test_x, test_y = load_cifar10(args.data, "test")
    test = DataLoader(CifarDataset(test_x, test_y, False, args.seed + 103), batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    model = EdgeDSCNetC10().to(device)
    if args.optimizer == "adam":
        opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    else:
        opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=args.weight_decay, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs) if args.schedule == "cosine" else None
    history = []
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch; model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True); opt.zero_grad(set_to_none=True); logits = model(x); loss = F.cross_entropy(logits, y); loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel(); correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        if sched is not None:
            sched.step()
        vl, va_acc = evaluate(model, valid, device); row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / seen, "train_acc": correct / seen, "val_loss": vl, "val_acc": va_acc}; history.append(row); print(json.dumps(row), flush=True)
    test_loss, test_acc = evaluate(model, test, device)
    # Preserve deterministic uint8 sample metadata required by the exporter.
    # Store the fresh test score as metadata, while reports still re-evaluate
    # all 10k samples from the checkpoint as the authoritative result.
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "schema": "C10-HWQA-v1-c0-edgedscnet-fp32",
        "backend": "torch_edgedscnet_c10_full_hwqa",
        "architecture": "edgedscnet_c10_control",
        "seed": args.seed,
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "lr": args.lr,
        "optimizer": args.optimizer,
        "schedule": args.schedule,
        "augmentation": args.augmentation,
        "weight_decay": args.weight_decay,
        "history": history,
        "eval_acc": test_acc,
        "eval_loss": test_loss,
        "model_state": model.cpu().state_dict(),
        "train_indices": tr,
        "validation_indices": va,
        "sample_image_uint8": train_x[0],
        "sample_label": int(train_y[0]),
    }, args.out)
    print(json.dumps({"test_loss": test_loss, "test_acc": test_acc}))
    print(f"wrote {args.out}")


if __name__ == "__main__": main()
