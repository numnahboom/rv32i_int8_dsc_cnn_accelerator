#!/usr/bin/env python3
"""Export a deterministic int8 EdgeDSCNet-C10 smoke model.

This is a lightweight verification exporter. It consumes the checkpoint written
by train_edgedscnet_c10.py, uses the saved CIFAR sample image as input, creates
hardware-compatible int8 parameters, runs the Python golden model, and emits
hex vectors plus a compressed NPZ parameter bundle.

It is not a production PTQ/QAT exporter yet. The generated parameters are
deterministic smoke-test values suitable for checking the export and golden
inference pipeline.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
from typing import Any

import numpy as np

from generate_test_vectors import (
    dsblock_same_golden,
    fc_golden,
    hex_width,
    saturate_int8,
    stem_same_golden,
)


DS_SPECS = [
    (1, 32, 32, 16, 32, 1),
    (2, 32, 32, 32, 64, 2),
    (3, 16, 16, 64, 64, 1),
    (4, 16, 16, 64, 128, 2),
    (5, 8, 8, 128, 128, 1),
    (6, 8, 8, 128, 256, 2),
]

INPUT_SCALE = 1.0 / 127.5
RELU6_SCALE = 6.0 / 127.0
LOGIT_SCALE = 6.0 / 127.0
RELU_MIN = 0
RELU_MAX = 127


def load_checkpoint_sample(path: Path, seed: int) -> tuple[np.ndarray, str]:
    if path.exists() and path.suffix == ".npz":
        ckpt = np.load(path, allow_pickle=True)
        if "sample_image_uint8" in ckpt:
            return ckpt["sample_image_uint8"].astype(np.uint8), str(ckpt.get("backend", "numpy"))

    if path.exists() and path.suffix in (".pth", ".pt"):
        try:
            import torch

            ckpt = torch.load(path, map_location="cpu")
            if "sample_image_uint8" in ckpt:
                return np.asarray(ckpt["sample_image_uint8"], dtype=np.uint8), str(ckpt.get("backend", "torch"))
        except ModuleNotFoundError:
            pass

    rng = np.random.default_rng(seed)
    image = rng.integers(0, 256, size=(32, 32, 3), dtype=np.uint8)
    return image, "random_fallback"


def load_torch_checkpoint(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        import torch

        try:
            ckpt = torch.load(path, map_location="cpu", weights_only=False)
        except TypeError:
            ckpt = torch.load(path, map_location="cpu")
    except Exception:
        return None
    if isinstance(ckpt, dict) and "model_state" in ckpt:
        return ckpt
    return None


def tensor_to_np(value: Any) -> np.ndarray:
    if hasattr(value, "detach"):
        value = value.detach().cpu().numpy()
    return np.asarray(value)


def quantize_weight_per_out_channel(weight: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    weight = np.asarray(weight, dtype=np.float32)
    flat = weight.reshape(weight.shape[0], -1)
    max_abs = np.max(np.abs(flat), axis=1)
    scales = np.where(max_abs > 1.0e-12, max_abs / 127.0, 1.0 / 127.0).astype(np.float64)
    q = np.rint(flat / scales[:, None])
    q = np.clip(q, -127, 127).astype(np.int8)
    return q.reshape(weight.shape), scales


def encode_q31_multiplier(real_multiplier: float) -> tuple[int, int]:
    real_multiplier = float(real_multiplier)
    if real_multiplier <= 0.0 or not math.isfinite(real_multiplier):
        return 0, 0

    shift = 0
    multiplier = int(round(real_multiplier * float(1 << 31)))
    while multiplier < (1 << 30) and shift < 31:
        shift += 1
        multiplier = int(round(real_multiplier * float(1 << (31 + shift))))
    while multiplier >= (1 << 31) and shift > 0:
        shift -= 1
        multiplier = int(round(real_multiplier * float(1 << (31 + shift))))
    multiplier = max(1, min((1 << 31) - 1, multiplier))
    return multiplier, shift


def make_qparams(
    bias_fp: np.ndarray,
    input_scale: float,
    weight_scales: np.ndarray,
    output_scale: float,
    relu: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int, int, int]:
    bias_fp = np.asarray(bias_fp, dtype=np.float64)
    weight_scales = np.asarray(weight_scales, dtype=np.float64)
    acc_scales = input_scale * weight_scales
    bias_q = np.rint(bias_fp / acc_scales)
    bias_q = np.clip(bias_q, -(1 << 31), (1 << 31) - 1).astype(np.int32)

    multipliers = []
    shifts = []
    for acc_scale in acc_scales:
        mul, shift = encode_q31_multiplier(float(acc_scale / output_scale))
        multipliers.append(mul)
        shifts.append(shift)

    return (
        bias_q,
        np.asarray(multipliers, dtype=np.int32),
        np.asarray(shifts, dtype=np.int32),
        0,
        RELU_MIN if relu else -128,
        RELU_MAX if relu else 127,
    )


def torch_weight_state(ckpt: dict[str, Any], key: str) -> np.ndarray:
    state = ckpt["model_state"]
    if key not in state:
        raise KeyError(f"checkpoint missing model_state[{key!r}]")
    return tensor_to_np(state[key]).astype(np.float32)


def flat_to_stem_weight(weight: np.ndarray) -> list[list[int]]:
    # Torch layout [Cout, Cin, 3, 3] -> RTL/golden layout [Cout][(kh*3+kw)*Cin+ci].
    weight = np.asarray(weight, dtype=np.int8)
    out = []
    for co in range(weight.shape[0]):
        vals = []
        for kh in range(3):
            for kw in range(3):
                for ci in range(weight.shape[1]):
                    vals.append(int(weight[co, ci, kh, kw]))
        out.append(vals)
    return out


def flat_to_dw_weight(weight: np.ndarray) -> list[list[int]]:
    # Torch depthwise layout [Cin, 1, 3, 3] -> [Cin][kh*3+kw].
    weight = np.asarray(weight, dtype=np.int8)
    out = []
    for c in range(weight.shape[0]):
        vals = []
        for kh in range(3):
            for kw in range(3):
                vals.append(int(weight[c, 0, kh, kw]))
        out.append(vals)
    return out


def flat_to_pw_weight(weight: np.ndarray) -> list[list[int]]:
    # Torch pointwise layout [Cout, Cin, 1, 1] -> [Cout][Cin].
    weight = np.asarray(weight, dtype=np.int8)
    return weight[:, :, 0, 0].astype(np.int16).tolist()


def run_exported_int8_model(image_u8: np.ndarray, params: dict[str, Any]) -> tuple[list[int], int]:
    feature = i8_image_from_uint8(image_u8)

    out_h, out_w, stem_out = stem_same_golden(
        feature,
        int(params["input_zero_point"]),
        np.asarray(params["stem_weight"], dtype=np.int8).astype(np.int16).tolist(),
        np.asarray(params["stem_bias"], dtype=np.int32).astype(int).tolist(),
        np.asarray(params["stem_multiplier"], dtype=np.int32).astype(int).tolist(),
        np.asarray(params["stem_shift"], dtype=np.int32).astype(int).tolist(),
        int(params["stem_output_zero_point"]),
        RELU_MIN,
        RELU_MAX,
    )
    feature = flat_to_feature(stem_out, out_h, out_w, 16)
    prev_ozp = int(params["stem_output_zero_point"])

    for idx, _, _, in_c, out_c, stride in DS_SPECS:
        out_h, out_w, ds_out = dsblock_same_golden(
            feature,
            prev_ozp,
            np.asarray(params[f"ds{idx}_dw_weight"], dtype=np.int8).astype(np.int16).tolist(),
            np.asarray(params[f"ds{idx}_dw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(params[f"ds{idx}_dw_multiplier"], dtype=np.int32).astype(int).tolist(),
            np.asarray(params[f"ds{idx}_dw_shift"], dtype=np.int32).astype(int).tolist(),
            np.asarray(params[f"ds{idx}_pw_weight"], dtype=np.int8).astype(np.int16).tolist(),
            np.asarray(params[f"ds{idx}_pw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(params[f"ds{idx}_pw_multiplier"], dtype=np.int32).astype(int).tolist(),
            np.asarray(params[f"ds{idx}_pw_shift"], dtype=np.int32).astype(int).tolist(),
            stride,
            int(params[f"ds{idx}_dw_output_zero_point"]),
            RELU_MIN,
            RELU_MAX,
            int(params[f"ds{idx}_pw_output_zero_point"]),
            RELU_MIN,
            RELU_MAX,
        )
        feature = flat_to_feature(ds_out, out_h, out_w, out_c)
        prev_ozp = int(params[f"ds{idx}_pw_output_zero_point"])

    gap = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        gap.append(saturate_int8(total >> 4))

    logits = fc_golden(
        gap,
        np.asarray(params["fc_weight"], dtype=np.int8).astype(np.int16).tolist(),
        np.asarray(params["fc_bias"], dtype=np.int32).astype(int).tolist(),
        np.asarray(params["fc_multiplier"], dtype=np.int32).astype(int).tolist(),
        np.asarray(params["fc_shift"], dtype=np.int32).astype(int).tolist(),
        int(params["fc_output_zero_point"]),
        -128,
        127,
    )
    return logits, int(np.argmax(np.asarray(logits, dtype=np.int16)))


def export_torch_quantized_model(args: argparse.Namespace, ckpt: dict[str, Any]) -> None:
    sample = np.asarray(ckpt.get("sample_image_uint8"), dtype=np.uint8)
    if sample.shape != (32, 32, 3):
        sample, _ = load_checkpoint_sample(args.ckpt, args.seed)

    params: dict[str, Any] = {
        "checkpoint_backend": np.asarray(str(ckpt.get("backend", "torch_edgedscnet_c10_quantized"))),
        "checkpoint_eval_acc": np.asarray(float(ckpt.get("eval_acc", -1.0)), dtype=np.float32),
        "input_image_uint8": sample,
        "input_image_i8": np.asarray(i8_image_from_uint8(sample), dtype=np.int8),
        "input_zero_point": np.asarray(0, dtype=np.int32),
    }

    stem_w_fp = torch_weight_state(ckpt, "stem.weight")
    stem_b_fp = torch_weight_state(ckpt, "stem.bias")
    stem_w_q, stem_w_scale = quantize_weight_per_out_channel(stem_w_fp)
    stem_bias, stem_mul, stem_shift, stem_ozp, _, _ = make_qparams(
        stem_b_fp,
        INPUT_SCALE,
        stem_w_scale,
        RELU6_SCALE,
        True,
    )
    params.update(
        {
            "stem_weight": np.asarray(flat_to_stem_weight(stem_w_q), dtype=np.int8),
            "stem_bias": stem_bias,
            "stem_multiplier": stem_mul,
            "stem_shift": stem_shift,
            "stem_output_zero_point": np.asarray(stem_ozp, dtype=np.int32),
        }
    )

    input_scale = RELU6_SCALE
    for block_idx, _, _, in_c, out_c, _ in DS_SPECS:
        torch_idx = block_idx - 1
        dw_w_fp = torch_weight_state(ckpt, f"blocks.{torch_idx}.dw.weight")
        dw_b_fp = torch_weight_state(ckpt, f"blocks.{torch_idx}.dw.bias")
        pw_w_fp = torch_weight_state(ckpt, f"blocks.{torch_idx}.pw.weight")
        pw_b_fp = torch_weight_state(ckpt, f"blocks.{torch_idx}.pw.bias")

        dw_w_q, dw_w_scale = quantize_weight_per_out_channel(dw_w_fp)
        pw_w_q, pw_w_scale = quantize_weight_per_out_channel(pw_w_fp)
        dw_bias, dw_mul, dw_shift, dw_ozp, _, _ = make_qparams(
            dw_b_fp,
            input_scale,
            dw_w_scale,
            RELU6_SCALE,
            True,
        )
        pw_bias, pw_mul, pw_shift, pw_ozp, _, _ = make_qparams(
            pw_b_fp,
            RELU6_SCALE,
            pw_w_scale,
            RELU6_SCALE,
            True,
        )

        params.update(
            {
                f"ds{block_idx}_dw_weight": np.asarray(flat_to_dw_weight(dw_w_q), dtype=np.int8),
                f"ds{block_idx}_dw_bias": dw_bias,
                f"ds{block_idx}_dw_multiplier": dw_mul,
                f"ds{block_idx}_dw_shift": dw_shift,
                f"ds{block_idx}_dw_output_zero_point": np.asarray(dw_ozp, dtype=np.int32),
                f"ds{block_idx}_pw_weight": np.asarray(flat_to_pw_weight(pw_w_q), dtype=np.int8),
                f"ds{block_idx}_pw_bias": pw_bias,
                f"ds{block_idx}_pw_multiplier": pw_mul,
                f"ds{block_idx}_pw_shift": pw_shift,
                f"ds{block_idx}_pw_output_zero_point": np.asarray(pw_ozp, dtype=np.int32),
            }
        )
        input_scale = RELU6_SCALE

    fc_w_fp = torch_weight_state(ckpt, "fc.weight")
    fc_b_fp = torch_weight_state(ckpt, "fc.bias")
    fc_w_q, fc_w_scale = quantize_weight_per_out_channel(fc_w_fp)
    fc_bias, fc_mul, fc_shift, fc_ozp, fc_min, fc_max = make_qparams(
        fc_b_fp,
        RELU6_SCALE,
        fc_w_scale,
        LOGIT_SCALE,
        False,
    )
    params.update(
        {
            "fc_weight": fc_w_q.astype(np.int8),
            "fc_bias": fc_bias,
            "fc_multiplier": fc_mul,
            "fc_shift": fc_shift,
            "fc_output_zero_point": np.asarray(fc_ozp, dtype=np.int32),
        }
    )

    logits, argmax = run_exported_int8_model(sample, params)
    params["expected_logits"] = np.asarray(logits, dtype=np.int8)
    params["expected_argmax"] = np.asarray(argmax, dtype=np.int32)

    eval_images = ckpt.get("eval_images_uint8")
    eval_labels = ckpt.get("eval_labels")
    if eval_images is not None and eval_labels is not None and args.accuracy_samples > 0:
        eval_images = np.asarray(eval_images, dtype=np.uint8)
        eval_labels = np.asarray(eval_labels, dtype=np.int64)
        sample_count = min(args.accuracy_samples, int(eval_labels.shape[0]))
        correct = 0
        for i in range(sample_count):
            _, pred = run_exported_int8_model(eval_images[i], params)
            correct += int(pred == int(eval_labels[i]))
        params["int8_eval_samples"] = np.asarray(sample_count, dtype=np.int32)
        params["int8_eval_acc"] = np.asarray(correct / max(1, sample_count), dtype=np.float32)
    else:
        params["int8_eval_samples"] = np.asarray(0, dtype=np.int32)
        params["int8_eval_acc"] = np.asarray(-1.0, dtype=np.float32)

    args.out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.out / "edgedscnet_c10_int8_smoke.npz", **params)
    write_i8_hex(args.vectors / "input_image.hex", params["input_image_i8"])
    write_i8_hex(args.vectors / "expected_logits.hex", logits)
    write_i8_hex(args.vectors / "expected_fullnet_logits.hex", logits)
    write_i32_words_hex(args.vectors / "expected_argmax.hex", [argmax])

    with (args.out / "model_export_summary.txt").open("w", encoding="ascii") as f:
        f.write("EdgeDSCNet-C10 int8 torch quantized export\n")
        f.write(f"checkpoint={args.ckpt}\n")
        f.write(f"checkpoint_backend={params['checkpoint_backend']}\n")
        f.write(f"checkpoint_eval_acc={float(params['checkpoint_eval_acc']):.6f}\n")
        f.write(f"int8_eval_samples={int(params['int8_eval_samples'])}\n")
        f.write(f"int8_eval_acc={float(params['int8_eval_acc']):.6f}\n")
        f.write(f"seed={args.seed}\n")
        f.write(f"logits={','.join(str(int(x)) for x in logits)}\n")
        f.write(f"argmax={argmax}\n")

    print(f"wrote {args.out / 'edgedscnet_c10_int8_smoke.npz'}")
    print(f"wrote {args.vectors / 'expected_logits.hex'}")
    print(
        "torch_quant argmax={argmax} logits={logits} checkpoint_eval_acc={eval_acc:.3f} "
        "int8_eval_acc={int8_acc:.3f} samples={samples}".format(
            argmax=argmax,
            logits=logits,
            eval_acc=float(params["checkpoint_eval_acc"]),
            int8_acc=float(params["int8_eval_acc"]),
            samples=int(params["int8_eval_samples"]),
        )
    )


def i8_image_from_uint8(image: np.ndarray) -> list[list[list[int]]]:
    centered = image.astype(np.int16) - 128
    centered = np.clip(centered, -128, 127).astype(np.int8)
    return centered.astype(np.int16).tolist()


def random_vec(rng: np.random.Generator, count: int, low: int, high: int) -> list[int]:
    return rng.integers(low, high + 1, size=count, dtype=np.int32).astype(int).tolist()


def random_qparams(rng: np.random.Generator, channels: int, relu: bool) -> tuple[list[int], list[int], list[int], int, int, int]:
    bias = random_vec(rng, channels, -256, 256)
    multiplier = random_vec(rng, channels, 1 << 28, 1 << 30)
    shift = random_vec(rng, channels, 6, 10)
    output_zero_point = int(rng.integers(-4, 5))
    activation_min = 0 if relu else -128
    activation_max = 48 if relu else 127
    return bias, multiplier, shift, output_zero_point, activation_min, activation_max


def write_i8_hex(path: Path, values: Any) -> None:
    flat = np.asarray(values, dtype=np.int16).reshape(-1)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as f:
        for value in flat:
            f.write(f"{int(value) & 0xff:02x}\n")


def write_i32_words_hex(path: Path, values: Any) -> None:
    flat = np.asarray(values, dtype=np.int64).reshape(-1)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii") as f:
        for value in flat:
            f.write(f"{hex_width(int(value), 32)}\n")


def flat_to_feature(flat: list[list[int]], h: int, w: int, channels: int) -> list[list[list[int]]]:
    return [
        [[flat[y * w + x][c] for c in range(channels)] for x in range(w)]
        for y in range(h)
    ]


def export_smoke_model(args: argparse.Namespace) -> None:
    torch_ckpt = load_torch_checkpoint(args.ckpt)
    if torch_ckpt is not None:
        export_torch_quantized_model(args, torch_ckpt)
        return

    image_u8, checkpoint_backend = load_checkpoint_sample(args.ckpt, args.seed)
    rng = np.random.default_rng(args.seed)
    feature = i8_image_from_uint8(image_u8)
    params: dict[str, Any] = {
        "checkpoint_backend": np.asarray(checkpoint_backend),
        "input_image_uint8": image_u8,
        "input_image_i8": np.asarray(feature, dtype=np.int8),
        "input_zero_point": np.asarray(0, dtype=np.int32),
    }

    relu_min = 0
    relu_max = 48
    input_zero_point = 0

    stem_weight = [random_vec(rng, 27, -3, 3) for _ in range(16)]
    stem_bias, stem_mul, stem_shift, stem_ozp, _, _ = random_qparams(rng, 16, True)
    out_h, out_w, stem_out = stem_same_golden(
        feature,
        input_zero_point,
        stem_weight,
        stem_bias,
        stem_mul,
        stem_shift,
        stem_ozp,
        relu_min,
        relu_max,
    )
    params.update(
        {
            "stem_weight": np.asarray(stem_weight, dtype=np.int8),
            "stem_bias": np.asarray(stem_bias, dtype=np.int32),
            "stem_multiplier": np.asarray(stem_mul, dtype=np.int32),
            "stem_shift": np.asarray(stem_shift, dtype=np.int32),
            "stem_output_zero_point": np.asarray(stem_ozp, dtype=np.int32),
        }
    )
    feature = flat_to_feature(stem_out, out_h, out_w, 16)
    prev_ozp = stem_ozp

    ds_specs = [
        (32, 32, 16, 32, 1),
        (32, 32, 32, 64, 2),
        (16, 16, 64, 64, 1),
        (16, 16, 64, 128, 2),
        (8, 8, 128, 128, 1),
        (8, 8, 128, 256, 2),
    ]

    for idx, (in_h, in_w, in_c, out_c, stride) in enumerate(ds_specs, start=1):
        dw_weight = [random_vec(rng, 9, -3, 3) for _ in range(in_c)]
        pw_weight = [random_vec(rng, in_c, -3, 3) for _ in range(out_c)]
        dw_bias, dw_mul, dw_shift, dw_ozp, _, _ = random_qparams(rng, in_c, True)
        pw_bias, pw_mul, pw_shift, pw_ozp, _, _ = random_qparams(rng, out_c, True)
        out_h, out_w, ds_out = dsblock_same_golden(
            feature,
            prev_ozp,
            dw_weight,
            dw_bias,
            dw_mul,
            dw_shift,
            pw_weight,
            pw_bias,
            pw_mul,
            pw_shift,
            stride,
            dw_ozp,
            relu_min,
            relu_max,
            pw_ozp,
            relu_min,
            relu_max,
        )
        params.update(
            {
                f"ds{idx}_dw_weight": np.asarray(dw_weight, dtype=np.int8),
                f"ds{idx}_dw_bias": np.asarray(dw_bias, dtype=np.int32),
                f"ds{idx}_dw_multiplier": np.asarray(dw_mul, dtype=np.int32),
                f"ds{idx}_dw_shift": np.asarray(dw_shift, dtype=np.int32),
                f"ds{idx}_dw_output_zero_point": np.asarray(dw_ozp, dtype=np.int32),
                f"ds{idx}_pw_weight": np.asarray(pw_weight, dtype=np.int8),
                f"ds{idx}_pw_bias": np.asarray(pw_bias, dtype=np.int32),
                f"ds{idx}_pw_multiplier": np.asarray(pw_mul, dtype=np.int32),
                f"ds{idx}_pw_shift": np.asarray(pw_shift, dtype=np.int32),
                f"ds{idx}_pw_output_zero_point": np.asarray(pw_ozp, dtype=np.int32),
            }
        )
        feature = flat_to_feature(ds_out, out_h, out_w, out_c)
        prev_ozp = pw_ozp

    gap = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        gap.append(saturate_int8(total >> 4))

    fc_weight = [random_vec(rng, 256, -3, 3) for _ in range(10)]
    fc_bias, fc_mul, fc_shift, fc_ozp, fc_min, fc_max = random_qparams(rng, 10, False)
    logits = fc_golden(gap, fc_weight, fc_bias, fc_mul, fc_shift, fc_ozp, fc_min, fc_max)
    argmax = int(np.argmax(np.asarray(logits, dtype=np.int16)))

    params.update(
        {
            "gap": np.asarray(gap, dtype=np.int8),
            "fc_weight": np.asarray(fc_weight, dtype=np.int8),
            "fc_bias": np.asarray(fc_bias, dtype=np.int32),
            "fc_multiplier": np.asarray(fc_mul, dtype=np.int32),
            "fc_shift": np.asarray(fc_shift, dtype=np.int32),
            "fc_output_zero_point": np.asarray(fc_ozp, dtype=np.int32),
            "expected_logits": np.asarray(logits, dtype=np.int8),
            "expected_argmax": np.asarray(argmax, dtype=np.int32),
        }
    )

    args.out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.out / "edgedscnet_c10_int8_smoke.npz", **params)
    write_i8_hex(args.vectors / "input_image.hex", params["input_image_i8"])
    write_i8_hex(args.vectors / "expected_logits.hex", logits)
    write_i8_hex(args.vectors / "expected_fullnet_logits.hex", logits)
    write_i32_words_hex(args.vectors / "expected_argmax.hex", [argmax])

    with (args.out / "model_export_summary.txt").open("w", encoding="ascii") as f:
        f.write("EdgeDSCNet-C10 int8 smoke export\n")
        f.write(f"checkpoint={args.ckpt}\n")
        f.write(f"checkpoint_backend={checkpoint_backend}\n")
        f.write(f"seed={args.seed}\n")
        f.write(f"logits={','.join(str(int(x)) for x in logits)}\n")
        f.write(f"argmax={argmax}\n")

    print(f"wrote {args.out / 'edgedscnet_c10_int8_smoke.npz'}")
    print(f"wrote {args.vectors / 'expected_logits.hex'}")
    print(f"argmax={argmax} logits={logits}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ckpt", type=Path, default=Path("build/model/edgedscnet_c10_smoke.npz"))
    parser.add_argument("--out", type=Path, default=Path("build/model_export"))
    parser.add_argument("--vectors", type=Path, default=Path("tests/vectors/training_smoke"))
    parser.add_argument("--seed", type=int, default=20260601)
    parser.add_argument(
        "--accuracy-samples",
        type=int,
        default=0,
        help="optional number of saved eval images to run through the int8 golden model",
    )
    return parser.parse_args()


def main() -> None:
    export_smoke_model(parse_args())


if __name__ == "__main__":
    main()
