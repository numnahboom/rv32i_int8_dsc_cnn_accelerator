#!/usr/bin/env python3
"""Export real frozen-D4 vectors for the standalone DW16 stream primitive.

The two cases are actual depthwise spatial layers from the D4 deployment
archive and an official CIFAR-10 test image.  Each case is one 8x8 output tile
for a 16-channel group: ``mb32.spatial`` at stride 1 and ``mb16_down.spatial``
at stride 2.  Source words contain the corresponding sixteen input channels;
the expected files contain the exact folded INT32 psum (including bias) and
the exact nearest-away-from-zero INT8 output used by the deployment evaluator.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from edgembconv_hwacandidate_d4_model import assert_locked_profile
from export_eval_edgembconv_hwacandidate_a import add_q, conv1_q, conv3_q, requant
from resnet20_hwqa import load_cifar10

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEPLOY = ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy"
DEFAULT_OUT = ROOT / "build/edgembconv_hwacandidate_d4_dw16_stream_vectors"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def hexword(value: int, bits: int) -> str:
    return f"{int(value) & ((1 << bits) - 1):0{(bits + 3) // 4}x}"


def load_params(deploy: Path) -> dict[str, np.ndarray]:
    archive = deploy / "edgembconv_hwacandidate_d4_int8.npz"
    if not archive.exists():
        raise FileNotFoundError(archive)
    return {k: v for k, v in np.load(archive).items()}


def load_scales(deploy: Path) -> dict[str, float]:
    import torch

    qat = deploy.parent / "edgembconv_hwacandidate_d4_qat.pt"
    q = torch.load(qat, map_location="cpu", weights_only=False)
    return {str(k): float(v) for k, v in q["scales"].items()}


def early_activations(params: dict[str, np.ndarray], image: np.ndarray,
                      scales: dict[str, float]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    stats: dict[str, int] = {}
    x = np.clip(image.astype(np.int16) - 128, -128, 127).astype(np.int8)[None]
    x = conv3_q(x, params["stem.weight"], params["stem.bias"],
                params["stem.multiplier"], params["stem.shift"], 1,
                "stem", stats)
    x = np.clip(x, 0, 127).astype(np.int8)
    stem = x.copy()
    x = conv1_q(x, params["mb32.expand.weight"], params["mb32.expand.bias"],
                params["mb32.expand.multiplier"], params["mb32.expand.shift"],
                1, "mb32.expand", stats)
    x = np.clip(x, 0, 127).astype(np.int8)
    mb32_expand = x.copy()
    x = conv3_q(x, params["mb32.spatial.weight"], params["mb32.spatial.bias"],
                params["mb32.spatial.multiplier"], params["mb32.spatial.shift"],
                1, "mb32.spatial", stats)
    mb32_spatial = np.clip(x, 0, 127).astype(np.int8)
    x = conv1_q(mb32_spatial, params["mb32.project.weight"], params["mb32.project.bias"],
                params["mb32.project.multiplier"], params["mb32.project.shift"],
                1, "mb32.project", stats)
    mb32_project = np.clip(x, -128, 127).astype(np.int8)
    mb32_out = add_q(stem, scales["stem"], mb32_project,
                     scales["mb32.project"], scales["mb32.out"])
    x = conv1_q(mb32_out, params["mb16_down.expand.weight"],
                params["mb16_down.expand.bias"],
                params["mb16_down.expand.multiplier"],
                params["mb16_down.expand.shift"], 1,
                "mb16_down.expand", stats)
    mb16_expand = np.clip(x, 0, 127).astype(np.int8)
    return mb32_expand, mb32_out, mb16_expand


def make_case(name: str, layer: str, x: np.ndarray, params: dict[str, np.ndarray],
              stride: int, channel_base: int, tile_x: int = 0,
              tile_y: int = 0, tile_w: int = 8, tile_h: int = 8) -> dict[str, object]:
    w = params[layer + ".weight"]
    bias = params[layer + ".bias"].astype(np.int64)
    mul = params[layer + ".multiplier"].astype(np.int32)
    shift = params[layer + ".shift"].astype(np.uint8)
    in_h, in_w, in_c = map(int, x.shape[1:])
    out_h = (in_h + stride - 1) // stride
    out_w = (in_w + stride - 1) // stride
    if w.shape != (in_c, 1, 3, 3):
        raise ValueError(f"{layer}: expected DW shape {(in_c, 1, 3, 3)}, got {w.shape}")
    if channel_base % 16 or channel_base + 16 > in_c:
        raise ValueError("channel group must be a valid 16-channel group")

    source_words: list[int] = []
    # The source word ABI is a group-local 128-bit word per spatial pixel,
    # lane 0 in bits [7:0], at address y*in_w+x.
    for y in range(in_h):
        for xx in range(in_w):
            word = 0
            for lane in range(16):
                word |= (int(x[0, y, xx, channel_base + lane]) & 0xff) << (8 * lane)
            source_words.append(word)

    expected: list[int] = []
    raw: list[int] = []
    for oy in range(tile_h):
        gy = tile_y + oy
        for ox in range(tile_w):
            gx = tile_x + ox
            raw_pixel: list[int] = []
            out_pixel: list[int] = []
            for lane in range(16):
                channel = channel_base + lane
                acc = int(bias[channel])
                for ky in range(3):
                    iy = gy * stride + ky - 1
                    for kx in range(3):
                        ix = gx * stride + kx - 1
                        if 0 <= iy < in_h and 0 <= ix < in_w:
                            acc += int(x[0, iy, ix, channel]) * int(w[channel, 0, ky, kx])
                raw_pixel.append(acc)
                # conv3_q uses the same integer multiplier/shift and clamps
                # later to ReLU6 [0,127] for these D4 spatial layers.
                out_pixel.append(int(requant(np.asarray(acc, dtype=np.int64),
                                             mul[channel], shift[channel], 0, 127)))
            raw.extend(raw_pixel)
            expected.extend(out_pixel)

    prefix = name
    files = {
        "source_words": f"{prefix}_source_words.mem",
        "expected": f"{prefix}_expected.mem",
        "raw_psum": f"{prefix}_raw_psum.mem",
        "weights": f"{prefix}_weights.mem",
        "bias": f"{prefix}_bias.mem",
        "multiplier": f"{prefix}_multiplier.mem",
        "shift": f"{prefix}_shift.mem",
    }
    return {
        "name": name, "layer": layer, "stride": stride,
        "input_shape_nhwc": [1, in_h, in_w, in_c],
        "output_shape_nhwc": [1, out_h, out_w, in_c],
        "tile": {"x": tile_x, "y": tile_y, "w": tile_w, "h": tile_h},
        "channel_base": channel_base, "channel_mask": 0xffff,
        "source_word_count": len(source_words), "output_pixel_count": tile_w * tile_h,
        "semantic_macs": tile_w * tile_h * 16 * 9,
        "source_words": source_words, "expected": expected, "raw_psum": raw,
        "weights": [int(w[channel_base + lane, 0, ky, kx]) & 0xff
                    for lane in range(16) for ky in range(3) for kx in range(3)],
        "bias": [int(bias[channel_base + lane]) & 0xffffffff for lane in range(16)],
        "multiplier": [int(mul[channel_base + lane]) & 0xffffffff for lane in range(16)],
        "shift": [int(shift[channel_base + lane]) for lane in range(16)],
        "files": files,
    }


def write_case(out: Path, case: dict[str, object]) -> None:
    files = case["files"]
    (out / files["source_words"]).write_text(
        "\n".join(hexword(v, 128) for v in case["source_words"]) + "\n", encoding="ascii")
    (out / files["expected"]).write_text(
        "\n".join(hexword(sum((v & 0xff) << (8 * lane) for lane, v in enumerate(case["expected"][i * 16:(i + 1) * 16])), 128)
                          for i in range(case["output_pixel_count"])) + "\n", encoding="ascii")
    (out / files["raw_psum"]).write_text(
        "\n".join(hexword(sum((v & 0xffffffff) << (32 * lane) for lane, v in enumerate(case["raw_psum"][i * 16:(i + 1) * 16])), 512)
                          for i in range(case["output_pixel_count"])) + "\n", encoding="ascii")
    (out / files["weights"]).write_text("\n".join(hexword(v, 8) for v in case["weights"]) + "\n", encoding="ascii")
    for key in ("bias", "multiplier"):
        (out / files[key]).write_text("\n".join(hexword(v, 32) for v in case[key]) + "\n", encoding="ascii")
    (out / files["shift"]).write_text("\n".join(hexword(v, 8) for v in case["shift"]) + "\n", encoding="ascii")
    case["file_sha256"] = {key: sha256(out / path) for key, path in files.items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deploy", type=Path, default=DEFAULT_DEPLOY)
    ap.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--sample", type=int, default=0)
    args = ap.parse_args()
    assert_locked_profile()
    args.out.mkdir(parents=True, exist_ok=True)
    params = load_params(args.deploy)
    scales = load_scales(args.deploy)
    images, labels = load_cifar10(args.data, "test")
    mb32_expand, mb32_out, mb16_expand = early_activations(params, images[args.sample], scales)
    cases = [
        make_case("mb32_stride1_dw16", "mb32.spatial", mb32_expand,
                   params, 1, 0),
        make_case("mb16_down_stride2_dw16", "mb16_down.spatial", mb16_expand,
                   params, 2, 16),
    ]
    for case in cases:
        write_case(args.out, case)
    archive = args.deploy / "edgembconv_hwacandidate_d4_int8.npz"
    manifest = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-dw16-stream-v1",
        "variant_id": "D4", "sample": int(args.sample), "label": int(labels[args.sample]),
        "source_deploy": str(archive), "source_deploy_sha256": sha256(archive),
        "interface": {
            "source": "one 128-bit word per spatial address y*in_w+x, lane0 in bits [7:0]",
            "request": "decoupled synchronous word request/response, in-order, at most one outstanding",
            "weights": "lane*9+tap, tap order ky-major then kx",
            "outputs": "one 128-bit INT8 vector per tile pixel, lane0 in bits [7:0]",
            "padding": "SAME zero byte; output clamp [0,127] for D4 spatial ReLU6",
        },
        "cases": [],
    }
    for case in cases:
        manifest["cases"].append({k: v for k, v in case.items()
                                   if k not in ("source_words", "expected", "raw_psum", "weights", "bias", "multiplier", "shift")})
    (args.out / "d4_dw16_stream_vector_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "out": str(args.out), "sample": int(args.sample),
                      "label": int(labels[args.sample]),
                      "cases": [{"name": c["name"], "shape": c["input_shape_nhwc"],
                                 "stride": c["stride"], "semantic_macs": c["semantic_macs"]} for c in cases]}, indent=2))


if __name__ == "__main__":
    main()
