#!/usr/bin/env python3
"""Independent C0 BatchNorm-training model and exact folding utilities.

The deployed graph is still the original C0 graph: one 3x3 stem, six
depthwise-3x3/pointwise-1x1 blocks, ReLU6, GAP, and the 256->10 linear layer.
BatchNorm exists only in the training graph and is algebraically folded into
the preceding convolution before export.
"""
from __future__ import annotations

from collections import OrderedDict
from typing import Iterable

import torch
import torch.nn as nn
import torch.nn.functional as F


class C0BNDSBlock(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int) -> None:
        super().__init__()
        self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=True)
        self.dw_bn = nn.BatchNorm2d(cin)
        self.pw = nn.Conv2d(cin, cout, 1, bias=True)
        self.pw_bn = nn.BatchNorm2d(cout)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu6(self.dw_bn(self.dw(x)))
        return F.relu6(self.pw_bn(self.pw(x)))


class C0BNTrainNet(nn.Module):
    """C0 training graph with BN after every existing convolution."""

    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
        self.stem_bn = nn.BatchNorm2d(16)
        self.blocks = nn.Sequential(
            C0BNDSBlock(16, 32, 1),
            C0BNDSBlock(32, 64, 2),
            C0BNDSBlock(64, 64, 1),
            C0BNDSBlock(64, 128, 2),
            C0BNDSBlock(128, 128, 1),
            C0BNDSBlock(128, 256, 2),
        )
        self.fc = nn.Linear(256, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu6(self.stem_bn(self.stem(x)))
        x = self.blocks(x)
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


class C0FoldedNet(nn.Module):
    """The exact BN-free C0 deployment graph after folding."""

    def __init__(self) -> None:
        super().__init__()
        self.stem = nn.Conv2d(3, 16, 3, padding=1, bias=True)
        self.blocks = nn.Sequential(
            _FoldedDSBlock(16, 32, 1),
            _FoldedDSBlock(32, 64, 2),
            _FoldedDSBlock(64, 64, 1),
            _FoldedDSBlock(64, 128, 2),
            _FoldedDSBlock(128, 128, 1),
            _FoldedDSBlock(128, 256, 2),
        )
        self.fc = nn.Linear(256, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu6(self.stem(x))
        x = self.blocks(x)
        return self.fc(F.adaptive_avg_pool2d(x, 1).flatten(1))


class _FoldedDSBlock(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int) -> None:
        super().__init__()
        self.dw = nn.Conv2d(cin, cin, 3, stride=stride, padding=1, groups=cin, bias=True)
        self.pw = nn.Conv2d(cin, cout, 1, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.relu6(self.pw(F.relu6(self.dw(x))))


def _fold_conv_bn(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> tuple[torch.Tensor, torch.Tensor]:
    if conv.out_channels != bn.num_features:
        raise ValueError("conv/BN channel count mismatch")
    weight = conv.weight.detach().clone()
    bias = conv.bias.detach().clone() if conv.bias is not None else torch.zeros(conv.out_channels, device=weight.device, dtype=weight.dtype)
    scale = bn.weight.detach() / torch.sqrt(bn.running_var.detach() + bn.eps)
    folded_weight = weight * scale.reshape(-1, 1, 1, 1)
    folded_bias = (bias - bn.running_mean.detach()) * scale + bn.bias.detach()
    return folded_weight, folded_bias


def fold_c0_bn(model: C0BNTrainNet) -> C0FoldedNet:
    """Fold evaluation-mode BN statistics into all seven preceding convs."""
    if model.training:
        raise ValueError("fold_c0_bn requires model.eval() so running statistics are authoritative")
    out = C0FoldedNet()
    with torch.no_grad():
        out.stem.weight.copy_(_fold_conv_bn(model.stem, model.stem_bn)[0])
        out.stem.bias.copy_(_fold_conv_bn(model.stem, model.stem_bn)[1])
        for idx in range(6):
            source = model.blocks[idx]
            target = out.blocks[idx]
            dw_w, dw_b = _fold_conv_bn(source.dw, source.dw_bn)
            pw_w, pw_b = _fold_conv_bn(source.pw, source.pw_bn)
            target.dw.weight.copy_(dw_w); target.dw.bias.copy_(dw_b)
            target.pw.weight.copy_(pw_w); target.pw.bias.copy_(pw_b)
        out.fc.weight.copy_(model.fc.weight.detach())
        out.fc.bias.copy_(model.fc.bias.detach())
    out.eval()
    return out


def folded_state_dict(model: C0BNTrainNet) -> OrderedDict[str, torch.Tensor]:
    """Return a plain C0 state dict with the legacy key names."""
    folded = fold_c0_bn(model)
    return OrderedDict((key, value.detach().cpu().clone()) for key, value in folded.state_dict().items())


def iter_existing_conv_pairs(model: C0BNTrainNet) -> Iterable[tuple[nn.Conv2d, nn.BatchNorm2d]]:
    yield model.stem, model.stem_bn
    for block in model.blocks:
        yield block.dw, block.dw_bn
        yield block.pw, block.pw_bn

