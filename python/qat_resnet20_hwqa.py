#!/usr/bin/env python3
"""Fold BatchNorm, run activation/weight fake-quant QAT, and save deploy state."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader

from resnet20_hwqa import (
    CifarDataset,
    INPUT_SCALE,
    ResNet20,
    evaluate,
    frozen_split,
    load_cifar10,
    seed_everything,
)


class FoldedBlock(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=True)
        self.conv2 = nn.Conv2d(cout, cout, 3, padding=1, bias=True)
        self.proj = nn.Conv2d(cin, cout, 1, stride=stride, bias=True) if (stride != 1 or cin != cout) else None

    def forward(self, x: torch.Tensor, taps: dict[str, torch.Tensor] | None = None, key: str = "") -> torch.Tensor:
        y = F.relu(self.conv1(x))
        if taps is not None: taps[f"{key}.c1"] = y
        y = self.conv2(y)
        if taps is not None: taps[f"{key}.c2"] = y
        identity = self.proj(x) if self.proj is not None else x
        if taps is not None and self.proj is not None: taps[f"{key}.skip"] = identity
        out = F.relu(y + identity)
        if taps is not None: taps[f"{key}.out"] = out
        return out


class FoldedResNet20(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
        self.blocks = nn.ModuleList([
            FoldedBlock(16, 16, 1), FoldedBlock(16, 16, 1), FoldedBlock(16, 16, 1),
            FoldedBlock(16, 32, 2), FoldedBlock(32, 32, 1), FoldedBlock(32, 32, 1),
            FoldedBlock(32, 64, 2), FoldedBlock(64, 64, 1), FoldedBlock(64, 64, 1),
        ])
        self.fc = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor, taps: dict[str, torch.Tensor] | None = None) -> torch.Tensor:
        x = F.relu(self.stem(x))
        if taps is not None: taps["stem"] = x
        for i, block in enumerate(self.blocks, 1):
            x = block(x, taps, f"b{i}")
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    bias = bn.bias - bn.running_mean * scale
    if conv.bias is not None: bias = bias + conv.bias * scale
    return conv.weight * scale.reshape(-1, 1, 1, 1), bias


def fold_model(model: ResNet20) -> FoldedResNet20:
    out = FoldedResNet20()
    with torch.no_grad():
        w, b = fold_conv_bn(model.stem[0], model.stem[1]); out.stem.weight.copy_(w); out.stem.bias.copy_(b)
        for i, src in enumerate(list(model.stage1) + list(model.stage2) + list(model.stage3)):
            dst = out.blocks[i]
            w, b = fold_conv_bn(src.conv1, src.bn1); dst.conv1.weight.copy_(w); dst.conv1.bias.copy_(b)
            w, b = fold_conv_bn(src.conv2, src.bn2); dst.conv2.weight.copy_(w); dst.conv2.bias.copy_(b)
            if src.proj is not None and src.proj_bn is not None and dst.proj is not None:
                w, b = fold_conv_bn(src.proj, src.proj_bn); dst.proj.weight.copy_(w); dst.proj.bias.copy_(b)
        out.fc.load_state_dict(model.fc.state_dict())
    return out


@torch.no_grad()
def calibrate_scales(model: FoldedResNet20, loader: DataLoader, device: torch.device, max_batches: int = 40) -> dict[str, float]:
    model.eval(); maxima: dict[str, float] = {}
    for bi, (x, _) in enumerate(loader):
        if bi >= max_batches: break
        taps: dict[str, torch.Tensor] = {}
        model(x.to(device), taps)
        for key, value in taps.items():
            # Max calibration avoids clipping in the first deploy artifact.
            current = float(value.detach().abs().amax().cpu())
            maxima[key] = max(maxima.get(key, 0.0), current)
    scales = {k: max(v / 127.0, 1.0 / 127.0) for k, v in maxima.items()}
    return scales


def fq(x: torch.Tensor, scale: float, qmin: int, qmax: int) -> torch.Tensor:
    s = torch.tensor(float(scale), dtype=x.dtype, device=x.device)
    # Match the deployment golden model's explicit nearest-away-from-zero rule.
    q = torch.sign(x) * torch.floor(torch.abs(x) / s + 0.5)
    q = torch.clamp(q, qmin, qmax)
    return x + (q * s - x).detach()


class QConv(nn.Module):
    def __init__(self, conv: nn.Conv2d) -> None:
        super().__init__()
        self.weight = nn.Parameter(conv.weight.detach().clone())
        self.bias = nn.Parameter(conv.bias.detach().clone())
        self.stride, self.padding = conv.stride, conv.padding

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        w = self.weight
        ws = w.detach().abs().amax(dim=(1, 2, 3)).clamp_min(1e-8) / 127.0
        q = torch.sign(w / ws.reshape(-1, 1, 1, 1)) * torch.floor(torch.abs(w / ws.reshape(-1, 1, 1, 1)) + 0.5)
        qw = w + (torch.clamp(q, -127, 127) * ws.reshape(-1, 1, 1, 1) - w).detach()
        return F.conv2d(x, qw, self.bias, self.stride, self.padding)


class QBlock(nn.Module):
    def __init__(self, block: FoldedBlock, scales: dict[str, float], key: str) -> None:
        super().__init__()
        self.conv1, self.conv2 = QConv(block.conv1), QConv(block.conv2)
        self.proj = QConv(block.proj) if block.proj is not None else None
        self.s1, self.s2, self.sout = scales[f"{key}.c1"], scales[f"{key}.c2"], scales[f"{key}.out"]
        self.sskip = scales.get(f"{key}.skip", self.sout)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = fq(F.relu(self.conv1(x)), self.s1, 0, 127)
        y = fq(self.conv2(y), self.s2, -128, 127)
        skip = fq(self.proj(x), self.sskip, -128, 127) if self.proj is not None else x
        return fq(F.relu(y + skip), self.sout, 0, 127)


class QATResNet20(nn.Module):
    def __init__(self, folded: FoldedResNet20, scales: dict[str, float]) -> None:
        super().__init__()
        self.stem = QConv(folded.stem)
        self.stem_scale = float(scales["stem"])
        self.blocks = nn.ModuleList([QBlock(b, scales, f"b{i}") for i, b in enumerate(folded.blocks, 1)])
        self.fc = nn.Linear(64, 10)
        self.fc.load_state_dict(folded.fc.state_dict())

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = fq(x, INPUT_SCALE, -128, 127)
        x = fq(F.relu(self.stem(x)), self.stem_scale, 0, 127)
        for b in self.blocks: x = b(x)
        gap = fq(F.adaptive_avg_pool2d(x, 1).flatten(1), self.blocks[-1].sout, 0, 127)
        w = self.fc.weight
        ws = w.detach().abs().amax(dim=1).clamp_min(1e-8) / 127.0
        q = torch.sign(w / ws[:, None]) * torch.floor(torch.abs(w / ws[:, None]) + 0.5)
        qw = w + (torch.clamp(q, -127, 127) * ws[:, None] - w).detach()
        return F.linear(gap, qw, self.fc.bias)


def train_qat(args: argparse.Namespace) -> None:
    seed_everything(args.seed)
    device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train")
    tr, va = frozen_split(train_y)
    train_loader = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, args.seed + 19), batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True)
    val_loader = DataLoader(CifarDataset(train_x[va], train_y[va], False, args.seed + 20), batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    ckpt = torch.load(args.fp32, map_location="cpu", weights_only=False)
    fp = ResNet20(); fp.load_state_dict(ckpt["model_state"]); fp.eval()
    folded = fold_model(fp)
    cal_loader = DataLoader(CifarDataset(train_x[tr[:5000]], train_y[tr[:5000]], False, args.seed + 21), batch_size=args.batch_size, shuffle=False, num_workers=0)
    scales = calibrate_scales(folded.to(device), cal_loader, device)
    model = QATResNet20(folded, scales).to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=1e-5, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []
    for epoch in range(args.epochs):
        train_loader.dataset.epoch = epoch
        model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train_loader:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            opt.zero_grad(set_to_none=True); logits = model(x); loss = F.cross_entropy(logits, y)
            loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel(); correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step(); vl, va_acc = evaluate(model, val_loader, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / seen, "train_acc": correct / seen, "val_loss": vl, "val_acc": va_acc}
        history.append(row); print(json.dumps(row), flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    # Store only folded float parameters plus QAT metadata; exporter owns integer encoding.
    torch.save({"schema": "C10-HWQA-v1-resnet20-qat", "architecture": "resnet20", "seed": args.seed, "epochs": args.epochs, "history": history, "scales": scales, "input_scale": INPUT_SCALE, "model_state": model.state_dict(), "train_indices": tr, "validation_indices": va}, args.out)
    print(f"wrote {args.out}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--fp32", type=Path, default=Path("build/model/resnet20_hwqa_fp32.pt"))
    p.add_argument("--out", type=Path, default=Path("build/model/resnet20_hwqa_qat.pt"))
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--lr", type=float, default=0.01)
    p.add_argument("--seed", type=int, default=20260901)
    p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    return p.parse_args()


if __name__ == "__main__":
    train_qat(parse_args())
