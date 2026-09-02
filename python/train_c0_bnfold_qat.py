#!/usr/bin/env python3
"""Train QAT for the fixed BN-folded C0 graph under C10-HWQA-v1."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from c0_bnfold_model import C0FoldedNet
from c0_bnfold_qat_model import C0BNFoldQAT
from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


def load_state(path: Path) -> dict:
    try:
        value = torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        value = torch.load(path, map_location="cpu")
    if not isinstance(value, dict) or "model_state" not in value:
        raise ValueError(f"invalid BN-fold checkpoint: {path}")
    return value


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--fp32", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_folded_fp32.pt"))
    p.add_argument("--out", type=Path, default=Path("build/c0_bnfold_qat/c0_bnfold_qat.pt"))
    p.add_argument("--curve", type=Path, default=Path("build/c0_bnfold_qat/c0_bnfold_qat_learning_curve.json"))
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--weight-decay", type=float, default=1e-5)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = p.parse_args()
    if args.epochs < 1:
        raise ValueError("--epochs must be positive")
    seed_everything(args.seed)
    device = torch.device(args.device)
    source = load_state(args.fp32)
    folded = C0FoldedNet()
    folded.load_state_dict(source["model_state"])
    qat = C0BNFoldQAT(folded).to(device)
    train_x, train_y = load_cifar10(args.data, "train")
    tr, va = frozen_split(train_y)
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, args.seed + 301), batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, args.seed + 302), batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    optimizer = torch.optim.SGD(qat.parameters(), lr=args.lr, momentum=0.9, nesterov=True, weight_decay=args.weight_decay)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    history: list[dict[str, float | int]] = []
    best_val = -1.0
    best_epoch = 0
    best_state: dict[str, torch.Tensor] | None = None
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch
        qat.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            logits = qat(x)
            loss = F.cross_entropy(logits, y)
            loss.backward(); optimizer.step()
            loss_sum += float(loss.detach()) * y.numel()
            correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        scheduler.step()
        val_loss, val_acc = evaluate(qat, valid, device)
        row: dict[str, float | int] = {"epoch": epoch + 1, "lr": float(optimizer.param_groups[0]["lr"]), "train_loss": loss_sum / max(1, seen), "train_acc": correct / max(1, seen), "val_loss": val_loss, "val_acc": val_acc}
        history.append(row); print(json.dumps(row), flush=True)
        if val_acc > best_val:
            best_val = val_acc; best_epoch = epoch + 1
            best_state = {k: v.detach().cpu().clone() for k, v in qat.core.state_dict().items()}
        args.curve.parent.mkdir(parents=True, exist_ok=True)
        args.curve.write_text(json.dumps({"schema": "C10-HWQA-v1-c0-bnfold-qat-learning-curve", "history": history}, indent=2) + "\n", encoding="utf-8")
    if best_state is None:
        best_state = {k: v.detach().cpu().clone() for k, v in qat.core.state_dict().items()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "schema": "C10-HWQA-v1-c0-bnfold-qat",
        "architecture": "edgedscnet_c10_control_bn_folded_qat",
        "source_folded_checkpoint": str(args.fp32),
        "seed": args.seed, "epochs": args.epochs, "batch_size": args.batch_size,
        "lr": args.lr, "weight_decay": args.weight_decay,
        "best_epoch": best_epoch, "best_val_acc": best_val, "history": history,
        "bn": "absent; source BN already folded", "model_state": best_state,
        "quantization_contract": {
            "weights": "symmetric per-output-channel int8 fake quantization",
            "activations": "signed int8; ReLU6 [0,127], input [-128,127]",
            "accumulator": "int32 deployment contract; int64 only in reference audit",
            "rounding": "nearest-away-from-zero", "saturation": "int8",
        },
        "train_indices": tr, "validation_indices": va,
    }, args.out)
    print(json.dumps({"schema": "C10-HWQA-v1-c0-bnfold-qat", "best_epoch": best_epoch, "best_val_acc": best_val, "checkpoint": str(args.out)}, indent=2))


if __name__ == "__main__":
    main()
