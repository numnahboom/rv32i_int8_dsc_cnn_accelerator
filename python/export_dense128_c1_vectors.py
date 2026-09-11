#!/usr/bin/env python3
"""Export a real CIFAR-10 C1 stem trace for dense128_os_8x16.

The trace is deliberately derived from the frozen ResNet-20 deployment
artifact, not synthetic/random parameters.  It contains every 32x32 output
pixel in 128 eight-pixel tiles, all 27 [Cin][Ky][Kx] reduction tokens, the
INT32 accumulator golden, and the exact INT8 requant golden.  ``$readmemh``
can consume the generated files directly from the RTL testbench.
"""
from __future__ import annotations

import argparse
import json
import pickle
from pathlib import Path

import numpy as np


def round_away_ratio(acc: int, multiplier: int, shift: int) -> int:
    product = int(acc) * int(multiplier)
    magnitude = abs(product)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return -rounded if product < 0 else rounded


def load_test_image(data_root: Path, sample: int) -> tuple[np.ndarray, int]:
    path = data_root / "cifar-10-batches-py" / "test_batch"
    with path.open("rb") as f:
        item = pickle.load(f, encoding="latin1")
    images = np.asarray(item["data"], dtype=np.uint8).reshape(-1, 3, 32, 32)
    image = images[sample].transpose(1, 2, 0).astype(np.int16) - 128
    image = np.clip(image, -128, 127).astype(np.int8)
    return image, int(item["labels"][sample])


def byte_hex(value: int) -> str:
    return f"{(int(value) & 0xff):02x}"


def word_hex(value: int, width: int) -> str:
    return f"{(int(value) & ((1 << width) - 1)):0{width // 4}x}"


def export(args: argparse.Namespace) -> None:
    deploy = args.deploy
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    params = np.load(deploy / "resnet20_hwqa_int8.npz")
    image, label = load_test_image(args.data, args.sample)
    weights = params["stem.weight"].astype(np.int32)  # [cout, cin, ky, kx]
    bias = params["stem.bias"].astype(np.int64)
    multiplier = params["stem.multiplier"].astype(np.int64)
    shift = params["stem.shift"].astype(np.int32)
    if weights.shape != (16, 3, 3, 3):
        raise ValueError(f"unexpected stem weight shape: {weights.shape}")

    # Tile pixels are row-major output positions.  The 8 lanes are always
    # valid for this full 32x32 trace; halo values are the real SAME-padding
    # zero operands, not K-padding inserted to fake throughput.
    token_lines: list[str] = []
    psum_lines: list[str] = []
    output_lines: list[str] = []
    tile_count = 0
    semantic_macs = 0
    for tile_base in range(0, 32 * 32, 8):
        tile_pixels = list(range(tile_base, tile_base + 8))
        accum = np.zeros((8, 16), dtype=np.int64)
        for k in range(27):
            ci, rem = divmod(k, 9)
            ky, kx = divmod(rem, 3)
            acts: list[int] = []
            for p in tile_pixels:
                y, x = divmod(p, 32)
                sy, sx = y + ky - 1, x + kx - 1
                acts.append(int(image[sy, sx, ci]) if 0 <= sy < 32 and 0 <= sx < 32 else 0)
            w0 = [int(weights[co, ci, ky, kx]) for co in range(8)]
            w1 = [int(weights[co, ci, ky, kx]) for co in range(8, 16)]
            for pi, act in enumerate(acts):
                for co in range(16):
                    accum[pi, co] += act * int(weights[co, ci, ky, kx])
            act_word = sum((int(v) & 0xff) << (8 * i) for i, v in enumerate(acts))
            lo_word = sum((int(v) & 0xff) << (8 * i) for i, v in enumerate(w0))
            hi_word = sum((int(v) & 0xff) << (8 * i) for i, v in enumerate(w1))
            # [201]=last, [200]=first, [199:192]=k, [191:128]=hi,
            # [127:64]=lo, [63:0]=shared activation.
            token = act_word | (lo_word << 64) | (hi_word << 128) | (k << 192)
            if k == 0:
                token |= 1 << 200
            if k == 26:
                token |= 1 << 201
            token_lines.append(word_hex(token, 256))
        for pi in range(8):
            for co in range(16):
                # The MAC primitive's psum contract excludes bias; the
                # existing exact requantizer consumes bias as a separate
                # operand.  Keep both forms distinct in the trace.
                raw_acc = int(accum[pi, co])
                psum_lines.append(word_hex(raw_acc, 32))
                acc = raw_acc + int(bias[co])
                q = round_away_ratio(acc, int(multiplier[co]), int(shift[co]))
                q = max(-128, min(127, q))
                output_lines.append(byte_hex(q))
        tile_count += 1
        semantic_macs += 8 * 16 * 27

    (out / "dense128_c1_tokens.mem").write_text("\n".join(token_lines) + "\n", encoding="ascii")
    (out / "dense128_c1_psum.mem").write_text("\n".join(psum_lines) + "\n", encoding="ascii")
    (out / "dense128_c1_output.mem").write_text("\n".join(output_lines) + "\n", encoding="ascii")
    (out / "dense128_c1_bias.mem").write_text("\n".join(word_hex(v, 32) for v in bias) + "\n", encoding="ascii")
    (out / "dense128_c1_multiplier.mem").write_text("\n".join(word_hex(v, 32) for v in multiplier) + "\n", encoding="ascii")
    (out / "dense128_c1_shift.mem").write_text("\n".join(word_hex(v, 8) for v in shift) + "\n", encoding="ascii")
    meta = {
        "schema": "C10-HWQA-v1-dense128-c1-trace",
        "source": str(deploy / "resnet20_hwqa_int8.npz"),
        "input": "official CIFAR-10 test_batch",
        "sample": args.sample,
        "label": label,
        "input_quantization": "clip(raw_uint8-128,-128,127)",
        "weight_layout": "stem.weight[cout,cin,ky,kx]",
        "k_order": "[cin][ky][kx]",
        "padding": "SAME, zero outside 32x32",
        "pixels": 1024,
        "tile_pixels": 8,
        "tiles": tile_count,
        "k": 27,
        "cout": 16,
        "token_count": len(token_lines),
        "semantic_macs": semantic_macs,
        "ideal_mac_cycles": semantic_macs // 128,
        "files": {
            "tokens": "dense128_c1_tokens.mem",
            "psum": "dense128_c1_psum.mem",
            "output": "dense128_c1_output.mem",
            "bias": "dense128_c1_bias.mem",
            "multiplier": "dense128_c1_multiplier.mem",
            "shift": "dense128_c1_shift.mem",
        },
    }
    (out / "dense128_c1_meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(meta, indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    parser.add_argument("--deploy", type=Path, default=Path("build/resnet20_hwqa_deploy"))
    parser.add_argument("--out", type=Path, default=Path("build/dense128_c1_vectors"))
    parser.add_argument("--sample", type=int, default=0)
    return parser.parse_args()


if __name__ == "__main__":
    export(parse_args())
