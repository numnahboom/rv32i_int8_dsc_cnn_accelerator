#!/usr/bin/env python3
"""Independent software model for locked EdgeMBConv HW candidate A.

The candidate is deliberately kept separate from C0 and from the earlier
exploratory ``edgembconv_hybrid_hwqa`` artifacts.  This module contains the
same frozen A graph as the static profile, plus the folded and fake-quantized
forms used by the candidate-only training/QAT/export scripts.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F


INPUT_SCALE = 1.0 / 127.5
LOCKED_PARAMS = 280_122
LOCKED_MACS = 17_211_904
PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = PROJECT_ROOT / "build" / "edgembconv_hwacandidate" / "profile_A.json"
MANIFEST_PATH = PROJECT_ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_manifest.json"


def assert_locked_profile(profile_path: Path = PROFILE_PATH, manifest_path: Path = MANIFEST_PATH) -> dict[str, Any]:
    """Refuse execution unless the independently generated A profile is intact."""
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    if profile.get("variant_id") != "A":
        raise RuntimeError(f"locked profile is not variant A: {profile_path}")
    if int(profile.get("parameter_count", -1)) != LOCKED_PARAMS:
        raise RuntimeError(
            f"A parameter mismatch: {profile.get('parameter_count')} != {LOCKED_PARAMS}"
        )
    if int(profile.get("semantic_macs", -1)) != LOCKED_MACS:
        raise RuntimeError(f"A MAC mismatch: {profile.get('semantic_macs')} != {LOCKED_MACS}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    variants = {str(v.get("variant_id")): v for v in manifest.get("variants", [])}
    if "A" not in variants:
        raise RuntimeError("locked candidate manifest has no A variant")
    if int(variants["A"].get("parameter_count", -1)) != LOCKED_PARAMS or int(variants["A"].get("semantic_macs", -1)) != LOCKED_MACS:
        raise RuntimeError("candidate manifest A disagrees with the locked profile")
    return profile


class CandidateFusedBlock(nn.Module):
    def __init__(self, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
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


class CandidateMBConv(nn.Module):
    def __init__(self, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
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


class EdgeMBConvCandidateA(nn.Module):
    """A_current_edgembconv_hybrid, exactly matching profile_A.json."""
    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Sequential(nn.Conv2d(3, 16, 3, padding=1, bias=False), nn.BatchNorm2d(16))
        self.fused1 = CandidateFusedBlock(16, 32, 16, 1, True)
        self.fused2 = CandidateFusedBlock(16, 32, 32, 2, False)
        self.mb16 = nn.Sequential(CandidateMBConv(32, 64, 32, 1, True), CandidateMBConv(32, 64, 32, 1, True))
        self.mb8_down = CandidateMBConv(32, 64, 64, 2, False)
        self.mb8 = nn.Sequential(
            CandidateMBConv(64, 128, 64, 1, True),
            CandidateMBConv(64, 128, 64, 1, True),
            CandidateMBConv(64, 128, 64, 1, True),
        )
        self.mb4_down = CandidateMBConv(64, 128, 128, 2, False)
        self.mb4 = nn.Sequential(CandidateMBConv(128, 256, 128, 1, True), CandidateMBConv(128, 256, 128, 1, True))
        self.head = nn.Sequential(nn.Conv2d(128, 256, 1, bias=False), nn.BatchNorm2d(256))
        self.fc = nn.Linear(256, 10)

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


class FoldedFused(nn.Module):
    def __init__(self, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
        super().__init__()
        self.expand = nn.Conv2d(cin, hidden, 3, stride=stride, padding=1, bias=True)
        self.project = nn.Conv2d(hidden, cout, 1, bias=True)
        self.residual = bool(residual)

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
        self.residual = bool(residual)

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


class FoldedCandidateA(nn.Module):
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
        for i, block in enumerate(self.mb16, 1): x = block(x, taps, f"mb16.{i}")
        x = self.mb8_down(x, taps, "mb8.down")
        for i, block in enumerate(self.mb8, 1): x = block(x, taps, f"mb8.{i}")
        x = self.mb4_down(x, taps, "mb4.down")
        for i, block in enumerate(self.mb4, 1): x = block(x, taps, f"mb4.{i}")
        x = self.head(x)
        if taps is not None: taps["head"] = x
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    bias = bn.bias - bn.running_mean * scale
    return conv.weight * scale.reshape(-1, 1, 1, 1), bias


def fold_candidate_a(src: EdgeMBConvCandidateA) -> FoldedCandidateA:
    out = FoldedCandidateA()
    with torch.no_grad():
        w, b = fold_conv_bn(src.stem[0], src.stem[1]); out.stem.weight.copy_(w); out.stem.bias.copy_(b)

        def fused(dst: FoldedFused, block: CandidateFusedBlock) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        def mb(dst: FoldedMB, block: CandidateMBConv) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.spatial, block.spatial_bn); dst.spatial.weight.copy_(w); dst.spatial.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        fused(out.fused1, src.fused1); fused(out.fused2, src.fused2)
        for d, s in zip(out.mb16, src.mb16): mb(d, s)
        mb(out.mb8_down, src.mb8_down)
        for d, s in zip(out.mb8, src.mb8): mb(d, s)
        mb(out.mb4_down, src.mb4_down)
        for d, s in zip(out.mb4, src.mb4): mb(d, s)
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
    si = torch.as_tensor(float(in_scale), dtype=x.dtype, device=x.device)
    so = torch.as_tensor(float(out_scale), dtype=x.dtype, device=x.device)
    qi = round_away_tensor(x / si)
    qo = round_away_tensor(qi * si / so).clamp(-128, 127)
    y = qo * so
    return x + (y - x).detach()


class CandidateQConv(nn.Module):
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


class CandidateQFused(nn.Module):
    def __init__(self, block: FoldedFused, scales: dict[str, float], key: str) -> None:
        super().__init__()
        self.expand, self.project = CandidateQConv(block.expand), CandidateQConv(block.project)
        self.residual = block.residual
        self.se, self.sp, self.so = scales[f"{key}.expand"], scales[f"{key}.project"], scales[f"{key}.out"]

    def forward(self, x: torch.Tensor, sx: float) -> tuple[torch.Tensor, float]:
        y = fake_quant(F.relu6(self.expand(x)), self.se, 0, 127)
        y = fake_quant(self.project(y), self.sp, -128, 127)
        if self.residual:
            y = fake_requant(x, sx, self.so) + fake_requant(y, self.sp, self.so)
        y = fake_quant(y, self.so, -128, 127)
        return y, self.so


class CandidateQMB(nn.Module):
    def __init__(self, block: FoldedMB, scales: dict[str, float], key: str) -> None:
        super().__init__()
        self.expand, self.spatial, self.project = CandidateQConv(block.expand), CandidateQConv(block.spatial), CandidateQConv(block.project)
        self.residual = block.residual
        self.se, self.ss, self.sp, self.so = scales[f"{key}.expand"], scales[f"{key}.spatial"], scales[f"{key}.project"], scales[f"{key}.out"]

    def forward(self, x: torch.Tensor, sx: float) -> tuple[torch.Tensor, float]:
        y = fake_quant(F.relu6(self.expand(x)), self.se, 0, 127)
        y = fake_quant(F.relu6(self.spatial(y)), self.ss, 0, 127)
        y = fake_quant(self.project(y), self.sp, -128, 127)
        if self.residual:
            y = fake_requant(x, sx, self.so) + fake_requant(y, self.sp, self.so)
        y = fake_quant(y, self.so, -128, 127)
        return y, self.so


class CandidateQAT(nn.Module):
    def __init__(self, folded: FoldedCandidateA, scales: dict[str, float]) -> None:
        super().__init__()
        self.stem, self.ss = CandidateQConv(folded.stem), scales["stem"]
        self.fused1, self.fused2 = CandidateQFused(folded.fused1, scales, "fused1"), CandidateQFused(folded.fused2, scales, "fused2")
        self.mb16 = nn.ModuleList([CandidateQMB(b, scales, f"mb16.{i + 1}") for i, b in enumerate(folded.mb16)])
        self.mb8_down = CandidateQMB(folded.mb8_down, scales, "mb8.down")
        self.mb8 = nn.ModuleList([CandidateQMB(b, scales, f"mb8.{i + 1}") for i, b in enumerate(folded.mb8)])
        self.mb4_down = CandidateQMB(folded.mb4_down, scales, "mb4.down")
        self.mb4 = nn.ModuleList([CandidateQMB(b, scales, f"mb4.{i + 1}") for i, b in enumerate(folded.mb4)])
        self.head, self.sh = CandidateQConv(folded.head), scales["head"]
        self.fc = nn.Linear(256, 10); self.fc.load_state_dict(folded.fc.state_dict())
        self.scales = {k: float(v) for k, v in scales.items()}

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
