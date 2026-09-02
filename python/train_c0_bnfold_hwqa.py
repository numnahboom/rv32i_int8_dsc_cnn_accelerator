#!/usr/bin/env python3
"""Train the independent C0 BN-fold software candidate under C10-HWQA-v1.

The only graph change during training is BatchNorm after each existing C0
convolution.  ``c0_bnfold_export.py`` folds these layers back into the same
convolution/linear primitive graph before deployment evaluation.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from c0_bnfold_model import C0BNTrainNet
from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_fp32.pt"))
    p.add_argument("--curve", type=Path, default=None)
    p.add_argument("--epochs", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.1)
    p.add_argument("--weight-decay", type=float, default=5e-4)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = p.parse_args()

    if args.epochs < 1:
        raise ValueError("--epochs must be positive")
    seed_everything(args.seed)
    device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train")
    test_x, test_y = load_cifar10(args.data, "test")
    tr, va = frozen_split(train_y)
    train = DataLoader(
        CifarDataset(train_x[tr], train_y[tr], True, args.seed + 101),
        batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True,
    )
    valid = DataLoader(
        CifarDataset(train_x[va], train_y[va], False, args.seed + 102),
        batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True,
    )
    test = DataLoader(
        CifarDataset(test_x, test_y, False, args.seed + 103),
        batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True,
    )
    model = C0BNTrainNet().to(device)
    optimizer = torch.optim.SGD(
        model.parameters(), lr=args.lr, momentum=0.9, nesterov=True,
        weight_decay=args.weight_decay,
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    history: list[dict[str, float | int]] = []
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch
        model.train()
        seen = correct = 0
        loss_sum = 0.0
        for x, y in train:
            x = x.to(device, non_blocking=True)
            y = y.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            loss.backward()
            optimizer.step()
            loss_sum += float(loss.detach()) * y.numel()
            correct += int((logits.argmax(1) == y).sum())
            seen += y.numel()
        scheduler.step()
        val_loss, val_acc = evaluate(model, valid, device)
        row: dict[str, float | int] = {
            "epoch": epoch + 1,
            "lr": float(optimizer.param_groups[0]["lr"]),
            "train_loss": loss_sum / max(1, seen),
            "train_acc": correct / max(1, seen),
            "val_loss": val_loss,
            "val_acc": val_acc,
        }
        history.append(row)
        print(json.dumps(row), flush=True)

    test_loss, test_acc = evaluate(model, test, device)
    model = model.cpu().eval()
    checkpoint = {
        "schema": "C10-HWQA-v1-c0-bnfold-fp32",
        "backend": "torch_c0_bnfold_training_candidate",
        "architecture": "edgedscnet_c10_control_bn_training_only",
        "deployment_graph": "original C0 conv/dw/pw/fc graph after exact BN folding",
        "seed": args.seed,
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "lr": args.lr,
        "optimizer": "sgd_nesterov",
        "schedule": "cosine",
        "augmentation": "pad4_flip",
        "weight_decay": args.weight_decay,
        "history": history,
        "eval_acc": float(test_acc),
        "eval_loss": float(test_loss),
        "model_state": model.state_dict(),
        "train_indices": tr,
        "validation_indices": va,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save(checkpoint, args.out)
    curve = args.curve or args.out.with_name("c0_bnfold_learning_curve.json")
    curve.parent.mkdir(parents=True, exist_ok=True)
    curve.write_text(json.dumps({"schema": "C10-HWQA-v1-c0-bnfold-learning-curve", "rows": history}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"test_loss": float(test_loss), "test_acc": float(test_acc), "checkpoint": str(args.out), "curve": str(curve)}))


if __name__ == "__main__":
    main()
