#!/usr/bin/env python3
"""Export ResNet-20 QAT weights as explicit INT8/INT32 deployment artifacts.

The evaluator below is an integer golden model.  Every convolution computes
INT8*INT8 -> INT64 (the eventual hardware accumulator is INT32 by contract;
the wider Python type is only an overflow-safe reference), adds INT32 bias,
then applies an integer multiplier/shift with round-to-nearest-away-from-zero
and saturation.  Residual additions use the same integer requantization.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import numpy as np

from resnet20_hwqa import INPUT_SCALE, ResNet20, CifarDataset, frozen_split, load_cifar10

DS = [(16, 16, 1), (16, 16, 1), (16, 16, 1), (16, 32, 2), (32, 32, 1), (32, 32, 1), (32, 64, 2), (64, 64, 1), (64, 64, 1)]


def round_away(x: np.ndarray | float) -> np.ndarray | int:
    a = np.asarray(x)
    out = np.floor(np.abs(a) + 0.5).astype(np.int64)
    return np.where(a < 0, -out, out)


def quant_weight(w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    flat = w.reshape(w.shape[0], -1).astype(np.float64)
    scale = np.maximum(np.max(np.abs(flat), axis=1) / 127.0, 1e-12)
    q = np.clip(round_away(flat / scale[:, None]), -127, 127).astype(np.int8)
    return q.reshape(w.shape), scale.astype(np.float64)


def ratio_qparams(ratio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    ratio = np.asarray(ratio, dtype=np.float64)
    shifts = np.full(ratio.shape, 31, dtype=np.int32)
    mul = np.rint(ratio * (2.0**31)).astype(np.int64)
    # Keep a signed 32-bit multiplier while retaining the closest power-of-two.
    for i in np.ndindex(ratio.shape):
        while abs(int(mul[i])) > 2**30 - 1 and int(shifts[i]) > 0:
            shifts[i] -= 1
            mul[i] = int(np.rint(ratio[i] * (2.0 ** int(shifts[i]))))
    return mul.astype(np.int32), shifts


def requant(acc: np.ndarray, multiplier: np.ndarray, shift: np.ndarray, qmin: int, qmax: int) -> np.ndarray:
    p = acc.astype(np.int64) * np.asarray(multiplier, dtype=np.int64)
    d = (2 ** np.asarray(shift, dtype=np.int64))
    q = round_away(p / d)
    return np.clip(q, qmin, qmax).astype(np.int8)


def conv3_q(x: np.ndarray, w: np.ndarray, bias: np.ndarray, mul: np.ndarray, shift: np.ndarray, stride: int) -> np.ndarray:
    n, h, wid, cin = x.shape; cout = w.shape[0]
    pad = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)), constant_values=0)
    view = np.lib.stride_tricks.sliding_window_view(pad, (3, 3), axis=(1, 2))
    view = view[:, ::stride, ::stride].reshape(n, (h + stride - 1) // stride, (wid + stride - 1) // stride, -1)
    acc = np.einsum("nhwk,ok->nhwo", view.astype(np.int64), w.reshape(cout, -1).astype(np.int64), optimize=True)
    acc += bias.reshape(1, 1, 1, -1).astype(np.int64)
    return requant(acc, mul.reshape(1, 1, 1, -1), shift.reshape(1, 1, 1, -1), -128, 127)


def conv1_q(x: np.ndarray, w: np.ndarray, bias: np.ndarray, mul: np.ndarray, shift: np.ndarray, stride: int) -> np.ndarray:
    sampled = x[:, ::stride, ::stride]
    acc = np.einsum("nhwc,oc->nhwo", sampled.astype(np.int64), w.reshape(w.shape[0], w.shape[1]).astype(np.int64), optimize=True)
    acc += bias.reshape(1, 1, 1, -1).astype(np.int64)
    return requant(acc, mul.reshape(1, 1, 1, -1), shift.reshape(1, 1, 1, -1), -128, 127)


def add_q(a: np.ndarray, sa: float, b: np.ndarray, sb: float, sout: float) -> np.ndarray:
    qa = round_away(a.astype(np.int64) * (sa / sout))
    qb = round_away(b.astype(np.int64) * (sb / sout))
    return np.clip(qa.astype(np.int64) + qb.astype(np.int64), 0, 127).astype(np.int8)


def state_np(state: dict[str, Any], key: str) -> np.ndarray:
    value = state[key]
    return value.detach().cpu().numpy() if hasattr(value, "detach") else np.asarray(value)


def export(args: argparse.Namespace) -> None:
    import torch
    ckpt = torch.load(args.qat, map_location="cpu", weights_only=False)
    state = ckpt["model_state"]; scales = {k: float(v) for k, v in ckpt["scales"].items()}
    out = args.out; out.mkdir(parents=True, exist_ok=True)
    params: dict[str, np.ndarray] = {"input_scale": np.asarray(INPUT_SCALE, np.float32)}
    layers: list[dict[str, Any]] = []
    in_scale = INPUT_SCALE

    def add_conv(name: str, key: str, in_s: float, out_s: float, kernel: int, stride: int) -> None:
        nonlocal params
        w, ws = quant_weight(state_np(state, key + ".weight"))
        bfp = state_np(state, key + ".bias").astype(np.float64)
        bias = round_away(bfp / (in_s * ws)).astype(np.int64)
        bias = np.clip(bias, -(2**31), 2**31 - 1).astype(np.int32)
        mul, sh = ratio_qparams(in_s * ws / out_s)
        params.update({name + ".weight": w.astype(np.int8), name + ".weight_scale": ws.astype(np.float32), name + ".bias": bias, name + ".multiplier": mul, name + ".shift": sh})
        layers.append({"name": name, "source": key, "kernel": kernel, "stride": stride, "in_scale": in_s, "out_scale": out_s, "weight_scale": ws.tolist(), "activation": "signed_int8"})

    add_conv("stem", "stem", INPUT_SCALE, scales["stem"], 3, 1); in_scale = scales["stem"]
    for i, (cin, cout, stride) in enumerate(DS, 1):
        key = f"blocks.{i-1}"
        add_conv(f"b{i}.conv1", key + ".conv1", in_scale, scales[f"b{i}.c1"], 3, stride)
        add_conv(f"b{i}.conv2", key + ".conv2", scales[f"b{i}.c1"], scales[f"b{i}.c2"], 3, 1)
        if cin != cout or stride != 1:
            add_conv(f"b{i}.proj", key + ".proj", in_scale, scales[f"b{i}.skip"], 1, stride)
        layers.append({"name": f"b{i}.add_relu", "op": "residual_add_relu", "main_scale": scales[f"b{i}.c2"], "skip_scale": scales.get(f"b{i}.skip", in_scale), "out_scale": scales[f"b{i}.out"]})
        in_scale = scales[f"b{i}.out"]

    fw, fws = quant_weight(state_np(state, "fc.weight")); fb = state_np(state, "fc.bias").astype(np.float64)
    gap_scale = in_scale
    fbias = round_away(fb / (gap_scale * fws)).astype(np.int64); fbias = np.clip(fbias, -(2**31), 2**31 - 1).astype(np.int32)
    params.update({"fc.weight": fw.astype(np.int8), "fc.weight_scale": fws.astype(np.float32), "fc.bias": fbias})
    layers.append({"name": "fc", "op": "linear", "in_scale": gap_scale, "weight_scale": fws.tolist(), "accumulator": "int32"})
    np.savez_compressed(out / "resnet20_hwqa_int8.npz", **params)

    manifest = {"schema": "C10-HWQA-v1-resnet20-deploy", "architecture": "CIFAR ResNet-20", "dataset_manifest": "docs/reports/c10_hwqa_v1_manifest.json", "operators": ["dense_3x3", "projection_1x1", "ReLU", "GAP", "FC"], "channels": [16, 32, 64], "spatial_sizes": [32, 16, 8], "bn": "folded_into_conv_bias_and_weight", "quantization": {"input": "q=clip(round((raw_uint8-128)), -128,127), scale=1/127.5, zero_point=0", "weights": "symmetric per-output-channel int8, range [-127,127]", "activations": "int8, ReLU range [0,127], residual branch signed range [-128,127]", "accumulator": "int32 (Python reference uses int64 to detect overflow)", "bias": "int32 in input_scale*weight_scale units", "requant": "round-to-nearest-away-from-zero(acc*multiplier/2^shift), then saturate"}, "layers": layers, "source_checkpoint": str(args.qat), "arrays": "resnet20_hwqa_int8.npz"}
    (out / "resnet20_hwqa_deploy_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"wrote {out / 'resnet20_hwqa_int8.npz'}")
    print(f"wrote {out / 'resnet20_hwqa_deploy_manifest.json'}")

    if args.data:
        images, labels = load_cifar10(args.data, "test")
        pred, correct = evaluate_int8(images, labels, params, scales, batch_size=args.batch_size)
        result = {"samples": int(labels.size), "correct": correct, "int8_top1": correct / labels.size}
        if args.fp32:
            from resnet20_hwqa import evaluate
            fp_ckpt = torch.load(args.fp32, map_location="cpu", weights_only=False); model = ResNet20(); model.load_state_dict(fp_ckpt["model_state"])
            test_loader = torch.utils.data.DataLoader(CifarDataset(images, labels, False, 17), batch_size=args.batch_size, shuffle=False, num_workers=0)
            _, fp_acc = evaluate(model, test_loader, torch.device("cpu")); result["fp32_top1"] = fp_acc; result["drop_pp"] = (fp_acc - result["int8_top1"]) * 100.0
        (out / "resnet20_hwqa_test10k.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result))


def evaluate_int8(images: np.ndarray, labels: np.ndarray, p: dict[str, np.ndarray], s: dict[str, float], batch_size: int = 128) -> tuple[np.ndarray, int]:
    predictions = np.empty(len(labels), dtype=np.int64)
    for start in range(0, len(labels), batch_size):
        x = np.clip(images[start:start + batch_size].astype(np.int16) - 128, -128, 127).astype(np.int8)
        x = conv3_q(x, p["stem.weight"], p["stem.bias"], p["stem.multiplier"], p["stem.shift"], 1); x = np.clip(x, 0, 127).astype(np.int8); in_s = s["stem"]
        for i, (cin, cout, stride) in enumerate(DS, 1):
            key = f"b{i}"
            y = conv3_q(x, p[key + ".conv1.weight"], p[key + ".conv1.bias"], p[key + ".conv1.multiplier"], p[key + ".conv1.shift"], stride); y = np.clip(y, 0, 127).astype(np.int8)
            y = conv3_q(y, p[key + ".conv2.weight"], p[key + ".conv2.bias"], p[key + ".conv2.multiplier"], p[key + ".conv2.shift"], 1)
            if cin != cout or stride != 1:
                z = conv1_q(x, p[key + ".proj.weight"], p[key + ".proj.bias"], p[key + ".proj.multiplier"], p[key + ".proj.shift"], stride); skip_s = s[f"b{i}.skip"]
            else: z, skip_s = x, in_s
            y = add_q(y, s[f"b{i}.c2"], z, skip_s, s[f"b{i}.out"]); x, in_s = y, s[f"b{i}.out"]
        gap = round_away(x.astype(np.int64).sum(axis=(1, 2)) / 64.0).clip(0, 127).astype(np.int8)
        acc = np.einsum("nc,oc->no", gap.astype(np.int64), p["fc.weight"].astype(np.int64), optimize=True) + p["fc.bias"].reshape(1, -1).astype(np.int64)
        predictions[start:start + len(gap)] = acc.argmax(1)
    return predictions, int(np.sum(predictions == labels))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--qat", type=Path, default=Path("build/model/resnet20_hwqa_qat.pt"))
    p.add_argument("--fp32", type=Path, default=Path("build/model/resnet20_hwqa_fp32.pt"))
    p.add_argument("--out", type=Path, default=Path("build/resnet20_hwqa_deploy"))
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--batch-size", type=int, default=128)
    return p.parse_args()


if __name__ == "__main__":
    export(parse_args())
