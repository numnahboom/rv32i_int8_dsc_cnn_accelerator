#!/usr/bin/env python3
"""Emit an auditable semantic profile for the EdgeDSCNet-C10 control (C0)."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def profile() -> dict[str, object]:
    # (name, input H, input W, Cin, Cout, kernel, stride, groups)
    rows: list[dict[str, int | str]] = []

    def add(name: str, h: int, w: int, cin: int, cout: int, kernel: int, stride: int, groups: int = 1) -> None:
        oh, ow = (h + stride - 1) // stride, (w + stride - 1) // stride
        if cin % groups or cout % groups:
            raise ValueError(f"invalid groups={groups} for {cin}->{cout}")
        weights = cout * (cin // groups) * kernel * kernel
        rows.append({
            "name": name,
            "h": oh,
            "w": ow,
            "cin": cin,
            "cout": cout,
            "kernel": kernel,
            "stride": stride,
            "groups": groups,
            "mac": oh * ow * cout * (cin // groups) * kernel * kernel,
            "weight_params": weights,
            "bias_params": cout,
        })

    add("stem", 32, 32, 3, 16, 3, 1)
    specs = [
        (16, 32, 32, 1),
        (32, 64, 32, 2),
        (64, 64, 16, 1),
        (64, 128, 16, 2),
        (128, 128, 8, 1),
        (128, 256, 8, 2),
    ]
    for index, (cin, cout, h, stride) in enumerate(specs, 1):
        add(f"b{index}.dw", h, h, cin, cin, 3, stride, groups=cin)
        add(f"b{index}.pw", h // stride, h // stride, cin, cout, 1, 1)

    fc_weight_params, fc_bias_params = 256 * 10, 10
    activations = [
        {"name": "input", "h": 32, "w": 32, "channels": 3},
        {"name": "stem", "h": 32, "w": 32, "channels": 16},
        {"name": "b1", "h": 32, "w": 32, "channels": 32},
        {"name": "b2", "h": 16, "w": 16, "channels": 64},
        {"name": "b3", "h": 16, "w": 16, "channels": 64},
        {"name": "b4", "h": 8, "w": 8, "channels": 128},
        {"name": "b5", "h": 8, "w": 8, "channels": 128},
        {"name": "b6", "h": 4, "w": 4, "channels": 256},
    ]
    for activation in activations:
        elements = activation["h"] * activation["w"] * activation["channels"]
        activation["elements"] = elements
        activation["bytes_int8"] = elements

    conv_mac = sum(int(row["mac"]) for row in rows)
    weight_params = sum(int(row["weight_params"]) for row in rows)
    bias_params = sum(int(row["bias_params"]) for row in rows)
    return {
        "schema": "C10-HWQA-v1-c0-edgedscnet-profile",
        "architecture": "EdgeDSCNet-C10 control",
        "operator_graph": "3x3 stem; six DW3x3+PW1x1 blocks; ReLU6; GAP; FC",
        "layers": rows,
        "conv_mac": conv_mac,
        "fc_mac": fc_weight_params,
        "semantic_macs": conv_mac + fc_weight_params,
        "binary_ops": 2 * (conv_mac + fc_weight_params),
        "weight_params": weight_params + fc_weight_params,
        "bias_params": bias_params + fc_bias_params,
        "trainable_params": weight_params + fc_weight_params + bias_params + fc_bias_params,
        "peak_activation_elements": max(int(a["elements"]) for a in activations),
        "peak_activation_bytes_int8": max(int(a["bytes_int8"]) for a in activations),
        "activation_shapes": activations,
        "quantization": {
            "weight": "symmetric per-output-channel int8",
            "activation": "signed int8; ReLU6 mapped to [0,127]",
            "accumulator": "int32 hardware contract; Python evaluator uses int64",
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("build/c0_hwqa_profile.json"))
    args = parser.parse_args()
    result = profile()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
