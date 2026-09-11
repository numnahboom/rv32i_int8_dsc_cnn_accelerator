#!/usr/bin/env python3
"""Fold BN and train the fixed EdgeMBConv-Hybrid with deployment QAT."""
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

from edgembconv_hybrid_hwqa import EdgeMBConvHybrid, INPUT_SCALE
from resnet20_hwqa import CifarDataset, evaluate, frozen_split, load_cifar10, seed_everything


def load_state(path: Path) -> dict[str, Any]:
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


def fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    bias = bn.bias - bn.running_mean * scale
    return conv.weight * scale.reshape(-1, 1, 1, 1), bias


class FoldedFused(nn.Module):
    def __init__(self, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
        super().__init__()
        self.expand = nn.Conv2d(cin, hidden, 3, stride=stride, padding=1, bias=True)
        self.project = nn.Conv2d(hidden, cout, 1, bias=True)
        self.residual = residual

    def forward(self, x: torch.Tensor, taps: dict[str, torch.Tensor] | None = None, key: str = "") -> torch.Tensor:
        y = F.relu6(self.expand(x), inplace=False)
        if taps is not None: taps[f"{key}.expand"] = y
        y = self.project(y)
        if taps is not None: taps[f"{key}.project"] = y
        if self.residual: y = y + x
        if taps is not None: taps[f"{key}.out"] = y
        return y


class FoldedMB(nn.Module):
    def __init__(self, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
        super().__init__()
        self.expand = nn.Conv2d(cin, hidden, 1, bias=True)
        self.spatial = nn.Conv2d(hidden, hidden, 3, stride=stride, padding=1, groups=hidden, bias=True)
        self.project = nn.Conv2d(hidden, cout, 1, bias=True)
        self.residual = residual

    def forward(self, x: torch.Tensor, taps: dict[str, torch.Tensor] | None = None, key: str = "") -> torch.Tensor:
        y = F.relu6(self.expand(x), inplace=False)
        if taps is not None: taps[f"{key}.expand"] = y
        y = F.relu6(self.spatial(y), inplace=False)
        if taps is not None: taps[f"{key}.spatial"] = y
        y = self.project(y)
        if taps is not None: taps[f"{key}.project"] = y
        if self.residual: y = y + x
        if taps is not None: taps[f"{key}.out"] = y
        return y


class FoldedHybrid(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
        self.fused1 = FoldedFused(16, 32, 16, 1, True)
        self.fused2 = FoldedFused(16, 32, 32, 2, False)
        self.mb16 = nn.ModuleList([FoldedMB(32, 64, 32, 1, True), FoldedMB(32, 64, 32, 1, True)])
        self.mb8_down = FoldedMB(32, 64, 64, 2, False)
        self.mb8 = nn.ModuleList([FoldedMB(64, 128, 64, 1, True) for _ in range(3)])
        self.mb4_down = FoldedMB(64, 128, 128, 2, False)
        self.mb4 = nn.ModuleList([FoldedMB(128, 256, 128, 1, True) for _ in range(2)])
        self.head = nn.Conv2d(128, 256, 1, bias=True)
        self.fc = nn.Linear(256, 10)

    def forward(self, x: torch.Tensor, taps: dict[str, torch.Tensor] | None = None) -> torch.Tensor:
        x = F.relu6(self.stem(x), inplace=False)
        if taps is not None: taps["stem"] = x
        x = self.fused1(x, taps, "fused1")
        x = self.fused2(x, taps, "fused2")
        for i, b in enumerate(self.mb16): x = b(x, taps, f"mb16.{i + 1}")
        x = self.mb8_down(x, taps, "mb8.down")
        for i, b in enumerate(self.mb8): x = b(x, taps, f"mb8.{i + 1}")
        x = self.mb4_down(x, taps, "mb4.down")
        for i, b in enumerate(self.mb4): x = b(x, taps, f"mb4.{i + 1}")
        x = self.head(x)
        if taps is not None: taps["head"] = x
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def fold_model(src: EdgeMBConvHybrid) -> FoldedHybrid:
    out = FoldedHybrid()
    with torch.no_grad():
        out.stem.weight.copy_(src.stem[0].weight)
        # stem BN follows the dense stem and the stem ReLU6 is outside it.
        out.stem.weight.copy_(fold_conv_bn(src.stem[0], src.stem[1])[0])
        out.stem.bias.copy_(fold_conv_bn(src.stem[0], src.stem[1])[1])

        def copy_fused(dst: FoldedFused, block: nn.Module) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        def copy_mb(dst: FoldedMB, block: nn.Module) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.spatial, block.spatial_bn); dst.spatial.weight.copy_(w); dst.spatial.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        copy_fused(out.fused1, src.fused1); copy_fused(out.fused2, src.fused2)
        for d, s in zip(out.mb16, src.mb16): copy_mb(d, s)
        copy_mb(out.mb8_down, src.mb8_down)
        for d, s in zip(out.mb8, src.mb8): copy_mb(d, s)
        copy_mb(out.mb4_down, src.mb4_down)
        for d, s in zip(out.mb4, src.mb4): copy_mb(d, s)
        w, b = fold_conv_bn(src.head[0], src.head[1]); out.head.weight.copy_(w); out.head.bias.copy_(b)
        out.fc.load_state_dict(src.fc.state_dict())
    return out


def round_away_tensor(x: torch.Tensor) -> torch.Tensor:
    return torch.sign(x) * torch.floor(torch.abs(x) + 0.5)


def fake_quant(x: torch.Tensor, scale: float, qmin: int, qmax: int) -> torch.Tensor:
    s = torch.as_tensor(float(scale), dtype=x.dtype, device=x.device)
    q = torch.clamp(round_away_tensor(x / s), qmin, qmax)
    return x + (q * s - x).detach()


def fake_requant(x: torch.Tensor, in_scale: float, out_scale: float) -> torch.Tensor:
    # Inputs are already dequantized values at in_scale.  Convert through the
    # same integer common-scale path as the exporter, while preserving STE.
    si = torch.as_tensor(float(in_scale), dtype=x.dtype, device=x.device)
    so = torch.as_tensor(float(out_scale), dtype=x.dtype, device=x.device)
    qi = round_away_tensor(x / si)
    qo = round_away_tensor(qi * si / so).clamp(-128, 127)
    y = qo * so
    return x + (y - x).detach()


class QConv(nn.Module):
    def __init__(self, conv: nn.Conv2d) -> None:
        super().__init__()
        self.weight = nn.Parameter(conv.weight.detach().clone())
        self.bias = nn.Parameter(conv.bias.detach().clone())
        self.stride, self.padding, self.groups = conv.stride, conv.padding, conv.groups

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        w = self.weight
        ws = w.detach().abs().amax(dim=(1, 2, 3)).clamp_min(1e-8) / 127.0
        q = torch.clamp(round_away_tensor(w / ws.reshape(-1, 1, 1, 1)), -127, 127)
        qw = w + (q * ws.reshape(-1, 1, 1, 1) - w).detach()
        return F.conv2d(x, qw, self.bias, self.stride, self.padding, groups=self.groups)


class QFused(nn.Module):
    def __init__(self, block: FoldedFused, scales: dict[str, float], key: str) -> None:
        super().__init__(); self.expand, self.project = QConv(block.expand), QConv(block.project)
        self.residual = block.residual; self.se = scales[f"{key}.expand"]; self.sp = scales[f"{key}.project"]
        self.so = scales[f"{key}.out"]

    def forward(self, x: torch.Tensor, sx: float) -> tuple[torch.Tensor, float]:
        y = fake_quant(F.relu6(self.expand(x)), self.se, 0, 127)
        y = fake_quant(self.project(y), self.sp, -128, 127)
        if self.residual: y = fake_requant(x, sx, self.so) + fake_requant(y, self.sp, self.so)
        y = fake_quant(y, self.so, -128, 127)
        return y, self.so


class QMB(nn.Module):
    def __init__(self, block: FoldedMB, scales: dict[str, float], key: str) -> None:
        super().__init__(); self.expand, self.spatial, self.project = QConv(block.expand), QConv(block.spatial), QConv(block.project)
        self.residual = block.residual; self.se = scales[f"{key}.expand"]; self.ss = scales[f"{key}.spatial"]; self.sp = scales[f"{key}.project"]; self.so = scales[f"{key}.out"]

    def forward(self, x: torch.Tensor, sx: float) -> tuple[torch.Tensor, float]:
        y = fake_quant(F.relu6(self.expand(x)), self.se, 0, 127)
        y = fake_quant(F.relu6(self.spatial(y)), self.ss, 0, 127)
        y = fake_quant(self.project(y), self.sp, -128, 127)
        if self.residual: y = fake_requant(x, sx, self.so) + fake_requant(y, self.sp, self.so)
        y = fake_quant(y, self.so, -128, 127)
        return y, self.so


class QATHybrid(nn.Module):
    def __init__(self, folded: FoldedHybrid, scales: dict[str, float]) -> None:
        super().__init__(); self.stem = QConv(folded.stem); self.ss = scales["stem"]
        self.fused1 = QFused(folded.fused1, scales, "fused1"); self.fused2 = QFused(folded.fused2, scales, "fused2")
        self.mb16 = nn.ModuleList([QMB(b, scales, f"mb16.{i + 1}") for i, b in enumerate(folded.mb16)])
        self.mb8_down = QMB(folded.mb8_down, scales, "mb8.down")
        self.mb8 = nn.ModuleList([QMB(b, scales, f"mb8.{i + 1}") for i, b in enumerate(folded.mb8)])
        self.mb4_down = QMB(folded.mb4_down, scales, "mb4.down")
        self.mb4 = nn.ModuleList([QMB(b, scales, f"mb4.{i + 1}") for i, b in enumerate(folded.mb4)])
        self.head = QConv(folded.head); self.sh = scales["head"]; self.fc = nn.Linear(256, 10); self.fc.load_state_dict(folded.fc.state_dict())
        self.scales = scales

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = fake_quant(x, INPUT_SCALE, -128, 127)
        x = fake_quant(F.relu6(self.stem(x)), self.ss, 0, 127); sx = self.ss
        x, sx = self.fused1(x, sx); x, sx = self.fused2(x, sx)
        for b in self.mb16: x, sx = b(x, sx)
        x, sx = self.mb8_down(x, sx)
        for b in self.mb8: x, sx = b(x, sx)
        x, sx = self.mb4_down(x, sx)
        for b in self.mb4: x, sx = b(x, sx)
        x = fake_quant(self.head(x), self.sh, -128, 127); sx = self.sh
        gap = fake_quant(F.adaptive_avg_pool2d(x, 1).flatten(1), sx, -128, 127)
        w = self.fc.weight; ws = w.detach().abs().amax(dim=1).clamp_min(1e-8) / 127.0
        q = torch.clamp(round_away_tensor(w / ws[:, None]), -127, 127); qw = w + (q * ws[:, None] - w).detach()
        return F.linear(gap, qw, self.fc.bias)


@torch.no_grad()
def calibrate_scales(model: FoldedHybrid, loader: DataLoader, device: torch.device, max_batches: int = 40) -> dict[str, float]:
    model.eval(); maxima: dict[str, float] = {}
    for i, (x, _) in enumerate(loader):
        if i >= max_batches: break
        taps: dict[str, torch.Tensor] = {}; model(x.to(device), taps)
        for key, value in taps.items(): maxima[key] = max(maxima.get(key, 0.0), float(value.abs().amax().cpu()))
    return {k: max(v / 127.0, 1.0 / 127.0) for k, v in maxima.items()}


def main(args: argparse.Namespace) -> None:
    seed_everything(args.seed); device = torch.device(args.device)
    train_x, train_y = load_cifar10(args.data, "train"); tr, va = frozen_split(train_y)
    train = DataLoader(CifarDataset(train_x[tr], train_y[tr], True, args.seed + 101), batch_size=args.batch_size, shuffle=True, num_workers=0, pin_memory=True)
    valid = DataLoader(CifarDataset(train_x[va], train_y[va], False, args.seed + 102), batch_size=args.batch_size, shuffle=False, num_workers=0, pin_memory=True)
    ckpt = load_state(args.fp32); fp = EdgeMBConvHybrid(); fp.load_state_dict(ckpt["model_state"]); fp.eval()
    folded = fold_model(fp).to(device)
    cal = DataLoader(CifarDataset(train_x[tr[:5000]], train_y[tr[:5000]], False, args.seed + 201), batch_size=args.batch_size, shuffle=False, num_workers=0)
    scales = calibrate_scales(folded, cal, device, args.calibration_batches)
    model = QATHybrid(folded.cpu(), scales).to(device)
    opt = torch.optim.SGD(model.parameters(), lr=args.lr, momentum=0.9, weight_decay=args.weight_decay, nesterov=True)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    history: list[dict[str, float]] = []; best_val = -1.0; best_epoch = 0; best_state: dict[str, torch.Tensor] | None = None
    for epoch in range(args.epochs):
        train.dataset.epoch = epoch; model.train(); seen = correct = 0; loss_sum = 0.0
        for x, y in train:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True); opt.zero_grad(set_to_none=True)
            logits = model(x); loss = F.cross_entropy(logits, y); loss.backward(); opt.step()
            loss_sum += float(loss.detach()) * y.numel(); correct += int((logits.argmax(1) == y).sum()); seen += y.numel()
        sched.step(); vl, va = evaluate(model, valid, device)
        row = {"epoch": epoch + 1, "lr": opt.param_groups[0]["lr"], "train_loss": loss_sum / max(1, seen), "train_acc": correct / max(1, seen), "val_loss": vl, "val_acc": va}; history.append(row); print(json.dumps(row), flush=True)
        if va > best_val:
            best_val, best_epoch = va, epoch + 1; best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    if best_state is None: best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"schema": "C10-HWQA-v1-edgembconv-hybrid-qat", "architecture": "EdgeMBConv-Hybrid", "seed": args.seed, "epochs": args.epochs, "best_epoch": best_epoch, "best_val_acc": best_val, "history": history, "scales": scales, "input_scale": INPUT_SCALE, "model_state": best_state, "train_indices": tr, "validation_indices": va}, args.out)
    print(json.dumps({"best_epoch": best_epoch, "best_val_acc": best_val})); print(f"wrote {args.out}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__); p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data")); p.add_argument("--fp32", type=Path, default=Path("build/model/edgembconv_hybrid_hwqa_fp32.pt")); p.add_argument("--out", type=Path, default=Path("build/model/edgembconv_hybrid_hwqa_qat.pt")); p.add_argument("--epochs", type=int, default=30); p.add_argument("--batch-size", type=int, default=256); p.add_argument("--lr", type=float, default=0.001); p.add_argument("--weight-decay", type=float, default=1e-5); p.add_argument("--calibration-batches", type=int, default=40); p.add_argument("--seed", type=int, default=20260901); p.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu"); return p.parse_args()


if __name__ == "__main__": main(parse_args())
