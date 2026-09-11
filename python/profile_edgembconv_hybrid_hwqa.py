#!/usr/bin/env python3
"""Produce the independent semantic cost profile for EdgeMBConv-Hybrid.

The profile is deliberately generated from the frozen graph table instead of
from PyTorch parameter counts, so stride, depthwise groups, repetitions and
the FC head are visible and auditable.  The declared target is retained in the
output for comparison; a mismatch is an explicit profile failure, never a
silent reduction of the graph.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


EXPECTED_SEMANTIC_MACS = 17_211_904


def profile() -> dict[str, object]:
    rows: list[dict[str, int | str | bool]] = []

    def add(name: str, h: int, w: int, cin: int, cout: int, kernel: int = 1,
            stride: int = 1, groups: int = 1, activation: str = "linear",
            residual: bool = False) -> None:
        if cin % groups != 0 or cout % groups != 0:
            raise ValueError(f"invalid groups={groups} for {cin}->{cout}")
        oh, ow = (h + stride - 1) // stride, (w + stride - 1) // stride
        params = cout * (cin // groups) * kernel * kernel
        rows.append({
            "name": name, "input_h": h, "input_w": w, "h": oh, "w": ow,
            "cin": cin, "cout": cout, "kernel": kernel, "stride": stride,
            "groups": groups, "mac": oh * ow * cout * (cin // groups) * kernel * kernel,
            "weight_params": params, "bias_params": cout,
            "activation": activation, "residual": residual,
        })

    add("stem.3x3", 32, 32, 3, 16, 3, activation="relu6")
    # 32^2 fused dense block, residual at equal width.
    add("fused1.expand.3x3", 32, 32, 16, 32, 3, activation="relu6", residual=True)
    add("fused1.project.1x1", 32, 32, 32, 16, activation="linear", residual=True)
    # 16^2 stride-2 fused block.
    add("fused2.expand.3x3", 32, 32, 16, 32, 3, stride=2, activation="relu6")
    add("fused2.project.1x1", 16, 16, 32, 32, activation="linear")

    def mb(prefix: str, h: int, w: int, cin: int, hidden: int, cout: int,
           stride: int, repeat: int = 1, residual: bool = False) -> None:
        for rep in range(repeat):
            tag = f"{prefix}.{rep + 1}" if repeat > 1 else prefix
            add(f"{tag}.expand.1x1", h, w, cin, hidden, stride=1, activation="relu6", residual=residual)
            add(f"{tag}.spatial.dw3x3", h, w, hidden, hidden, kernel=3, stride=stride,
                groups=hidden, activation="relu6", residual=residual)
            add(f"{tag}.project.1x1", (h + stride - 1) // stride, (w + stride - 1) // stride,
                hidden, cout, activation="linear", residual=residual)
            h, w, cin = (h + stride - 1) // stride, (w + stride - 1) // stride, cout
            stride = 1

    mb("mb16", 16, 16, 32, 64, 32, 1, repeat=2, residual=True)
    mb("mb8.down", 16, 16, 32, 64, 64, 2)
    mb("mb8", 8, 8, 64, 128, 64, 1, repeat=3, residual=True)
    mb("mb4.down", 8, 8, 64, 128, 128, 2)
    mb("mb4", 4, 4, 128, 256, 128, 1, repeat=2, residual=True)
    add("head.1x1", 4, 4, 128, 256, activation="linear")

    fc_params = 256 * 10
    rows.append({"name": "fc", "input_h": 1, "input_w": 1, "h": 1, "w": 1,
                 "cin": 256, "cout": 10, "kernel": 1, "stride": 1, "groups": 1,
                 "mac": fc_params, "weight_params": fc_params, "bias_params": 10,
                 "activation": "linear", "residual": False})

    activations = [
        {"name": "input", "h": 32, "w": 32, "channels": 3},
        {"name": "stem", "h": 32, "w": 32, "channels": 16},
        {"name": "fused1", "h": 32, "w": 32, "channels": 16},
        {"name": "fused2", "h": 16, "w": 16, "channels": 32},
        {"name": "mb16", "h": 16, "w": 16, "channels": 32},
        {"name": "mb8", "h": 8, "w": 8, "channels": 64},
        {"name": "mb4", "h": 4, "w": 4, "channels": 128},
        {"name": "head", "h": 4, "w": 4, "channels": 256},
    ]
    for item in activations:
        item["elements"] = int(item["h"]) * int(item["w"]) * int(item["channels"])
        item["bytes_int8"] = item["elements"]

    conv_mac = sum(int(r["mac"]) for r in rows if r["name"] != "fc")
    semantic = conv_mac + fc_params
    weight_params = sum(int(r["weight_params"]) for r in rows)
    bias_params = sum(int(r["bias_params"]) for r in rows)
    residual_adds = 32 * 32 * 16 + 2 * 16 * 16 * 32 + 3 * 8 * 8 * 64 + 2 * 4 * 4 * 128
    return {
        "schema": "C10-HWQA-v1-edgembconv-hybrid-profile",
        "architecture": "EdgeMBConv-Hybrid",
        "operator_graph": "dense3x3 stem; fused dense3x3+linear1x1; MBConv 1x1+DW3x3+linear1x1; GAP; FC",
        "layers": rows,
        "conv_mac": conv_mac,
        "fc_mac": fc_params,
        "semantic_macs": semantic,
        "expected_semantic_macs": EXPECTED_SEMANTIC_MACS,
        "semantic_mac_match": semantic == EXPECTED_SEMANTIC_MACS,
        "profile_status": "PASS" if semantic == EXPECTED_SEMANTIC_MACS else "FAIL_EXPECTED_MAC_MISMATCH",
        "weight_params": weight_params,
        "bias_params": bias_params,
        "trainable_params": weight_params + bias_params,
        "residual_adds": residual_adds,
        "peak_activation_elements": max(int(a["elements"]) for a in activations),
        "peak_activation_bytes_int8": max(int(a["bytes_int8"]) for a in activations),
        "activation_shapes": activations,
        "quantization": {
            "weight": "symmetric per-output-channel int8",
            "activation": "signed int8; ReLU6 range [0,127]; linear/residual signed range [-128,127]",
            "accumulator": "int32 hardware contract; evaluator uses int64 for overflow audit",
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("build/edgembconv_hybrid_hwqa/edgembconv_hybrid_profile.json"))
    parser.add_argument("--allow-mismatch", action="store_true", help="write the profile but retain FAIL status")
    args = parser.parse_args()
    result = profile()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"wrote {args.out}")
    if result["profile_status"] != "PASS" and not args.allow_mismatch:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
