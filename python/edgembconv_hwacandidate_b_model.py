#!/usr/bin/env python3
"""Independent software model for locked EdgeMBConv HW candidate B.

Candidate B is the frozen minimum ablation in which only the 32x32 residual
fused block from candidate A is replaced by an MBConv.  The graph, folded
graph, and deployment-QAT graph live under this module so B checkpoints and
exports cannot accidentally be accepted as candidate A artifacts.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F

# These are primitive implementations only; no A model or A checkpoint is
# imported.  Sharing the small numerical helpers keeps the hardware contract
# identical while the B graph and all B artifacts remain independently named.
from edgembconv_hwacandidate_a_model import (
    INPUT_SCALE,
    CandidateFusedBlock,
    CandidateMBConv,
    CandidateQConv,
    CandidateQFused,
    CandidateQMB,
    FoldedFused,
    FoldedMB,
    fake_quant,
    fake_requant,
    fold_conv_bn,
    round_away_tensor,
)


LOCKED_PARAMS = 276_346
LOCKED_MACS = 13_312_512
LOCKED_DENSE_MACS = 1_622_016
LOCKED_PW_MACS = 10_747_904
LOCKED_DW_MACS = 940_032
PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = PROJECT_ROOT / "build" / "edgembconv_hwacandidate" / "profile_B.json"
MANIFEST_PATH = PROJECT_ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_manifest.json"


def assert_locked_profile(
    profile_path: Path = PROFILE_PATH, manifest_path: Path = MANIFEST_PATH
) -> dict[str, Any]:
    """Refuse execution unless the frozen B arithmetic is exactly intact."""
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    if profile.get("variant_id") != "B":
        raise RuntimeError(f"locked profile is not variant B: {profile_path}")
    expected = {
        "parameter_count": LOCKED_PARAMS,
        "semantic_macs": LOCKED_MACS,
        "dense3x3": LOCKED_DENSE_MACS,
        "pw1x1": LOCKED_PW_MACS,
        "dw3x3": LOCKED_DW_MACS,
    }
    category_macs = {
        str(row.get("kind")): int(row.get("mac", -1))
        for row in profile.get("operator_mac_categories", [])
    }
    got = {
        "parameter_count": int(profile.get("parameter_count", -1)),
        "semantic_macs": int(profile.get("semantic_macs", -1)),
        "dense3x3": category_macs.get("dense3x3", -1),
        "pw1x1": category_macs.get("pw1x1", -1),
        "dw3x3": category_macs.get("dw3x3", -1),
    }
    if got != expected:
        raise RuntimeError(f"B frozen profile guard failed: got={got}, expected={expected}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    variants = {str(v.get("variant_id")): v for v in manifest.get("variants", [])}
    if "B" not in variants:
        raise RuntimeError("locked candidate manifest has no B variant")
    b = variants["B"]
    # The generator puts the profile totals at the variant top level.  Check
    # those exact values as well, so a stale profile cannot authorize training.
    for key, value in (("parameter_count", LOCKED_PARAMS), ("semantic_macs", LOCKED_MACS)):
        if int(b.get(key, -1)) != value:
            raise RuntimeError(f"candidate manifest B {key} disagrees with frozen guard")
    return profile


class EdgeMBConvCandidateB(nn.Module):
    """B_mb32_replaces_fused32, exactly matching profile_B.json."""

    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Sequential(nn.Conv2d(3, 16, 3, padding=1, bias=False), nn.BatchNorm2d(16))
        # The only graph change from A: fused32.residual -> MBConv(16,32,16).
        self.mb32 = CandidateMBConv(16, 32, 16, 1, True)
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
        x = self.mb32(x)
        x = self.fused2(x)
        x = self.mb16(x)
        x = self.mb8_down(x)
        x = self.mb8(x)
        x = self.mb4_down(x)
        x = self.mb4(x)
        x = self.head[1](self.head[0](x))
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


class FoldedCandidateB(nn.Module):
    """BatchNorm-folded B graph used by calibration and integer export."""

    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
        self.mb32 = FoldedMB(16, 32, 16, 1, True)
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
        if taps is not None:
            taps["stem"] = x
        x = self.mb32(x, taps, "mb32")
        x = self.fused2(x, taps, "fused2")
        for i, block in enumerate(self.mb16, 1):
            x = block(x, taps, f"mb16.{i}")
        x = self.mb8_down(x, taps, "mb8.down")
        for i, block in enumerate(self.mb8, 1):
            x = block(x, taps, f"mb8.{i}")
        x = self.mb4_down(x, taps, "mb4.down")
        for i, block in enumerate(self.mb4, 1):
            x = block(x, taps, f"mb4.{i}")
        x = self.head(x)
        if taps is not None:
            taps["head"] = x
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


def fold_candidate_b(src: EdgeMBConvCandidateB) -> FoldedCandidateB:
    out = FoldedCandidateB()
    with torch.no_grad():
        w, b = fold_conv_bn(src.stem[0], src.stem[1]); out.stem.weight.copy_(w); out.stem.bias.copy_(b)

        def fused(dst: FoldedFused, block: CandidateFusedBlock) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        def mb(dst: FoldedMB, block: CandidateMBConv) -> None:
            w, b = fold_conv_bn(block.expand, block.expand_bn); dst.expand.weight.copy_(w); dst.expand.bias.copy_(b)
            w, b = fold_conv_bn(block.spatial, block.spatial_bn); dst.spatial.weight.copy_(w); dst.spatial.bias.copy_(b)
            w, b = fold_conv_bn(block.project, block.project_bn); dst.project.weight.copy_(w); dst.project.bias.copy_(b)

        mb(out.mb32, src.mb32); fused(out.fused2, src.fused2)
        for d, s in zip(out.mb16, src.mb16): mb(d, s)
        mb(out.mb8_down, src.mb8_down)
        for d, s in zip(out.mb8, src.mb8): mb(d, s)
        mb(out.mb4_down, src.mb4_down)
        for d, s in zip(out.mb4, src.mb4): mb(d, s)
        w, b = fold_conv_bn(src.head[0], src.head[1]); out.head.weight.copy_(w); out.head.bias.copy_(b)
        out.fc.load_state_dict(src.fc.state_dict())
    return out


class CandidateQATB(nn.Module):
    """Deployment fake-QAT graph with B-specific module names and scales."""

    def __init__(self, folded: FoldedCandidateB, scales: dict[str, float]) -> None:
        super().__init__()
        self.stem, self.ss = CandidateQConv(folded.stem), scales["stem"]
        self.mb32 = CandidateQMB(folded.mb32, scales, "mb32")
        self.fused2 = CandidateQFused(folded.fused2, scales, "fused2")
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
        x, sx = self.mb32(x, sx); x, sx = self.fused2(x, sx)
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
