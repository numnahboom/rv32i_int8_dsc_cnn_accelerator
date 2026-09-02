#!/usr/bin/env python3
"""Export real D4 deployment vectors for the first 128-MAC PW tiles.

The vectors are derived from the frozen D4 INT8 deployment archive and an
official CIFAR-10 test image.  ``mb32.expand`` is the requested first tile
(Cin=16); a second real D4 tile, ``mb16.1.expand`` (Cin=32), is emitted to
exercise a 32-token partial-K reduction as well.  Both files contain raw
INT32 dot products before the separately represented folded bias.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from edgembconv_hwacandidate_d4_model import assert_locked_profile
from export_eval_edgembconv_hwacandidate_a import add_q, conv1_q, conv3_q
from resnet20_hwqa import load_cifar10

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEPLOY = ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy"
DEFAULT_OUT = ROOT / "build/edgembconv_hwacandidate_d4_dense128_vectors"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def hex_word(value: int, bits: int) -> str:
    return f"{int(value) & ((1 << bits) - 1):0{(bits + 3) // 4}x}"


def load_npz(deploy: Path) -> dict[str, np.ndarray]:
    archive = deploy / "edgembconv_hwacandidate_d4_int8.npz"
    if not archive.exists():
        raise FileNotFoundError(archive)
    return {k: v for k, v in np.load(archive).items()}


def d4_early_activations(params: dict[str, np.ndarray], sample: np.ndarray,
                         scales: dict[str, float]) -> tuple[np.ndarray, np.ndarray]:
    """Return stem output and mb16_down output using the deploy integer ABI."""
    stats: dict[str, int] = {}
    x = np.clip(sample.astype(np.int16) - 128, -128, 127).astype(np.int8)[None]
    x = conv3_q(x, params["stem.weight"], params["stem.bias"],
                params["stem.multiplier"], params["stem.shift"], 1,
                "stem", stats)
    x = np.clip(x, 0, 127).astype(np.int8)
    stem = x.copy()
    in_scale = scales["stem"]

    def mb(prefix: str, stride: int, residual: bool) -> None:
        nonlocal x, in_scale
        identity = x.copy() if residual else None
        identity_scale = in_scale
        x = conv1_q(x, params[prefix + ".expand.weight"],
                    params[prefix + ".expand.bias"],
                    params[prefix + ".expand.multiplier"],
                    params[prefix + ".expand.shift"], 1,
                    prefix + ".expand", stats)
        x = np.clip(x, 0, 127).astype(np.int8)
        x = conv3_q(x, params[prefix + ".spatial.weight"],
                    params[prefix + ".spatial.bias"],
                    params[prefix + ".spatial.multiplier"],
                    params[prefix + ".spatial.shift"], stride,
                    prefix + ".spatial", stats)
        x = np.clip(x, 0, 127).astype(np.int8)
        x = conv1_q(x, params[prefix + ".project.weight"],
                    params[prefix + ".project.bias"],
                    params[prefix + ".project.multiplier"],
                    params[prefix + ".project.shift"], 1,
                    prefix + ".project", stats)
        if residual:
            x = add_q(identity, identity_scale, x,
                      scales[prefix + ".project"], scales[prefix + ".out"])
        in_scale = scales[prefix + ".out"]

    mb("mb32", 1, True)
    mb("mb16_down", 2, False)
    return stem, x


def make_tile(layer: str, x: np.ndarray, params: dict[str, np.ndarray],
              tile_y: int = 0, tile_x: int = 0) -> dict[str, object]:
    w = params[layer + ".weight"]
    bias = params[layer + ".bias"]
    if w.ndim != 4 or w.shape[2:] != (1, 1):
        raise ValueError(f"{layer}: expected 1x1 weight, got {w.shape}")
    cout, cin = int(w.shape[0]), int(w.shape[1])
    if cout < 16 or cin not in (16, 32):
        raise ValueError(f"{layer}: unexpected shape {w.shape}")
    if x.shape[1] <= tile_y or x.shape[2] < tile_x + 8 or x.shape[3] < cin:
        raise ValueError(f"{layer}: tile outside activation shape {x.shape}")

    # The first Cout tile is deliberately fixed to 0..15, matching the RTL
    # lane contract.  The tile is a real activation point from the official
    # test image, not generated arithmetic data.
    pixels = [int(x[0, tile_y, tile_x + p, k]) for k in range(cin)
              for p in range(8)]
    acts = [[int(x[0, tile_y, tile_x + p, k]) for p in range(8)]
            for k in range(cin)]
    weights = [[int(w[c, k, 0, 0]) for c in range(16)] for k in range(cin)]
    psum = [[sum(acts[k][p] * weights[k][c] for k in range(cin))
             for c in range(16)] for p in range(8)]

    tokens: list[str] = []
    for k in range(cin):
        act_word = sum((acts[k][p] & 0xff) << (8 * p) for p in range(8))
        wgt_word = sum((weights[k][c] & 0xff) << (8 * c) for c in range(16))
        token = act_word | (wgt_word << 64)
        token |= (int(k) & 0xff) << 194
        token |= (1 if k == 0 else 0) << 192
        token |= (1 if k == cin - 1 else 0) << 193
        token |= 0xff << 202
        token |= 0xffff << 210
        # [257:226] is a stable tile metadata field.  It is also repeated in
        # the JSON so the testbench can check the sideband independently.
        token |= ((tile_y & 0xff) | ((tile_x & 0xff) << 8) |
                  ((cin & 0xff) << 16) | ((layer == "mb16.1.expand") << 24)) << 226
        tokens.append(hex_word(token, 258))

    return {
        "layer": layer,
        "cin": cin,
        "cout": 16,
        "pixels": 8,
        "tile_y": tile_y,
        "tile_x": tile_x,
        "tokens": tokens,
        "psum": [int(psum[p][c]) for p in range(8) for c in range(16)],
        "bias": [int(v) for v in bias[:16]],
        "semantic_macs": 8 * 16 * cin,
        "arithmetic_ops": 2 * 8 * 16 * cin,
        "metadata": (tile_y & 0xff) | ((tile_x & 0xff) << 8) |
                    ((cin & 0xff) << 16) |
                    ((layer == "mb16.1.expand") << 24),
    }


def write_tile(out: Path, tile: dict[str, object]) -> None:
    stem = "d4_dense128_" + str(tile["layer"]).replace(".", "_")
    (out / f"{stem}_tokens.mem").write_text("\n".join(tile["tokens"]) + "\n", encoding="ascii")
    (out / f"{stem}_psum.mem").write_text("\n".join(hex_word(v, 32) for v in tile["psum"]) + "\n", encoding="ascii")
    (out / f"{stem}_bias.mem").write_text("\n".join(hex_word(v, 32) for v in tile["bias"]) + "\n", encoding="ascii")
    tile["files"] = {"tokens": f"{stem}_tokens.mem", "psum": f"{stem}_psum.mem", "bias": f"{stem}_bias.mem"}
    tile["file_sha256"] = {kind: sha256(out / name) for kind, name in tile["files"].items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--deploy", type=Path, default=DEFAULT_DEPLOY)
    ap.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--sample", type=int, default=0)
    args = ap.parse_args()
    assert_locked_profile()
    args.out.mkdir(parents=True, exist_ok=True)
    params = load_npz(args.deploy)
    images, labels = load_cifar10(args.data, "test")
    sample = images[args.sample]
    # The scales are deployment metadata, not guessed values.
    manifest = json.loads((args.deploy / "edgembconv_hwacandidate_d4_deploy_manifest.json").read_text(encoding="utf-8"))
    scales = {str(layer["name"]): float(layer["out_scale"])
              for layer in manifest["layers"] if "out_scale" in layer}
    scales["mb32.out"] = scales["mb32.project"]
    scales["mb16_down.out"] = scales["mb16_down.project"]
    stem, mb16_down = d4_early_activations(params, sample, scales)
    tiles = [make_tile("mb32.expand", stem, params),
             make_tile("mb16.1.expand", mb16_down, params)]
    for tile in tiles:
        write_tile(args.out, tile)
    source_archive = args.deploy / "edgembconv_hwacandidate_d4_int8.npz"
    meta = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-dense128-vectors-v1",
        "variant_id": "D4", "source_deploy": str(source_archive),
        "source_deploy_sha256": sha256(source_archive), "sample": int(args.sample),
        "label": int(labels[args.sample]), "input": "official CIFAR-10 test split",
        "activation_pipeline": "exported INT8 stem -> mb32.expand/residual -> mb16_down",
        "interface": {"act": "signed int8 p0..p7", "weight": "signed int8 cout0..cout15",
                      "psum": "signed int32 raw dot product, bias separate",
                      "metadata": "[257:226] tile_y,tile_x,cin,layer_id"},
        "tiles": tiles,
    }
    (args.out / "d4_dense128_vector_manifest.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "out": str(args.out),
                      "sample": int(args.sample), "label": int(labels[args.sample]),
                      "tiles": [{"layer": t["layer"], "cin": t["cin"],
                                 "semantic_macs": t["semantic_macs"]} for t in tiles]}, indent=2))


if __name__ == "__main__":
    main()
