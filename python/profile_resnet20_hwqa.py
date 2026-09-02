#!/usr/bin/env python3
"""Emit an auditable semantic MAC/parameter/activation profile for ResNet-20."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

def profile() -> dict:
    # (name, H, W, Cin, Cout, kernel, stride), including all 19 conv layers.
    rows = [{"name": "stem", "h": 32, "w": 32, "cin": 3, "cout": 16, "kernel": 3, "stride": 1}]
    specs = [(16, 16, 32, 32, 1), (16, 16, 32, 32, 1), (16, 16, 32, 32, 1), (16, 32, 32, 32, 2), (32, 32, 16, 16, 1), (32, 32, 16, 16, 1), (32, 64, 16, 16, 2), (64, 64, 8, 8, 1), (64, 64, 8, 8, 1)]
    for i, (cin, cout, h, w, stride) in enumerate(specs, 1):
        rows.append({"name": f"b{i}.conv1", "h": h // stride, "w": w // stride, "cin": cin, "cout": cout, "kernel": 3, "stride": stride})
        rows.append({"name": f"b{i}.conv2", "h": h // stride, "w": w // stride, "cin": cout, "cout": cout, "kernel": 3, "stride": 1})
        if cin != cout or stride != 1:
            rows.append({"name": f"b{i}.proj", "h": h // stride, "w": w // stride, "cin": cin, "cout": cout, "kernel": 1, "stride": stride})
    for r in rows:
        r["mac"] = r["h"] * r["w"] * r["cout"] * r["cin"] * r["kernel"] * r["kernel"]
        r["params"] = r["cout"] * r["cin"] * r["kernel"] * r["kernel"]
    # FC and residual adds are reported separately from convolution MACs.
    fc_params = 64 * 10; fc_mac = fc_params
    acts = [{"name": "input", "h": 32, "w": 32, "channels": 3}, {"name": "stem", "h": 32, "w": 32, "channels": 16}, {"name": "stage1", "h": 32, "w": 32, "channels": 16}, {"name": "stage2", "h": 16, "w": 16, "channels": 32}, {"name": "stage3", "h": 8, "w": 8, "channels": 64}]
    for a in acts: a["elements"] = a["h"] * a["w"] * a["channels"]; a["bytes_int8"] = a["elements"]
    residual_adds = 3 * 32 * 32 * 16 + 3 * 16 * 16 * 32 + 3 * 8 * 8 * 64
    return {"schema": "C10-HWQA-v1-resnet20-profile", "architecture": "CIFAR ResNet-20", "layers": rows, "conv_mac": sum(r["mac"] for r in rows), "fc_mac": fc_mac, "semantic_macs": sum(r["mac"] for r in rows) + fc_mac, "params": sum(r["params"] for r in rows) + fc_params, "residual_adds": residual_adds, "peak_activation_elements": max(a["elements"] for a in acts), "peak_activation_bytes_int8": max(a["bytes_int8"] for a in acts), "activation_shapes": acts, "quantization": {"weight": "int8 per output channel", "activation": "int8", "accumulator": "int32", "bias": "int32"}}


def main() -> None:
    p = argparse.ArgumentParser(); p.add_argument("--out", type=Path, default=Path("build/resnet20_hwqa_deploy/resnet20_hwqa_profile.json")); args = p.parse_args()
    result = profile(); args.out.parent.mkdir(parents=True, exist_ok=True); args.out.write_text(json.dumps(result, indent=2), encoding="utf-8"); print(json.dumps(result, indent=2)); print(f"wrote {args.out}")


if __name__ == "__main__": main()
