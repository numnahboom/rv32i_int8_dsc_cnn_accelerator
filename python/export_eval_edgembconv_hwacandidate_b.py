#!/usr/bin/env python3
"""Export and evaluate locked EdgeMBConv hardware candidate B.

The evaluator is integer-first and independent in its artifact namespace.  It
uses the same C10-HWQA-v1 deployment contract as candidate A: folded BN,
per-output-channel symmetric INT8 weights, signed INT8 activations, INT32
bias/accumulator contract, nearest-away-from-zero requantization, and INT8
saturation.  The reference arithmetic is INT64 only to make overflow checks
auditable.
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

from edgembconv_hwacandidate_b_model import (
    INPUT_SCALE,
    CandidateQATB,
    EdgeMBConvCandidateB,
    FoldedCandidateB,
    assert_locked_profile,
    fold_candidate_b,
)
from resnet20_hwqa import CifarDataset, load_cifar10, seed_everything

# Import only tested low-level integer primitives.  This module does not use
# A's model, checkpoints, or output paths.
from export_eval_edgembconv_hwacandidate_a import (
    add_q,
    check_acc,
    conv1_q,
    conv3_q,
    quant_weight,
    ratio_qparams,
    round_away,
    state_np,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = ROOT / "build" / "edgembconv_hwacandidate_b"
DEFAULT_QAT = DEFAULT_ROOT / "edgembconv_hwacandidate_b_qat.pt"
DEFAULT_FP32 = DEFAULT_ROOT / "edgembconv_hwacandidate_b_fp32.pt"
DEFAULT_OUT = DEFAULT_ROOT / "edgembconv_hwacandidate_b_deploy"
DEFAULT_RESULT = DEFAULT_ROOT / "edgembconv_hwacandidate_b_test10k.json"
DEFAULT_REPORT = ROOT / "docs" / "reports" / "edgembconv_hwacandidate_b_hwqa_report_20260902.md"
PROFILE_REL = "build/edgembconv_hwacandidate/profile_B.json"
STATIC_MANIFEST_REL = "build/edgembconv_hwacandidate/edgembconv_hwacandidate_manifest.json"

LOCKED_PROFILE = {"parameter_count": 276346, "semantic_macs": 13312512}


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


def verify_checkpoint(ckpt: dict[str, Any], profile: dict[str, Any], label: str) -> None:
    cp = ckpt.get("profile", {})
    if cp.get("variant_id") not in (None, "B"):
        raise RuntimeError(f"{label} checkpoint identifies non-B variant")
    if int(cp.get("parameter_count", -1)) != int(profile["parameter_count"]) or int(cp.get("semantic_macs", -1)) != int(profile["semantic_macs"]):
        raise RuntimeError(f"{label} checkpoint is not locked candidate B")


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
        params.update({
            name + ".weight": w.astype(np.int8), name + ".weight_scale": ws.astype(np.float32),
            name + ".bias": bias, name + ".multiplier": mul, name + ".shift": sh,
        })
        layers.append({"name": name, "source": key, "kernel": kernel, "stride": stride, "in_scale": in_s, "out_scale": out_s,
                       "activation": activation, "accumulator": "int32", "bias_units": "input_scale*weight_scale",
                       "rounding": "nearest_away_from_zero", "saturation": "int8"})

    in_s = INPUT_SCALE
    add_conv("stem", "stem", in_s, scales["stem"], 3, 1, "relu6"); in_s = scales["stem"]

    # B-specific early sequence: MBConv at 32x32, then the retained fused
    # 16x16 downsample.  The residual add uses the explicit output scale.
    add_conv("mb32.expand", "mb32.expand", in_s, scales["mb32.expand"], 1, 1, "relu6")
    add_conv("mb32.spatial", "mb32.spatial", scales["mb32.expand"], scales["mb32.spatial"], 3, 1, "relu6")
    add_conv("mb32.project", "mb32.project", scales["mb32.spatial"], scales["mb32.project"], 1, 1, "linear")
    in_s = scales["mb32.out"]
    add_conv("fused2.expand", "fused2.expand", in_s, scales["fused2.expand"], 3, 2, "relu6")
    add_conv("fused2.project", "fused2.project", scales["fused2.expand"], scales["fused2.out"], 1, 1, "linear")
    in_s = scales["fused2.out"]

    def add_mb(prefix: str, source: str, cin_scale: float, stride: int, residual: bool) -> float:
        add_conv(prefix + ".expand", source + ".expand", cin_scale, scales[prefix + ".expand"], 1, 1, "relu6")
        add_conv(prefix + ".spatial", source + ".spatial", scales[prefix + ".expand"], scales[prefix + ".spatial"], 3, stride, "relu6")
        project_scale = scales[prefix + (".project" if residual else ".out")]
        add_conv(prefix + ".project", source + ".project", scales[prefix + ".spatial"], project_scale, 1, 1, "linear")
        return scales[prefix + ".out"]

    for i in (1, 2):
        key = f"mb16.{i}"; in_s = add_mb(key, f"mb16.{i - 1}", in_s, 1, True)
    in_s = add_mb("mb8.down", "mb8_down", in_s, 2, False)
    for i in (1, 2, 3):
        key = f"mb8.{i}"; in_s = add_mb(key, f"mb8.{i - 1}", in_s, 1, True)
    in_s = add_mb("mb4.down", "mb4_down", in_s, 2, False)
    for i in (1, 2):
        key = f"mb4.{i}"; in_s = add_mb(key, f"mb4.{i - 1}", in_s, 1, True)
    add_conv("head", "head", in_s, scales["head"], 1, 1, "linear")

    fw, fws = quant_weight(state_np(state, "fc.weight")); fb = state_np(state, "fc.bias").astype(np.float64)
    fbias = np.clip(round_away(fb / (scales["head"] * fws)), -(2 ** 31), 2 ** 31 - 1).astype(np.int32)
    params.update({"fc.weight": fw.astype(np.int8), "fc.weight_scale": fws.astype(np.float32), "fc.bias": fbias})
    layers.append({"name": "fc", "op": "linear", "in_scale": scales["head"], "weight_scale": fws.tolist(),
                   "accumulator": "int32", "bias_units": "input_scale*weight_scale"})

    array_name = "edgembconv_hwacandidate_b_int8.npz"
    np.savez_compressed(out / array_name, **params)
    manifest = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-B-deploy",
        "variant_id": "B", "architecture": "B_mb32_replaces_fused32", "profile": LOCKED_PROFILE,
        "bn": "folded_into_conv_weight_and_bias_before_QAT",
        "quantization": {"input": "signed int8, zero point 0, scale 1/127.5", "weights": "symmetric per-output-channel int8 [-127,127]",
                         "activations": "signed int8; ReLU6 [0,127], linear/residual [-128,127]",
                         "accumulator": "int32 contract; reference computes int64 and checks bound",
                         "bias": "int32 in input_scale*weight_scale units",
                         "requant": "nearest-away-from-zero(acc*multiplier/2^shift), saturate to int8"},
        "layers": layers, "source_checkpoint": str(ckpt.get("source_checkpoint", "candidate B QAT")), "arrays": array_name,
    }
    manifest_name = "edgembconv_hwacandidate_b_deploy_manifest.json"
    (out / manifest_name).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    manifest["manifest_file"] = manifest_name
    return params, scales, manifest


CLASS_NAMES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]


def per_class(pred: np.ndarray, labels: np.ndarray) -> dict[str, Any]:
    total = np.bincount(labels, minlength=10); correct = np.bincount(labels[pred == labels], minlength=10)
    return {name: {"correct": int(correct[i]), "total": int(total[i]), "top1": float(correct[i] / max(1, total[i]))} for i, name in enumerate(CLASS_NAMES)}


@torch.no_grad()
def fp32_predict(ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, float]:
    model = EdgeMBConvCandidateB(); model.load_state_dict(ckpt["model_state"]); model.eval()
    loader = DataLoader(CifarDataset(images, labels, False, 20260904), batch_size=batch_size, shuffle=False, num_workers=0)
    pred = np.empty(labels.size, dtype=np.int64); offset = 0
    for x, _ in loader:
        logits = model(x); n = logits.shape[0]; pred[offset:offset + n] = logits.argmax(1).numpy(); offset += n
    return pred, float(np.mean(pred == labels))


@torch.no_grad()
def qat_predict(ckpt: dict[str, Any], fp_ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, float]:
    fp = EdgeMBConvCandidateB(); fp.load_state_dict(fp_ckpt["model_state"]); fp.eval()
    folded = fold_candidate_b(fp)
    model = CandidateQATB(folded, {k: float(v) for k, v in ckpt["scales"].items()})
    model.load_state_dict(ckpt["model_state"]); model.eval()
    loader = DataLoader(CifarDataset(images, labels, False, 20260905), batch_size=batch_size, shuffle=False, num_workers=0)
    pred = np.empty(labels.size, dtype=np.int64); offset = 0
    for x, _ in loader:
        logits = model(x); n = logits.shape[0]; pred[offset:offset + n] = logits.argmax(1).numpy(); offset += n
    return pred, float(np.mean(pred == labels))


@torch.no_grad()
def bn_fold_equivalence(fp_ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray) -> dict[str, Any]:
    """Compare eval-mode BN graph and folded graph on a deterministic sample."""
    model = EdgeMBConvCandidateB(); model.load_state_dict(fp_ckpt["model_state"]); model.eval()
    folded: FoldedCandidateB = fold_candidate_b(model); folded.eval()
    x, _ = CifarDataset(images[:16], labels[:16], False, 20260906)[0]
    batch = torch.stack([CifarDataset(images[:16], labels[:16], False, 20260906)[i][0] for i in range(min(16, len(images)))])
    a = model(batch); b = folded(batch)
    diff = (a - b).abs()
    return {"samples": int(batch.shape[0]), "max_abs_logit_diff": float(diff.max()), "mean_abs_logit_diff": float(diff.mean()), "allclose_atol_2e-5_rtol_1e-5": bool(torch.allclose(a, b, atol=2e-5, rtol=1e-5))}


def run_integer(params: dict[str, np.ndarray], scales: dict[str, float], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, dict[str, int]]:
    pred = np.empty(labels.size, dtype=np.int64); stats = {"max_abs_accumulator": 0, "accumulator_checks": 0}
    for start in range(0, labels.size, batch_size):
        end = min(start + batch_size, labels.size)
        x = np.clip(images[start:end].astype(np.int16) - 128, -128, 127).astype(np.int8)
        x = conv3_q(x, params["stem.weight"], params["stem.bias"], params["stem.multiplier"], params["stem.shift"], 1, "stem", stats); x = np.clip(x, 0, 127).astype(np.int8); in_s = scales["stem"]

        identity = x.copy(); identity_s = in_s
        x = conv1_q(x, params["mb32.expand.weight"], params["mb32.expand.bias"], params["mb32.expand.multiplier"], params["mb32.expand.shift"], 1, "mb32.expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
        x = conv3_q(x, params["mb32.spatial.weight"], params["mb32.spatial.bias"], params["mb32.spatial.multiplier"], params["mb32.spatial.shift"], 1, "mb32.spatial", stats); x = np.clip(x, 0, 127).astype(np.int8)
        x = conv1_q(x, params["mb32.project.weight"], params["mb32.project.bias"], params["mb32.project.multiplier"], params["mb32.project.shift"], 1, "mb32.project", stats)
        x = add_q(identity, identity_s, x, scales["mb32.project"], scales["mb32.out"]); in_s = scales["mb32.out"]

        x = conv3_q(x, params["fused2.expand.weight"], params["fused2.expand.bias"], params["fused2.expand.multiplier"], params["fused2.expand.shift"], 2, "fused2.expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
        x = conv1_q(x, params["fused2.project.weight"], params["fused2.project.bias"], params["fused2.project.multiplier"], params["fused2.project.shift"], 1, "fused2.project", stats); in_s = scales["fused2.out"]

        def mb(prefix: str, stride: int, residual: bool) -> None:
            nonlocal x, in_s
            identity = x.copy() if residual else None; identity_s = in_s
            x = conv1_q(x, params[prefix + ".expand.weight"], params[prefix + ".expand.bias"], params[prefix + ".expand.multiplier"], params[prefix + ".expand.shift"], 1, prefix + ".expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
            x = conv3_q(x, params[prefix + ".spatial.weight"], params[prefix + ".spatial.bias"], params[prefix + ".spatial.multiplier"], params[prefix + ".spatial.shift"], stride, prefix + ".spatial", stats); x = np.clip(x, 0, 127).astype(np.int8)
            x = conv1_q(x, params[prefix + ".project.weight"], params[prefix + ".project.bias"], params[prefix + ".project.multiplier"], params[prefix + ".project.shift"], 1, prefix + ".project", stats)
            if residual: x = add_q(identity, identity_s, x, scales[prefix + ".project"], scales[prefix + ".out"])
            in_s = scales[prefix + ".out"]

        mb("mb16.1", 1, True); mb("mb16.2", 1, True); mb("mb8.down", 2, False)
        mb("mb8.1", 1, True); mb("mb8.2", 1, True); mb("mb8.3", 1, True); mb("mb4.down", 2, False); mb("mb4.1", 1, True); mb("mb4.2", 1, True)
        x = conv1_q(x, params["head.weight"], params["head.bias"], params["head.multiplier"], params["head.shift"], 1, "head", stats)
        gap = round_away(x.astype(np.int64).sum(axis=(1, 2)) / 16.0).clip(-128, 127).astype(np.int8)
        acc = np.einsum("nc,oc->no", gap.astype(np.int64), params["fc.weight"].astype(np.int64), optimize=True) + params["fc.bias"].reshape(1, -1).astype(np.int64)
        check_acc(acc, "fc", stats)
        pred[start:end] = (acc.astype(np.float64) * params["fc.weight_scale"].reshape(1, -1)).argmax(1)
    return pred, stats


def curve_summary(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False}
    rows = json.loads(path.read_text(encoding="utf-8")).get("history", [])
    if not rows:
        return {"path": str(path), "exists": True, "epochs": 0}
    best = max(rows, key=lambda r: float(r.get("val_acc", -1)))
    last = rows[-1]
    return {"path": str(path.relative_to(ROOT)).replace("\\", "/"), "exists": True, "epochs": len(rows),
            "best_epoch": int(best["epoch"]), "best_val_acc": float(best["val_acc"]),
            "first_val_acc": float(rows[0]["val_acc"]), "last_val_acc": float(last["val_acc"]),
            "last_train_acc": float(last.get("train_acc", 0.0))}


def report_text(result: dict[str, Any], manifest: dict[str, Any], profile: dict[str, Any], bn_fold: dict[str, Any], artifact_hash_path: str) -> str:
    fp, q = result["fp32"], result["int8"]
    lines = [
        "# EdgeMBConv hardware-aware candidate B — C10-HWQA-v1 result", "",
        "Candidate B is an independent ablation artifact. C0 and candidate A paths, checkpoints, RTL, and reports remain untouched.", "",
        "## Locked graph and static guard", "",
        "- B definition: replace only A's 32x32 residual fused block with `MBConv(16,32,16)`; retain the 16x16 fused downsample and all later MBConv blocks.",
        f"- Profile guard: **PASS** — {profile['parameter_count']:,} deployed parameters, {profile['semantic_macs']:,} semantic MACs; dense3x3={profile['operator_mac_categories'][0]['mac']:,}, PW={profile['operator_mac_categories'][1]['mac']:,}, DW={profile['operator_mac_categories'][2]['mac']:,}.",
        "- Operator narrative: predominantly DW/PW, but the retained stem and fused downsample remain explicitly accounted for; no claim is made that dense3x3 work maps directly to the DW/PW path.",
        "- BN is folded into convolution weights and biases before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; folded biases and accumulators follow the INT32 hardware contract.",
        "",
        "## Accuracy (official CIFAR-10 test10k, final evaluation)", "",
        f"- FP32 top-1: **{100 * fp['top1']:.2f}%** ({fp['correct']}/{result['samples']})",
        f"- Deployment INT8 top-1: **{100 * q['top1']:.2f}%** ({q['correct']}/{result['samples']})",
        f"- FP32 → INT8 drop: **{result['drop_pp']:.3f} percentage points**",
        f"- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **{'PASS' if result['quality_gate'] else 'FAIL'}**",
        "",
        "### Per-class top-1", "", "| Class | FP32 | INT8 |", "| --- | ---: | ---: |",
    ]
    for name in fp["per_class"]:
        lines.append(f"| {name} | {100 * fp['per_class'][name]['top1']:.2f}% | {100 * q['per_class'][name]['top1']:.2f}% |")
    lines += [
        "", "## Training and quantization evidence", "",
        f"- FP32 learning curve: `{result['learning_curves']['fp32']['path']}`; {result['learning_curves']['fp32'].get('epochs', 0)} epochs, best validation {100 * result['learning_curves']['fp32'].get('best_val_acc', 0):.2f}% at epoch {result['learning_curves']['fp32'].get('best_epoch', 0)}.",
        f"- QAT learning curve: `{result['learning_curves']['qat']['path']}`; {result['learning_curves']['qat'].get('epochs', 0)} epochs, best validation {100 * result['learning_curves']['qat'].get('best_val_acc', 0):.2f}% at epoch {result['learning_curves']['qat'].get('best_epoch', 0)}.",
        f"- BN-fold equivalence sample: {bn_fold['samples']} images, max absolute logit difference {bn_fold['max_abs_logit_diff']:.6g}, allclose(atol=2e-5, rtol=1e-5)={bn_fold['allclose_atol_2e-5_rtol_1e-5']}",
        f"- QAT fake-quant vs exported integer evaluator argmax agreement: {result['quant_equivalence']['matching_predictions']}/{result['samples']} ({100 * result['quant_equivalence']['agreement']:.3f}%).",
        f"- Integer overflow audit: {q['accumulator_checks']} accumulator checks; maximum absolute accumulator {q['max_abs_accumulator']:,}; INT32 limit 2,147,483,647; overflow={q['overflow']}",
        "- Requantization: nearest-away-from-zero followed by INT8 saturation; integer evaluator uses INT64 intermediates only to check the INT32 bound.",
        "",
        "## Comparison anchors (not a superiority claim)", "",
        "C0 remains the formal baseline; its 70.05% result is not treated as an architectural ceiling. Candidate A remains an independent trained reference, and neither anchor is replaced by B.",
        "", "| Item | Candidate B | Candidate A | C0 anchor |", "| --- | ---: | ---: | ---: |",
        f"| FP32 top-1 | {100 * fp['top1']:.2f}% | 91.48% | 70.05% |",
        f"| Deployment INT8 top-1 | {100 * q['top1']:.2f}% | 91.30% | 66.16% |",
        f"| Semantic MAC | {profile['semantic_macs']:,} | 17,211,904 | 5,136,896 |",
        f"| Parameters | {profile['parameter_count']:,} | 280,122 | 72,010 |",
        "", "## Artifact hashes and evidence boundary", "",
        f"- B artifact hashes: `{artifact_hash_path}`.",
        f"- Deployment manifest: `{manifest['arrays']}` and `{manifest['manifest_file']}`.",
        "- No cycle-model, RTL-equivalence, synthesis, post-route timing, power, or energy evidence is claimed by this software-only B evaluation.",
        "",
    ]
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--qat", type=Path, default=DEFAULT_QAT); p.add_argument("--fp32", type=Path, default=DEFAULT_FP32)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT); p.add_argument("--result", type=Path, default=DEFAULT_RESULT); p.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data")); p.add_argument("--batch-size", type=int, default=128)
    p.add_argument("--seed", type=int, default=20260902)
    return p.parse_args()


def main(args: argparse.Namespace) -> None:
    profile = assert_locked_profile()
    if not args.qat.exists() or not args.fp32.exists():
        raise FileNotFoundError("candidate B FP32 and QAT checkpoints are required")
    qat = load_state(args.qat); fp_ckpt = load_state(args.fp32)
    verify_checkpoint(qat, profile, "QAT"); verify_checkpoint(fp_ckpt, profile, "FP32")
    params, scales, deploy_manifest = export_arrays(qat, args.out)
    images, labels = load_cifar10(args.data, "test")
    fp_pred, fp_top1 = fp32_predict(fp_ckpt, images, labels, args.batch_size)
    q_pred, q_stats = run_integer(params, scales, images, labels, args.batch_size)
    q_top1 = float(np.mean(q_pred == labels))
    qat_pred, qat_top1 = qat_predict(qat, fp_ckpt, images, labels, args.batch_size)
    bn_fold = bn_fold_equivalence(fp_ckpt, images, labels)
    result: dict[str, Any] = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-B-test10k", "variant_id": "B", "samples": int(labels.size),
        "profile": LOCKED_PROFILE,
        "fp32": {"top1": fp_top1, "correct": int(np.sum(fp_pred == labels)), "per_class": per_class(fp_pred, labels)},
        "int8": {"top1": q_top1, "correct": int(np.sum(q_pred == labels)), "per_class": per_class(q_pred, labels), **q_stats, "overflow": bool(q_stats["max_abs_accumulator"] > 2 ** 31 - 1)},
        "qat_fake_quant": {"top1": qat_top1, "correct": int(np.sum(qat_pred == labels))},
        "drop_pp": (fp_top1 - q_top1) * 100.0,
        "quality_gate": bool(q_top1 >= 0.90 and (fp_top1 - q_top1) * 100.0 <= 0.5),
        "quant_equivalence": {"reference": "CandidateQATB argmax vs exported integer evaluator argmax", "matching_predictions": int(np.sum(qat_pred == q_pred)), "agreement": float(np.mean(qat_pred == q_pred))},
        "bn_fold_equivalence": bn_fold,
        "learning_curves": {"fp32": curve_summary(DEFAULT_ROOT / "edgembconv_hwacandidate_b_fp32_learning_curve.json"), "qat": curve_summary(DEFAULT_ROOT / "edgembconv_hwacandidate_b_qat_learning_curve.json")},
        "c0_anchor": {"fp32_top1": 0.7005, "int8_top1": 0.6616}, "candidate_a_anchor": {"fp32_top1": 0.9148, "int8_top1": 0.9130},
    }
    args.result.parent.mkdir(parents=True, exist_ok=True); args.result.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    args.report.parent.mkdir(parents=True, exist_ok=True)

    # Hash every B artifact plus the locked static evidence and B source files.
    hash_files: list[Path] = []
    hash_files.extend(file for file in sorted(DEFAULT_ROOT.rglob("*")) if file.is_file())
    hash_files.extend([ROOT / PROFILE_REL, ROOT / STATIC_MANIFEST_REL, Path(__file__), Path(__file__).with_name("train_edgembconv_hwacandidate_b.py"), Path(__file__).with_name("qat_edgembconv_hwacandidate_b.py"), Path(__file__).with_name("edgembconv_hwacandidate_b_model.py")])
    hashes: dict[str, str] = {}
    for file in hash_files:
        # Console logs are process-output side effects and can be flushed after
        # the exporter writes its hash manifest; hash reproducible artifacts
        # only and keep logs available separately for diagnosis.
        if file.exists() and file.suffix.lower() != ".log" and file.name not in {"edgembconv_hwacandidate_b_artifact_hashes.json", "edgembconv_hwacandidate_b_manifest_sha256.json"}:
            key = str(file.relative_to(ROOT)).replace("\\", "/")
            hashes[key] = sha256_file(file)
    hash_path = DEFAULT_ROOT / "edgembconv_hwacandidate_b_artifact_hashes.json"
    hash_path.write_text(json.dumps({"schema": "C10-HWQA-v1-artifact-hashes", "variant_id": "B", "files": hashes}, indent=2) + "\n", encoding="utf-8")
    manifest_path = args.out / deploy_manifest["manifest_file"]
    manifest_hash = sha256_file(manifest_path)
    manifest_sha_path = DEFAULT_ROOT / "edgembconv_hwacandidate_b_manifest_sha256.json"
    manifest_sha_path.write_text(json.dumps({"path": str(manifest_path.relative_to(ROOT)).replace("\\", "/"), "sha256": manifest_hash}, indent=2) + "\n", encoding="utf-8")
    args.report.write_text(report_text(result, deploy_manifest, profile, bn_fold, str(hash_path.relative_to(ROOT)).replace("\\", "/")), encoding="utf-8")
    print(json.dumps(result, indent=2)); print(f"wrote {args.out / deploy_manifest['arrays']}"); print(f"wrote {args.result}"); print(f"wrote {args.report}")


if __name__ == "__main__":
    main(parse_args())
