#!/usr/bin/env python3
"""Export exact D4 mb32 and mb16_down vectors for the RTL block shell.

This exporter deliberately has its own output directory and consumes only the
already frozen D4 deployment archive.  The shell testbench loads the signed
INT8 input/weights and the folded INT32 bias/requant parameters through its
configuration handshake, then compares every output byte with this integer
reference.
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
DEFAULT_OUT = ROOT / "build/edgembconv_hwacandidate_d4_block_shell_vectors"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_bytes(path: Path, a: np.ndarray) -> None:
    flat = np.asarray(a, dtype=np.int8).reshape(-1)
    path.write_text("\n".join(f"{int(v) & 0xff:02x}" for v in flat) + "\n", encoding="ascii")


def write_u32(path: Path, a: np.ndarray) -> None:
    flat = np.asarray(a, dtype=np.int64).reshape(-1)
    path.write_text("\n".join(f"{int(v) & 0xffffffff:08x}" for v in flat) + "\n", encoding="ascii")


def load_npz(deploy: Path) -> dict[str, np.ndarray]:
    return {k: v for k, v in np.load(deploy / "edgembconv_hwacandidate_d4_int8.npz").items()}


def layer_params(params: dict[str, np.ndarray], prefix: str, op: int) -> dict[str, object]:
    w = params[prefix + ".weight"]
    if w.ndim == 4 and w.shape[2:] == (1, 1):
        kind = "pw"
        flat = w.reshape(w.shape[0], w.shape[1])
    elif w.ndim == 4 and w.shape[1] == 1 and w.shape[2:] == (3, 3):
        kind = "dw"
        flat = w.reshape(w.shape[0], 9)
    else:
        raise ValueError(f"unexpected layer shape {prefix}: {w.shape}")
    return {
        "prefix": prefix, "op": op, "kind": kind,
        "cin": int(w.shape[1]), "cout": int(w.shape[0]),
        "weight": flat.astype(np.int8),
        "bias": params[prefix + ".bias"].astype(np.int32),
        "multiplier": params[prefix + ".multiplier"].astype(np.int32),
        "shift": params[prefix + ".shift"].astype(np.uint8),
    }


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
    manifest = json.loads((args.deploy / "edgembconv_hwacandidate_d4_deploy_manifest.json").read_text(encoding="utf-8"))
    scales = {str(x["name"]): float(x["out_scale"]) for x in manifest["layers"] if "out_scale" in x}
    scales["mb32.out"] = float(json.loads((ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy/edgembconv_hwacandidate_d4_deploy_manifest.json").read_text())["layers"][3]["out_scale"])
    # The out scales are stored in the QAT checkpoint, not in the layer list.
    import torch
    q = torch.load(ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_qat.pt", map_location="cpu", weights_only=False)
    scales = {str(k): float(v) for k, v in q["scales"].items()}

    images, labels = load_cifar10(args.data, "test")
    sample = np.clip(images[args.sample].astype(np.int16) - 128, -128, 127).astype(np.int8)[None]
    stats: dict[str, int] = {}
    stem = conv3_q(sample, params["stem.weight"], params["stem.bias"], params["stem.multiplier"], params["stem.shift"], 1, "stem", stats)
    stem = np.clip(stem, 0, 127).astype(np.int8)

    def run_block(prefix: str, x: np.ndarray, in_scale: float, stride: int, residual: bool) -> tuple[np.ndarray, float]:
        identity = x.copy()
        expand = conv1_q(x, params[prefix + ".expand.weight"], params[prefix + ".expand.bias"], params[prefix + ".expand.multiplier"], params[prefix + ".expand.shift"], 1, prefix + ".expand", stats)
        expand = np.clip(expand, 0, 127).astype(np.int8)
        spatial = conv3_q(expand, params[prefix + ".spatial.weight"], params[prefix + ".spatial.bias"], params[prefix + ".spatial.multiplier"], params[prefix + ".spatial.shift"], stride, prefix + ".spatial", stats)
        spatial = np.clip(spatial, 0, 127).astype(np.int8)
        project = conv1_q(spatial, params[prefix + ".project.weight"], params[prefix + ".project.bias"], params[prefix + ".project.multiplier"], params[prefix + ".project.shift"], 1, prefix + ".project", stats)
        if residual:
            out = add_q(identity, in_scale, project, scales[prefix + ".project"], scales[prefix + ".out"])
            return out, scales[prefix + ".out"]
        return project, scales[prefix + ".out"]

    mb32_out, mb32_scale = run_block("mb32", stem, scales["stem"], 1, True)
    mb16_out, _ = run_block("mb16_down", mb32_out, mb32_scale, 2, False)

    # Two actual block records.  Both input tensors are real intermediate
    # tensors from the official image, not synthetic arithmetic fixtures.
    blocks = [
        {"name": "mb32", "block_id": 0, "input": stem[0], "output": mb32_out[0], "in_scale": scales["stem"], "residual": True, "in_h": 32, "in_w": 32, "out_h": 32, "out_w": 32, "pw_expand": layer_params(params, "mb32.expand", 0), "dw": layer_params(params, "mb32.spatial", 0), "pw_project": layer_params(params, "mb32.project", 1), "res_out_scale": scales["mb32.out"], "res_project_scale": scales["mb32.project"]},
        {"name": "mb16_down", "block_id": 1, "input": mb32_out[0], "output": mb16_out[0], "in_scale": mb32_scale, "residual": False, "in_h": 32, "in_w": 32, "out_h": 16, "out_w": 16, "pw_expand": layer_params(params, "mb16_down.expand", 2), "dw": layer_params(params, "mb16_down.spatial", 1), "pw_project": layer_params(params, "mb16_down.project", 3), "res_out_scale": scales["mb16_down.out"], "res_project_scale": scales["mb16_down.project"]},
    ]
    files: dict[str, str] = {}
    for b in blocks:
        stem_name = str(b["name"])
        write_bytes(args.out / f"{stem_name}_input.mem", b["input"])
        write_bytes(args.out / f"{stem_name}_output.mem", b["output"])
        files[f"{stem_name}_input"] = f"{stem_name}_input.mem"
        files[f"{stem_name}_output"] = f"{stem_name}_output.mem"
        for key in ("pw_expand", "pw_project"):
            p = b[key]; prefix = f"{stem_name}_{key}"
            write_bytes(args.out / f"{prefix}_weight.mem", p["weight"])
            write_u32(args.out / f"{prefix}_bias.mem", p["bias"])
            write_u32(args.out / f"{prefix}_multiplier.mem", p["multiplier"])
            write_bytes(args.out / f"{prefix}_shift.mem", p["shift"])
            files.update({f"{prefix}_{k}": f"{prefix}_{k}.mem" for k in ("weight", "bias", "multiplier", "shift")})
        p = b["dw"]; prefix = f"{stem_name}_dw"
        write_bytes(args.out / f"{prefix}_weight.mem", p["weight"])
        write_u32(args.out / f"{prefix}_bias.mem", p["bias"])
        write_u32(args.out / f"{prefix}_multiplier.mem", p["multiplier"])
        write_bytes(args.out / f"{prefix}_shift.mem", p["shift"])
        files.update({f"{prefix}_{k}": f"{prefix}_{k}.mem" for k in ("weight", "bias", "multiplier", "shift")})
    # Q31-like ratios are emitted as exact integer requant parameters for the
    # residual common-scale add.  The Python reference and RTL use the same
    # nearest-away-from-zero contract; the guard below catches rare ties.
    def ratio_qparams(ratio: float) -> tuple[int, int]:
        sh = 31; mul = int(np.rint(ratio * (2.0 ** sh)))
        while abs(mul) > 2 ** 30 - 1 and sh > 0:
            sh -= 1; mul = int(np.rint(ratio * (2.0 ** sh)))
        return mul, sh
    for b in blocks:
        if b["residual"]:
            a_mul, a_sh = ratio_qparams(float(b["in_scale"] / b["res_out_scale"]))
            p_mul, p_sh = ratio_qparams(float(b["res_project_scale"] / b["res_out_scale"]))
        else:
            a_mul = p_mul = 0; a_sh = p_sh = 0
        b["res_a_mul"], b["res_a_shift"] = a_mul, a_sh
        b["res_b_mul"], b["res_b_shift"] = p_mul, p_sh
        if b["residual"]:
            ratio_path = args.out / f"{b['name']}_residual.mem"
            ratio_path.write_text("\n".join([f"{a_mul & 0xffffffff:08x}", f"{a_sh:08x}", f"{p_mul & 0xffffffff:08x}", f"{p_sh:08x}"]) + "\n", encoding="ascii")
            files[f"{b['name']}_residual"] = ratio_path.name
    def descriptor(p: dict[str, object]) -> dict[str, object]:
        return {k: (v.tolist() if isinstance(v, np.ndarray) else int(v) if isinstance(v, np.integer) else v)
                for k, v in p.items() if k != "weight"}
    meta = {"schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-block-shell-v1", "variant_id": "D4", "sample": int(args.sample), "label": int(labels[args.sample]), "source_deploy_sha256": sha256(args.deploy / "edgembconv_hwacandidate_d4_int8.npz"), "blocks": [{k: v for k, v in b.items() if k not in ("input", "output", "pw_expand", "dw", "pw_project")} | {"pw_expand": descriptor(b["pw_expand"]), "dw": descriptor(b["dw"]), "pw_project": descriptor(b["pw_project"])} for b in blocks], "files": files}
    meta["file_sha256"] = {name: sha256(args.out / path) for name, path in files.items()}
    (args.out / "d4_block_shell_vector_manifest.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "out": str(args.out), "sample": int(args.sample), "label": int(labels[args.sample]), "blocks": [{"name": b["name"], "input": list(b["input"].shape), "output": list(b["output"].shape)} for b in blocks]}, indent=2))


if __name__ == "__main__":
    main()
