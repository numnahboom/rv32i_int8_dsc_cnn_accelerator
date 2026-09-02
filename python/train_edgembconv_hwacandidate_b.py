#!/usr/bin/env python3
"""Train the locked EdgeMBConv hardware candidate B under C10-HWQA-v1.

All outputs are B-specific.  The official test set is evaluated only after
the 200-epoch fixed-train/fixed-validation run has selected its best state.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from edgembconv_hwacandidate_b_model import EdgeMBConvCandidateB, assert_locked_profile
from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = ROOT / "build" / "edgembconv_hwacandidate_b"
DEFAULT_OUT = DEFAULT_ROOT / "edgembconv_hwacandidate_b_fp32.pt"
DEFAULT_LAST = DEFAULT_ROOT / "edgembconv_hwacandidate_b_fp32_last.pt"
DEFAULT_CURVE = DEFAULT_ROOT / "edgembconv_hwacandidate_b_fp32_learning_curve.json"


def load_state(path: Path) -> dict[str, Any]:
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


def save_checkpoint(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(payload, tmp)
    tmp.replace(path)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--last", type=Path, default=DEFAULT_LAST)
    p.add_argument("--curve", type=Path, default=DEFAULT_CURVE)
    p.add_argument("--epochs", type=int, default=200)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.1)
    p.add_argument("--weight-decay", type=float, default=5e-4)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    p.add_argument("--resume", action="store_true", help="resume B from --last if present")
    return p.parse_args()


def main(args: argparse.Namespace) -> None:
    profile = assert_locked_profile()
    seed_everything(args.seed)
    device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train")
    tr, va = frozen_split(train_y)
    if tr.size != 45_000 or va.size != 5_000:
        raise RuntimeError(f"unexpected fixed split sizes: {tr.size}/{va.size}")
    train = DataLoader(
        CifarDataset(train_x[tr], train_y[tr], True, args.seed + 101),
        batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True,
    )
    valid = DataLoader(
        CifarDataset(train_x[va], train_y[va], False, args.seed + 102),
        batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True,
    )
    model = EdgeMBConvCandidateB().to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=args.weight_decay, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []
    best_val, best_epoch = -1.0, 0
    best_state: dict[str, torch.Tensor] | None = None
    start_epoch = 0
    if args.resume and args.last.exists():
        old = load_state(args.last)
        old_profile = old.get("profile", {})
        if int(old_profile.get("parameter_count", -1)) != int(profile["parameter_count"]) or int(old_profile.get("semantic_macs", -1)) != int(profile["semantic_macs"]):
            raise RuntimeError("resume checkpoint is not locked candidate B")
        model.load_state_dict(old["model_state"])
        if old.get("optimizer_state"): opt.load_state_dict(old["optimizer_state"])
        if old.get("scheduler_state"): sched.load_state_dict(old["scheduler_state"])
        history = list(old.get("history", [])); start_epoch = int(old.get("epoch", 0))
        best_val = float(old.get("best_val_acc", -1.0)); best_epoch = int(old.get("best_epoch", 0))
        if old.get("best_state") is not None: best_state = old["best_state"]

    for epoch in range(start_epoch, args.epochs):
        train.dataset.epoch = epoch
        model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad(set_to_none=True)
            logits = model(x); loss = F.cross_entropy(logits, y)
            loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel(); correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step()
        val_loss, val_acc = evaluate(model, valid, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / max(1, seen), "train_acc": correct / max(1, seen), "val_loss": val_loss, "val_acc": val_acc}
        history.append(row); print(json.dumps(row), flush=True)
        if val_acc > best_val:
            best_val, best_epoch = val_acc, epoch + 1
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        save_checkpoint(args.last, {
            "schema": "C10-HWQA-v1-edgembconv-hwacandidate-B-fp32-last",
            "architecture": "B_mb32_replaces_fused32", "profile": profile,
            "seed": args.seed, "epochs": args.epochs, "epoch": epoch + 1,
            "batch_size": args.batch_size, "lr": args.lr, "weight_decay": args.weight_decay,
            "history": history, "best_epoch": best_epoch, "best_val_acc": best_val,
            "best_state": best_state, "model_state": {k: v.detach().cpu() for k, v in model.state_dict().items()},
            "optimizer_state": opt.state_dict(), "scheduler_state": sched.state_dict(),
            "train_indices": tr, "validation_indices": va,
        })
        args.curve.parent.mkdir(parents=True, exist_ok=True)
        args.curve.write_text(json.dumps({"schema": "C10-HWQA-v1", "stage": "B-fp32", "profile": profile, "history": history}, indent=2) + "\n", encoding="utf-8")

    if best_state is None:
        best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state); model.to(torch.device("cpu")); model.eval()
    test_x, test_y = load_cifar10(args.data, "test")
    test = DataLoader(CifarDataset(test_x, test_y, False, args.seed + 103), batch_size=args.batch_size, shuffle=False, num_workers=0)
    test_loss, test_acc = evaluate(model, test, torch.device("cpu"))
    save_checkpoint(args.out, {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-B-fp32",
        "architecture": "B_mb32_replaces_fused32", "profile": profile,
        "seed": args.seed, "epochs": args.epochs, "batch_size": args.batch_size,
        "lr": args.lr, "weight_decay": args.weight_decay, "history": history,
        "best_epoch": best_epoch, "best_val_acc": best_val,
        "test10k_loss": test_loss, "test10k_top1": test_acc,
        "model_state": best_state, "train_indices": tr, "validation_indices": va,
    })
    print(json.dumps({"stage": "B-fp32", "best_epoch": best_epoch, "best_val_acc": best_val, "test10k_top1": test_acc}, indent=2))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main(parse_args())
