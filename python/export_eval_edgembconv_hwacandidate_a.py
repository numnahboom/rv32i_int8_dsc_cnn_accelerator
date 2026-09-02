#!/usr/bin/env python3
"""Export and evaluate locked EdgeMBConv candidate A.

The exporter is intentionally integer-first: each convolution quantizes its
weights per output channel, forms an int32-contract accumulator (the Python
reference uses int64 and checks the int32 bound), adds an int32 bias in
input-scale*weight-scale units, then applies nearest-away-from-zero scaling and
int8 saturation.  BN has already been folded before QAT.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import DataLoader

from edgembconv_hwacandidate_a_model import (
    INPUT_SCALE,
    EdgeMBConvCandidateA,
    assert_locked_profile,
)
from resnet20_hwqa import CifarDataset, load_cifar10, seed_everything


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_QAT = ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_a_qat.pt"
DEFAULT_FP32 = ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_a_fp32.pt"
DEFAULT_OUT = ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_a_deploy"
DEFAULT_RESULT = ROOT / "build" / "edgembconv_hwacandidate" / "edgembconv_hwacandidate_a_test10k.json"
DEFAULT_REPORT = ROOT / "docs" / "reports" / "edgembconv_hwacandidate_a_hwqa_report_20260902.md"


def load_state(path: Path) -> dict[str, Any]:
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def round_away(x: np.ndarray | float) -> np.ndarray:
    a = np.asarray(x)
    mag = np.floor(np.abs(a) + 0.5).astype(np.int64)
    return np.where(a < 0, -mag, mag)


def quant_weight(w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    flat = w.reshape(w.shape[0], -1).astype(np.float64)
    scale = np.maximum(np.max(np.abs(flat), axis=1) / 127.0, 1e-12)
    q = np.clip(round_away(flat / scale[:, None]), -127, 127).astype(np.int8)
    return q.reshape(w.shape), scale.astype(np.float64)


def ratio_qparams(ratio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    ratio = np.asarray(ratio, dtype=np.float64)
    shifts = np.full(ratio.shape, 31, dtype=np.int32)
    mul = np.rint(ratio * (2.0 ** 31)).astype(np.int64)
    for i in np.ndindex(ratio.shape):
        while abs(int(mul[i])) > 2 ** 30 - 1 and int(shifts[i]) > 0:
            shifts[i] -= 1
            mul[i] = int(np.rint(ratio[i] * (2.0 ** int(shifts[i]))))
    return mul.astype(np.int32), shifts


def requant(acc: np.ndarray, multiplier: np.ndarray, shift: np.ndarray, qmin: int = -128, qmax: int = 127) -> np.ndarray:
    p = acc.astype(np.int64) * np.asarray(multiplier, dtype=np.int64)
    d = 2 ** np.asarray(shift, dtype=np.int64)
    q = round_away(p / d)
    return np.clip(q, qmin, qmax).astype(np.int8)


def check_acc(acc: np.ndarray, label: str, stats: dict[str, int]) -> None:
    peak = int(np.max(np.abs(acc))) if acc.size else 0
    stats["max_abs_accumulator"] = max(stats.get("max_abs_accumulator", 0), peak)
    stats["accumulator_checks"] = stats.get("accumulator_checks", 0) + 1
    if peak > 2 ** 31 - 1:
        raise OverflowError(f"{label} exceeds int32 contract: {peak}")


def conv3_q(x: np.ndarray, w: np.ndarray, bias: np.ndarray, mul: np.ndarray, shift: np.ndarray, stride: int, label: str, stats: dict[str, int]) -> np.ndarray:
    n, h, wid, cin = x.shape; cout = w.shape[0]
    pad = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)), constant_values=0)
    view = np.lib.stride_tricks.sliding_window_view(pad, (3, 3), axis=(1, 2))
    ho, wo = (h + stride - 1) // stride, (wid + stride - 1) // stride
    view = view[:, ::stride, ::stride]
    groups = cin // int(w.shape[1])
    if groups == 1:
        view = view.reshape(n, ho, wo, -1)
        acc = np.einsum("nhwk,ok->nhwo", view.astype(np.int64), w.reshape(cout, -1).astype(np.int64), optimize=True)
    else:
        # Grouped/depthwise kernels keep channel groups separate.  Flattening
        # all channels into one K dimension would incorrectly mix DW lanes.
        channels_per_group = cin // groups
        outputs_per_group = cout // groups
        view = view.reshape(n, ho, wo, groups, channels_per_group, 9)
        wg = w.reshape(groups, outputs_per_group, channels_per_group, 9)
        grouped = np.einsum("nhwgck,gock->nhwgo", view.astype(np.int64), wg.astype(np.int64), optimize=True)
        acc = grouped.reshape(n, ho, wo, cout)
    acc += bias.reshape(1, 1, 1, -1).astype(np.int64)
    check_acc(acc, label, stats)
    return requant(acc, mul.reshape(1, 1, 1, -1), shift.reshape(1, 1, 1, -1))


def conv1_q(x: np.ndarray, w: np.ndarray, bias: np.ndarray, mul: np.ndarray, shift: np.ndarray, stride: int, label: str, stats: dict[str, int]) -> np.ndarray:
    sampled = x[:, ::stride, ::stride]
    acc = np.einsum("nhwc,oc->nhwo", sampled.astype(np.int64), w.reshape(w.shape[0], w.shape[1]).astype(np.int64), optimize=True)
    acc += bias.reshape(1, 1, 1, -1).astype(np.int64)
    check_acc(acc, label, stats)
    return requant(acc, mul.reshape(1, 1, 1, -1), shift.reshape(1, 1, 1, -1))


def add_q(a: np.ndarray, sa: float, b: np.ndarray, sb: float, sout: float) -> np.ndarray:
    qa = round_away(a.astype(np.int64) * (sa / sout))
    qb = round_away(b.astype(np.int64) * (sb / sout))
    return np.clip(qa.astype(np.int64) + qb.astype(np.int64), -128, 127).astype(np.int8)


def state_np(state: dict[str, Any], key: str) -> np.ndarray:
    value = state[key]
    return value.detach().cpu().numpy() if hasattr(value, "detach") else np.asarray(value)


def export_arrays(ckpt: dict[str, Any], out: Path) -> tuple[dict[str, np.ndarray], dict[str, float], dict[str, Any]]:
    state = ckpt["model_state"]
    scales = {k: float(v) for k, v in ckpt["scales"].items()}
    out.mkdir(parents=True, exist_ok=True)
    params: dict[str, np.ndarray] = {"input_scale": np.asarray(INPUT_SCALE, np.float32)}
    layers: list[dict[str, Any]] = []

    def add_conv(name: str, key: str, in_s: float, out_s: float, kernel: int, stride: int, activation: str = "linear") -> None:
        w, ws = quant_weight(state_np(state, key + ".weight"))
        bfp = state_np(state, key + ".bias").astype(np.float64)
        bias = np.clip(round_away(bfp / (in_s * ws)), -(2 ** 31), 2 ** 31 - 1).astype(np.int32)
        mul, sh = ratio_qparams(in_s * ws / out_s)
        params.update({name + ".weight": w.astype(np.int8), name + ".weight_scale": ws.astype(np.float32), name + ".bias": bias, name + ".multiplier": mul, name + ".shift": sh})
        layers.append({"name": name, "source": key, "kernel": kernel, "stride": stride, "in_scale": in_s, "out_scale": out_s, "activation": activation, "accumulator": "int32", "bias_units": "input_scale*weight_scale", "rounding": "nearest_away_from_zero", "saturation": "int8"})

    in_s = INPUT_SCALE
    add_conv("stem", "stem", in_s, scales["stem"], 3, 1, "relu6"); in_s = scales["stem"]
    add_conv("fused1.expand", "fused1.expand", in_s, scales["fused1.expand"], 3, 1, "relu6"); in_s1 = scales["fused1.expand"]
    add_conv("fused1.project", "fused1.project", in_s1, scales["fused1.project"], 1, 1, "linear")
    in_s = scales["fused1.out"]
    add_conv("fused2.expand", "fused2.expand", in_s, scales["fused2.expand"], 3, 2, "relu6"); in_s2 = scales["fused2.expand"]
    add_conv("fused2.project", "fused2.project", in_s2, scales["fused2.out"], 1, 1, "linear"); in_s = scales["fused2.out"]

    def add_mb(prefix: str, key: str, cin_scale: float, residual: bool, stride: int = 1) -> float:
        add_conv(prefix + ".expand", key + ".expand", cin_scale, scales[key + ".expand"], 1, 1, "relu6")
        add_conv(prefix + ".spatial", key + ".spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, stride, "relu6")
        add_conv(prefix + ".project", key + ".project", scales[key + ".spatial"], scales[key + (".project" if residual else ".out")], 1, 1, "linear")
        return scales[key + ".out"]

    # For residual blocks project is kept at project scale and requanted at add.
    # Re-write the metadata's output scale for the project array when needed.
    in_s = scales["fused2.out"]
    for i in (1, 2):
        key = f"mb16.{i}"; add_conv(key + ".expand", f"mb16.{i-1}.expand", in_s, scales[key + ".expand"], 1, 1, "relu6")
        add_conv(key + ".spatial", f"mb16.{i-1}.spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, 1, "relu6")
        add_conv(key + ".project", f"mb16.{i-1}.project", scales[key + ".spatial"], scales[key + ".project"], 1, 1); in_s = scales[key + ".out"]
    key = "mb8.down"; add_conv(key + ".expand", "mb8_down.expand", in_s, scales[key + ".expand"], 1, 1, "relu6"); add_conv(key + ".spatial", "mb8_down.spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, 2, "relu6"); add_conv(key + ".project", "mb8_down.project", scales[key + ".spatial"], scales[key + ".out"], 1, 1); in_s = scales[key + ".out"]
    for i in (1, 2, 3):
        key = f"mb8.{i}"; add_conv(key + ".expand", f"mb8.{i-1}.expand", in_s, scales[key + ".expand"], 1, 1, "relu6"); add_conv(key + ".spatial", f"mb8.{i-1}.spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, 1, "relu6"); add_conv(key + ".project", f"mb8.{i-1}.project", scales[key + ".spatial"], scales[key + ".project"], 1, 1); in_s = scales[key + ".out"]
    key = "mb4.down"; add_conv(key + ".expand", "mb4_down.expand", in_s, scales[key + ".expand"], 1, 1, "relu6"); add_conv(key + ".spatial", "mb4_down.spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, 2, "relu6"); add_conv(key + ".project", "mb4_down.project", scales[key + ".spatial"], scales[key + ".out"], 1, 1); in_s = scales[key + ".out"]
    for i in (1, 2):
        key = f"mb4.{i}"; add_conv(key + ".expand", f"mb4.{i-1}.expand", in_s, scales[key + ".expand"], 1, 1, "relu6"); add_conv(key + ".spatial", f"mb4.{i-1}.spatial", scales[key + ".expand"], scales[key + ".spatial"], 3, 1, "relu6"); add_conv(key + ".project", f"mb4.{i-1}.project", scales[key + ".spatial"], scales[key + ".project"], 1, 1); in_s = scales[key + ".out"]
    add_conv("head", "head", in_s, scales["head"], 1, 1, "linear")
    fw, fws = quant_weight(state_np(state, "fc.weight")); fb = state_np(state, "fc.bias").astype(np.float64)
    fbias = np.clip(round_away(fb / (scales["head"] * fws)), -(2 ** 31), 2 ** 31 - 1).astype(np.int32)
    params.update({"fc.weight": fw.astype(np.int8), "fc.weight_scale": fws.astype(np.float32), "fc.bias": fbias})
    layers.append({"name": "fc", "op": "linear", "in_scale": scales["head"], "weight_scale": fws.tolist(), "accumulator": "int32", "bias_units": "input_scale*weight_scale"})
    np.savez_compressed(out / "edgembconv_hwacandidate_a_int8.npz", **params)
    manifest = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-A-deploy",
        "variant_id": "A", "architecture": "A_current_edgembconv_hybrid",
        "profile": {"parameter_count": 280122, "semantic_macs": 17211904},
        "bn": "folded_into_conv_weight_and_bias_before_QAT",
        "quantization": {"input": "signed int8, zero point 0, scale 1/127.5", "weights": "symmetric per-output-channel int8 [-127,127]", "activations": "signed int8; ReLU6 [0,127], linear/residual [-128,127]", "accumulator": "int32 contract; reference computes int64 and checks bound", "bias": "int32 in input_scale*weight_scale units", "requant": "nearest-away-from-zero(acc*multiplier/2^shift), saturate to int8"},
        "layers": layers, "source_checkpoint": str(ckpt.get("source_checkpoint", "candidate A QAT")), "arrays": "edgembconv_hwacandidate_a_int8.npz",
    }
    (out / "edgembconv_hwacandidate_a_deploy_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return params, scales, manifest


def per_class(pred: np.ndarray, labels: np.ndarray) -> dict[str, Any]:
    total = np.bincount(labels, minlength=10); correct = np.bincount(labels[pred == labels], minlength=10)
    names = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]
    return {name: {"correct": int(correct[i]), "total": int(total[i]), "top1": float(correct[i] / max(1, total[i]))} for i, name in enumerate(names)}


@torch.no_grad()
def fp32_predict(ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, float]:
    model = EdgeMBConvCandidateA(); model.load_state_dict(ckpt["model_state"]); model.eval()
    loader = DataLoader(CifarDataset(images, labels, False, 20260904), batch_size=batch_size, shuffle=False, num_workers=0)
    pred = np.empty(labels.size, dtype=np.int64); offset = 0
    for x, _ in loader:
        logits = model(x); n = logits.shape[0]; pred[offset:offset + n] = logits.argmax(1).numpy(); offset += n
    return pred, float(np.mean(pred == labels))


def report_text(result: dict[str, Any], manifest: dict[str, Any], hashes: dict[str, str]) -> str:
    fp, q = result["fp32"], result["int8"]
    lines = [
        "# EdgeMBConv HW candidate A — C10-HWQA-v1 result",
        "",
        "This is an independent candidate artifact. C0 remains untouched and is not replaced by this result.",
        "",
        "## Locked graph and arithmetic",
        "",
        "- Variant A: current EdgeMBConv-Hybrid; profile guard passed at 280,122 deployed parameters and 17,211,904 semantic MACs.",
        "- BN is folded into convolution weights/biases before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators and folded biases use the INT32 hardware contract.",
        "- Requantization is nearest-away-from-zero followed by INT8 saturation. The Python evaluator uses INT64 only as an overflow-safe reference and checks every accumulator against INT32 bounds.",
        "",
        "## Accuracy (official CIFAR-10 test10k, final evaluation only)",
        "",
        f"- FP32 top-1: **{100 * fp['top1']:.2f}%**",
        f"- Deployment INT8 top-1: **{100 * q['top1']:.2f}%**",
        f"- FP32 → INT8 drop: **{result['drop_pp']:.3f} percentage points**",
        f"- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **{'PASS' if result['quality_gate'] else 'FAIL'}**",
        "",
        "### Per-class top-1",
        "",
        "| Class | FP32 | INT8 |",
        "| --- | ---: | ---: |",
    ]
    for name in fp["per_class"]:
        lines.append(f"| {name} | {100 * fp['per_class'][name]['top1']:.2f}% | {100 * q['per_class'][name]['top1']:.2f}% |")
    lines += [
        "",
        "## Comparison anchors",
        "",
        "C0 is retained as the formal baseline (reported FP32 70.05%, INT8 66.16%); its training protocol was not an architecture ceiling. C1 ResNet-20 is a quality anchor (reported FP32 91.63%, INT8 91.29%) and not an automatic replacement.",
        "",
        "| Item | Candidate A | C0 anchor | C1 anchor |",
        "| --- | ---: | ---: | ---: |",
        f"| FP32 top-1 | {100 * fp['top1']:.2f}% | 70.05% | 91.63% |",
        f"| INT8 top-1 | {100 * q['top1']:.2f}% | 66.16% | 91.29% |",
        "| Semantic MAC | 17,211,904 | 5,136,896 | 40,813,184 |",
        "| Parameters | 280,122 | 72,010 | 270,896 |",
        "",
        "## Export/evaluator evidence",
        "",
        f"- Accumulator checks: {result['int8']['accumulator_checks']}; maximum absolute accumulator: {result['int8']['max_abs_accumulator']:,} (INT32 limit 2,147,483,647).",
        f"- Deployment manifest: `{manifest['arrays']}` and `edgembconv_hwacandidate_a_deploy_manifest.json`.",
        "- Artifact hashes are recorded in `build/edgembconv_hwacandidate/edgembconv_hwacandidate_a_artifact_hashes.json`; the manifest hash is recorded separately.",
        "",
        "This result establishes software FP32/INT8 quality and integer export evidence only. Cycle-model, RTL equivalence, synthesis, post-route timing, power, and energy remain separate gates.",
        "",
    ]
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--qat", type=Path, default=DEFAULT_QAT); p.add_argument("--fp32", type=Path, default=DEFAULT_FP32)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT); p.add_argument("--result", type=Path, default=DEFAULT_RESULT); p.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data")); p.add_argument("--batch-size", type=int, default=128)
    return p.parse_args()


def main(args: argparse.Namespace) -> None:
    profile = assert_locked_profile()
    if not args.qat.exists() or not args.fp32.exists(): raise FileNotFoundError("candidate A FP32 and QAT checkpoints are required")
    qat = load_state(args.qat); fp_ckpt = load_state(args.fp32)
    for ckpt, label in ((qat, "QAT"), (fp_ckpt, "FP32")):
        cp = ckpt.get("profile", {})
        if int(cp.get("parameter_count", -1)) != int(profile["parameter_count"]) or int(cp.get("semantic_macs", -1)) != int(profile["semantic_macs"]): raise RuntimeError(f"{label} checkpoint is not locked candidate A")
    params, scales, deploy_manifest = export_arrays(qat, args.out)
    images, labels = load_cifar10(args.data, "test")
    fp_pred, fp_top1 = fp32_predict(fp_ckpt, images, labels, args.batch_size)

    # Keep the residual input before each residual block; this is the explicit
    # integer counterpart of CandidateQAT's scale-aligned residual add.
    def int8_run() -> tuple[np.ndarray, dict[str, int]]:
        pred = np.empty(labels.size, dtype=np.int64); stats = {"max_abs_accumulator": 0, "accumulator_checks": 0}
        for start in range(0, labels.size, args.batch_size):
            end = min(start + args.batch_size, labels.size)
            x = np.clip(images[start:end].astype(np.int16) - 128, -128, 127).astype(np.int8)
            x = conv3_q(x, params["stem.weight"], params["stem.bias"], params["stem.multiplier"], params["stem.shift"], 1, "stem", stats); x = np.clip(x, 0, 127).astype(np.int8); in_s = scales["stem"]
            residual = x.copy()
            x = conv3_q(x, params["fused1.expand.weight"], params["fused1.expand.bias"], params["fused1.expand.multiplier"], params["fused1.expand.shift"], 1, "fused1.expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
            y = conv1_q(x, params["fused1.project.weight"], params["fused1.project.bias"], params["fused1.project.multiplier"], params["fused1.project.shift"], 1, "fused1.project", stats)
            x = add_q(residual, scales["stem"], y, scales["fused1.project"], scales["fused1.out"]); in_s = scales["fused1.out"]
            x = conv3_q(x, params["fused2.expand.weight"], params["fused2.expand.bias"], params["fused2.expand.multiplier"], params["fused2.expand.shift"], 2, "fused2.expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
            x = conv1_q(x, params["fused2.project.weight"], params["fused2.project.bias"], params["fused2.project.multiplier"], params["fused2.project.shift"], 1, "fused2.project", stats); in_s = scales["fused2.out"]

            def mb(prefix: str, stride: int, residual_add: bool) -> None:
                nonlocal x, in_s
                identity = x.copy() if residual_add else None; identity_s = in_s
                x = conv1_q(x, params[prefix + ".expand.weight"], params[prefix + ".expand.bias"], params[prefix + ".expand.multiplier"], params[prefix + ".expand.shift"], 1, prefix + ".expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
                x = conv3_q(x, params[prefix + ".spatial.weight"], params[prefix + ".spatial.bias"], params[prefix + ".spatial.multiplier"], params[prefix + ".spatial.shift"], stride, prefix + ".spatial", stats); x = np.clip(x, 0, 127).astype(np.int8)
                x = conv1_q(x, params[prefix + ".project.weight"], params[prefix + ".project.bias"], params[prefix + ".project.multiplier"], params[prefix + ".project.shift"], 1, prefix + ".project", stats)
                if residual_add: x = add_q(identity, identity_s, x, scales[prefix + ".project"], scales[prefix + ".out"])
                in_s = scales[prefix + ".out"]

            mb("mb16.1", 1, True); mb("mb16.2", 1, True); mb("mb8.down", 2, False); mb("mb8.1", 1, True); mb("mb8.2", 1, True); mb("mb8.3", 1, True); mb("mb4.down", 2, False); mb("mb4.1", 1, True); mb("mb4.2", 1, True)
            x = conv1_q(x, params["head.weight"], params["head.bias"], params["head.multiplier"], params["head.shift"], 1, "head", stats); in_s = scales["head"]
            gap = round_away(x.astype(np.int64).sum(axis=(1, 2)) / 16.0).clip(-128, 127).astype(np.int8)  # 4x4 output
            acc = np.einsum("nc,oc->no", gap.astype(np.int64), params["fc.weight"].astype(np.int64), optimize=True) + params["fc.bias"].reshape(1, -1).astype(np.int64)
            check_acc(acc, "fc", stats)
            # Per-output-channel weight scales are retained when comparing logits.
            pred[start:end] = (acc.astype(np.float64) * params["fc.weight_scale"].reshape(1, -1)).argmax(1)
        return pred, stats

    q_pred, q_stats = int8_run(); q_top1 = float(np.mean(q_pred == labels))
    result = {"schema": "C10-HWQA-v1-edgembconv-hwacandidate-A-test10k", "variant_id": "A", "samples": int(labels.size), "profile": {"parameter_count": 280122, "semantic_macs": 17211904}, "fp32": {"top1": fp_top1, "correct": int(np.sum(fp_pred == labels)), "per_class": per_class(fp_pred, labels)}, "int8": {"top1": q_top1, "correct": int(np.sum(q_pred == labels)), "per_class": per_class(q_pred, labels), **q_stats}, "drop_pp": (fp_top1 - q_top1) * 100.0, "quality_gate": bool(q_top1 >= 0.90 and (fp_top1 - q_top1) * 100.0 <= 0.5), "c0_anchor": {"fp32_top1": 0.7005, "int8_top1": 0.6616}, "c1_anchor": {"fp32_top1": 0.9163, "int8_top1": 0.9129}}
    args.result.parent.mkdir(parents=True, exist_ok=True); args.result.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    args.report.parent.mkdir(parents=True, exist_ok=True); args.report.write_text(report_text(result, deploy_manifest, {}), encoding="utf-8")

    candidate_root = ROOT / "build" / "edgembconv_hwacandidate"; hashes: dict[str, str] = {}
    for file in sorted(candidate_root.rglob("*")):
        if file.is_file() and file.name != "edgembconv_hwacandidate_a_artifact_hashes.json": hashes[str(file.relative_to(ROOT)).replace("\\", "/")] = sha256_file(file)
    hash_path = candidate_root / "edgembconv_hwacandidate_a_artifact_hashes.json"; hash_path.write_text(json.dumps({"schema": "C10-HWQA-v1-artifact-hashes", "files": hashes}, indent=2) + "\n", encoding="utf-8")
    manifest_path = args.out / "edgembconv_hwacandidate_a_deploy_manifest.json"; manifest_hash = sha256_file(manifest_path)
    (candidate_root / "edgembconv_hwacandidate_a_manifest_sha256.json").write_text(json.dumps({"path": str(manifest_path.relative_to(ROOT)).replace("\\", "/"), "sha256": manifest_hash}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2)); print(f"wrote {args.out / 'edgembconv_hwacandidate_a_int8.npz'}"); print(f"wrote {args.result}")


if __name__ == "__main__":
    main(parse_args())
