#!/usr/bin/env python3
"""30-epoch deployment-QAT stage for frozen EdgeMBConv candidate D4."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from edgembconv_hwacandidate_d4_model import (
    CandidateQATD4,
    EdgeMBConvCandidateD4,
    assert_locked_profile,
    fold_candidate_d4,
)
from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = ROOT / "build" / "edgembconv_hwacandidate_d4"
DEFAULT_FP32 = DEFAULT_ROOT / "edgembconv_hwacandidate_d4_fp32.pt"
DEFAULT_OUT = DEFAULT_ROOT / "edgembconv_hwacandidate_d4_qat.pt"
DEFAULT_CURVE = DEFAULT_ROOT / "edgembconv_hwacandidate_d4_qat_learning_curve.json"


def load_state(path: Path) -> dict[str, Any]:
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


@torch.no_grad()
def calibrate_scales(model: torch.nn.Module, loader: DataLoader,
                     device: torch.device, max_batches: int) -> dict[str, float]:
    model.eval(); maxima: dict[str, float] = {}
    for batch_index, (x, _) in enumerate(loader):
        if batch_index >= max_batches:
            break
        taps: dict[str, torch.Tensor] = {}
        model(x.to(device), taps)
        for key, value in taps.items():
            maxima[key] = max(maxima.get(key, 0.0), float(value.detach().abs().amax().cpu()))
    return {key: max(value / 127.0, 1.0 / 127.0) for key, value in maxima.items()}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--fp32", type=Path, default=DEFAULT_FP32)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--curve", type=Path, default=DEFAULT_CURVE)
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.001)
    p.add_argument("--weight-decay", type=float, default=1e-5)
    p.add_argument("--calibration-batches", type=int, default=40)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return p.parse_args()


def main(args: argparse.Namespace) -> None:
    profile = assert_locked_profile()
    if not args.fp32.exists():
        raise FileNotFoundError(f"candidate D4 FP32 checkpoint required: {args.fp32}")
    seed_everything(args.seed); device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train"); tr, va = frozen_split(train_y)
    if tr.size != 45_000 or va.size != 5_000:
        raise RuntimeError(f"unexpected fixed split sizes: {tr.size}/{va.size}")
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, args.seed + 101),
                       batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, args.seed + 102),
                       batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    ckpt = load_state(args.fp32); old_profile = ckpt.get("profile", {})
    if (old_profile.get("variant_id") not in (None, "D4") or
            int(old_profile.get("parameter_count", -1)) != int(profile["parameter_count"]) or
            int(old_profile.get("semantic_macs", -1)) != int(profile["semantic_macs"])):
        raise RuntimeError("FP32 checkpoint is not locked candidate D4")
    fp = EdgeMBConvCandidateD4(); fp.load_state_dict(ckpt["model_state"]); fp.eval()
    folded = fold_candidate_d4(fp).to(device)
    cal = DataLoader(CifarDataset(train_x[tr[:5000]], train_y[tr[:5000]], False, args.seed + 201),
                     batch_size=args.batch_size, shuffle=False, num_workers=0)
    scales = calibrate_scales(folded, cal, device, args.calibration_batches)
    expected_keys = [
        "stem", "mb32.expand", "mb32.spatial", "mb32.project", "mb32.out",
        "mb16_down.expand", "mb16_down.spatial", "mb16_down.project", "mb16_down.out",
        "head",
    ]
    expected_keys += [f"mb16.{i}.{part}" for i in (1, 2) for part in ("expand", "spatial", "project", "out")]
    expected_keys += [f"mb8.{i}.{part}" for i in ("down",) for part in ("expand", "spatial", "project", "out")]
    expected_keys += [f"mb8.{i}.{part}" for i in (1, 2, 3) for part in ("expand", "spatial", "project", "out")]
    expected_keys += [f"mb4.{i}.{part}" for i in ("down",) for part in ("expand", "spatial", "project", "out")]
    expected_keys += [f"mb4.1.{part}" for part in ("expand", "spatial", "project", "out")]
    missing = sorted(set(expected_keys) - set(scales))
    if missing:
        raise RuntimeError(f"incomplete activation calibration; missing {missing}")
    model = CandidateQATD4(folded.cpu(), scales).to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9,
                          weight_decay=args.weight_decay, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []; best_val, best_epoch = -1.0, 0
    best_state: dict[str, torch.Tensor] | None = None
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch; model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad(set_to_none=True); logits = model(x); loss = F.cross_entropy(logits, y)
            loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel()
            correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step(); val_loss, val_acc = evaluate(model, valid, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"],
               "train_loss": loss_sum / max(1, seen), "train_acc": correct / max(1, seen),
               "val_loss": val_loss, "val_acc": val_acc}
        history.append(row); print(json.dumps(row), flush=True)
        if val_acc > best_val:
            best_val, best_epoch = val_acc, epoch + 1
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        args.curve.parent.mkdir(parents=True, exist_ok=True)
        args.curve.write_text(json.dumps({"schema": "C10-HWQA-v1", "stage": "D4-qat",
                                          "profile": profile, "scales": scales,
                                          "history": history}, indent=2) + "\n", encoding="utf-8")
    if best_state is None:
        best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-qat",
        "architecture": "D4_C_minus_one_mb4", "profile": profile,
        "seed": args.seed, "epochs": args.epochs, "batch_size": args.batch_size,
        "lr": args.lr, "weight_decay": args.weight_decay, "best_epoch": best_epoch,
        "best_val_acc": best_val, "history": history, "scales": scales,
        "input_scale": 1.0 / 127.5, "bn": "folded_before_QAT", "model_state": best_state,
        "train_indices": tr, "validation_indices": va,
        "quantization_contract": {
            "weights": "symmetric per-output-channel int8",
            "activations": "signed int8; ReLU6 [0,127], linear/residual [-128,127]",
            "accumulator": "int32; evaluator checks with int64",
            "rounding": "nearest-away-from-zero", "saturation": "int8",
        },
    }, args.out)
    print(json.dumps({"stage": "D4-qat", "best_epoch": best_epoch,
                      "best_val_acc": best_val}, indent=2))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main(parse_args())
