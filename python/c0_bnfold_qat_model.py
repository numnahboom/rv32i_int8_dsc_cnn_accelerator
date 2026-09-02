#!/usr/bin/env python3
"""INT8-aware training model for the fixed, BN-folded C0 graph."""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F

from c0_bnfold_model import C0FoldedNet


INPUT_SCALE = 1.0 / 127.5
RELU6_SCALE = 6.0 / 127.0


def round_away_tensor(value: torch.Tensor) -> torch.Tensor:
    return torch.sign(value) * torch.floor(torch.abs(value) + 0.5)


def fake_quant(value: torch.Tensor, scale: float, qmin: int, qmax: int) -> torch.Tensor:
    """Straight-through fake quantizer matching the integer evaluator."""
    scale = max(float(scale), 1.0e-12)
    quantized = torch.clamp(round_away_tensor(value / scale), qmin, qmax)
    dequantized = quantized * scale
    return value + (dequantized - value).detach()


def fake_quant_weight(weight: torch.Tensor) -> torch.Tensor:
    """Symmetric per-output-channel INT8 fake quantization."""
    scale = weight.detach().abs().flatten(1).amax(dim=1).clamp_min(1.0e-8) / 127.0
    shape = [weight.shape[0]] + [1] * (weight.ndim - 1)
    scale = scale.reshape(shape)
    # Export uses numpy.rint (nearest-even); torch.round has the same tie rule.
    quantized = torch.clamp(torch.round(weight / scale), -127, 127)
    return weight + (quantized * scale - weight).detach()


def fake_quant_weight_with_scale(weight: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    scale = weight.detach().abs().flatten(1).amax(dim=1).clamp_min(1.0e-8) / 127.0
    scale = scale.reshape([weight.shape[0]] + [1] * (weight.ndim - 1))
    quantized = torch.clamp(torch.round(weight / scale), -127, 127)
    return weight + (quantized * scale - weight).detach(), scale


class C0BNFoldQAT(nn.Module):
    """Fake-quantized fixed C0 graph; BN and no new runtime operators."""

    def __init__(self, folded: C0FoldedNet) -> None:
        super().__init__()
        self.core = folded

    @staticmethod
    def _conv_relu(conv: nn.Conv2d, x: torch.Tensor, input_scale: float) -> torch.Tensor:
        qweight, weight_scale = fake_quant_weight_with_scale(conv.weight)
        # Deployment stores bias in input_scale*weight_scale accumulator units.
        # Fake quantizing it here removes the systematic PTQ-vs-QAT mismatch
        # while retaining an STE path to the FP32 bias.
        bias_scale = float(input_scale) * weight_scale.flatten()
        bias_q = torch.round(conv.bias / bias_scale)
        bias_dequant = bias_q * bias_scale
        bias = conv.bias + (bias_dequant - conv.bias).detach()
        y = F.conv2d(x, qweight, bias,
                     stride=conv.stride, padding=conv.padding,
                     dilation=conv.dilation, groups=conv.groups)
        return fake_quant(F.relu6(y), RELU6_SCALE, 0, 127)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = fake_quant(x, INPUT_SCALE, -128, 127)
        x = self._conv_relu(self.core.stem, x, INPUT_SCALE)
        for block in self.core.blocks:
            x = self._conv_relu(block.dw, x, RELU6_SCALE)
            x = self._conv_relu(block.pw, x, RELU6_SCALE)
        x = fake_quant(F.adaptive_avg_pool2d(x, 1), RELU6_SCALE, 0, 127)
        qweight, weight_scale = fake_quant_weight_with_scale(self.core.fc.weight)
        bias_scale = RELU6_SCALE * weight_scale.flatten()
        bias_q = torch.round(self.core.fc.bias / bias_scale)
        bias = self.core.fc.bias + (bias_q * bias_scale - self.core.fc.bias).detach()
        # Keep the classifier output in float during optimization.  The
        # deployment exporter applies the final INT8 requant; clipping logits
        # here would give zero gradients for already saturated classes.
        return F.linear(x.flatten(1), qweight, bias)


def make_qat_from_state(state: dict[str, torch.Tensor]) -> C0BNFoldQAT:
    folded = C0FoldedNet()
    folded.load_state_dict(state)
    return C0BNFoldQAT(folded)
