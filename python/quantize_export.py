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
    return parser.parse_args()


def main() -> None:
    export_smoke_model(parse_args())


if __name__ == "__main__":
    main()
