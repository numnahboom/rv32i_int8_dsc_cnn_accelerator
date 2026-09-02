#!/usr/bin/env python3
"""Export and evaluate frozen EdgeMBConv hardware candidate D8.

The evaluator folds BN before exporting per-output-channel symmetric INT8
weights, then evaluates all 10,000 official CIFAR-10 test images using the
integer contract.  It emits only D8-named artifacts and makes no cycle,
synthesis, timing, power, or energy claim.
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

from edgembconv_hwacandidate_d8_model import (
    INPUT_SCALE, CandidateQATD8, EdgeMBConvCandidateD8, FoldedCandidateD8,
    assert_locked_profile, fold_candidate_d8,
)
from resnet20_hwqa import CifarDataset, load_cifar10
from export_eval_edgembconv_hwacandidate_a import (
    add_q, check_acc, conv1_q, conv3_q, quant_weight, ratio_qparams,
    round_away, state_np,
)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = ROOT / "build" / "edgembconv_hwacandidate_d8"
DEFAULT_QAT = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_qat.pt"
DEFAULT_FP32 = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_fp32.pt"
DEFAULT_OUT = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_deploy"
DEFAULT_RESULT = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_test10k.json"
DEFAULT_REPORT = ROOT / "docs" / "reports" / "edgembconv_hwacandidate_d8_hwqa_report_20260902.md"
PROFILE_REL = "build/edgembconv_hwacandidate/profile_D8.json"
STATIC_MANIFEST_REL = "build/edgembconv_hwacandidate/edgembconv_hwacandidate_manifest.json"
LOCKED_PROFILE = {"parameter_count": 254_714, "semantic_macs": 11_608_576,
                  "dense3x3": 442_368, "pw1x1": 10_223_616, "dw3x3": 940_032}
CLASS_NAMES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]


def load_state(path: Path) -> dict[str, Any]:
    try: return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError: return torch.load(path, map_location="cpu")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()


def verify_checkpoint(ckpt: dict[str, Any], profile: dict[str, Any], label: str) -> None:
    cp = ckpt.get("profile", {})
    if cp.get("variant_id") not in (None, "D8"):
        raise RuntimeError(f"{label} checkpoint identifies a non-D8 variant")
    if (int(cp.get("parameter_count", -1)) != int(profile["parameter_count"]) or
            int(cp.get("semantic_macs", -1)) != int(profile["semantic_macs"])):
        raise RuntimeError(f"{label} checkpoint is not locked candidate D8")


def export_arrays(ckpt: dict[str, Any], out: Path) -> tuple[dict[str, np.ndarray], dict[str, float], dict[str, Any]]:
    state = ckpt["model_state"]; scales = {k: float(v) for k, v in ckpt["scales"].items()}
    out.mkdir(parents=True, exist_ok=True); params: dict[str, np.ndarray] = {"input_scale": np.asarray(INPUT_SCALE, np.float32)}; layers: list[dict[str, Any]] = []

    def add_conv(name: str, key: str, in_s: float, out_s: float, kernel: int, stride: int, activation: str = "linear") -> None:
        w, ws = quant_weight(state_np(state, key + ".weight")); bfp = state_np(state, key + ".bias").astype(np.float64)
        bias = np.clip(round_away(bfp / (in_s * ws)), -(2 ** 31), 2 ** 31 - 1).astype(np.int32); mul, sh = ratio_qparams(in_s * ws / out_s)
        params.update({name + ".weight": w.astype(np.int8), name + ".weight_scale": ws.astype(np.float32), name + ".bias": bias, name + ".multiplier": mul, name + ".shift": sh})
        layers.append({"name": name, "source": key, "kernel": kernel, "stride": stride, "in_scale": in_s, "out_scale": out_s, "activation": activation, "accumulator": "int32", "bias_units": "input_scale*weight_scale", "rounding": "nearest_away_from_zero", "saturation": "int8"})

    in_s = INPUT_SCALE; add_conv("stem", "stem", in_s, scales["stem"], 3, 1, "relu6"); in_s = scales["stem"]

    def add_mb(prefix: str, source: str, cin_scale: float, stride: int, residual: bool) -> float:
        add_conv(prefix + ".expand", source + ".expand", cin_scale, scales[prefix + ".expand"], 1, 1, "relu6")
        add_conv(prefix + ".spatial", source + ".spatial", scales[prefix + ".expand"], scales[prefix + ".spatial"], 3, stride, "relu6")
        project_out = scales[prefix + (".project" if residual else ".out")]
        add_conv(prefix + ".project", source + ".project", scales[prefix + ".spatial"], project_out, 1, 1, "linear")
        return scales[prefix + ".out"]

    in_s = add_mb("mb32", "mb32", in_s, 1, True); in_s = add_mb("mb16_down", "mb16_down", in_s, 2, False)
    for i in (1, 2): in_s = add_mb(f"mb16.{i}", f"mb16.{i - 1}", in_s, 1, True)
    in_s = add_mb("mb8.down", "mb8_down", in_s, 2, False)
    for i in (1, 2): in_s = add_mb(f"mb8.{i}", f"mb8.{i - 1}", in_s, 1, True)
    in_s = add_mb("mb4.down", "mb4_down", in_s, 2, False)
    for i in (1, 2): in_s = add_mb(f"mb4.{i}", f"mb4.{i - 1}", in_s, 1, True)
    add_conv("head", "head", in_s, scales["head"], 1, 1, "linear")
    fw, fws = quant_weight(state_np(state, "fc.weight")); fb = state_np(state, "fc.bias").astype(np.float64)
    fbias = np.clip(round_away(fb / (scales["head"] * fws)), -(2 ** 31), 2 ** 31 - 1).astype(np.int32)
    params.update({"fc.weight": fw.astype(np.int8), "fc.weight_scale": fws.astype(np.float32), "fc.bias": fbias})
    layers.append({"name": "fc", "op": "linear", "in_scale": scales["head"], "weight_scale": fws.tolist(), "accumulator": "int32", "bias_units": "input_scale*weight_scale"})
    array_name = "edgembconv_hwacandidate_d8_int8.npz"; np.savez_compressed(out / array_name, **params)
    manifest = {"schema": "C10-HWQA-v1-edgembconv-hwacandidate-D8-deploy", "variant_id": "D8", "architecture": "D8_C_minus_one_mb8", "profile": LOCKED_PROFILE, "bn": "folded_into_conv_weight_and_bias_before_QAT", "quantization": {"input": "signed int8, zero point 0, scale 1/127.5", "weights": "symmetric per-output-channel int8 [-127,127]", "activations": "signed int8; ReLU6 [0,127], linear/residual [-128,127]", "accumulator": "int32 contract; reference computes int64 and checks bound", "bias": "int32 in input_scale*weight_scale units", "requant": "nearest-away-from-zero(acc*multiplier/2^shift), saturate to int8"}, "layers": layers, "source_checkpoint": str(ckpt.get("source_checkpoint", "candidate D8 QAT")), "arrays": array_name}
    manifest_name = "edgembconv_hwacandidate_d8_deploy_manifest.json"; (out / manifest_name).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8"); manifest["manifest_file"] = manifest_name
    return params, scales, manifest


def per_class(pred: np.ndarray, labels: np.ndarray) -> dict[str, Any]:
    total = np.bincount(labels, minlength=10); correct = np.bincount(labels[pred == labels], minlength=10)
    return {name: {"correct": int(correct[i]), "total": int(total[i]), "top1": float(correct[i] / max(1, total[i]))} for i, name in enumerate(CLASS_NAMES)}


@torch.no_grad()
def fp32_predict(ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, float]:
    model = EdgeMBConvCandidateD8(); model.load_state_dict(ckpt["model_state"]); model.eval(); loader = DataLoader(CifarDataset(images, labels, False, 20260904), batch_size=batch_size, shuffle=False, num_workers=0)
    pred = np.empty(labels.size, dtype=np.int64); offset = 0
    for x, _ in loader:
        logits = model(x); n = logits.shape[0]; pred[offset:offset + n] = logits.argmax(1).numpy(); offset += n
    return pred, float(np.mean(pred == labels))


@torch.no_grad()
def qat_predict(ckpt: dict[str, Any], fp_ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, float]:
    fp = EdgeMBConvCandidateD8(); fp.load_state_dict(fp_ckpt["model_state"]); fp.eval(); folded = fold_candidate_d8(fp); model = CandidateQATD8(folded, {k: float(v) for k, v in ckpt["scales"].items()}); model.load_state_dict(ckpt["model_state"]); model.eval()
    loader = DataLoader(CifarDataset(images, labels, False, 20260905), batch_size=batch_size, shuffle=False, num_workers=0); pred = np.empty(labels.size, dtype=np.int64); offset = 0
    for x, _ in loader:
        logits = model(x); n = logits.shape[0]; pred[offset:offset + n] = logits.argmax(1).numpy(); offset += n
    return pred, float(np.mean(pred == labels))


@torch.no_grad()
def bn_fold_equivalence(fp_ckpt: dict[str, Any], images: np.ndarray, labels: np.ndarray) -> dict[str, Any]:
    model = EdgeMBConvCandidateD8(); model.load_state_dict(fp_ckpt["model_state"]); model.eval(); folded: FoldedCandidateD8 = fold_candidate_d8(model); folded.eval(); ds = CifarDataset(images[:16], labels[:16], False, 20260906); batch = torch.stack([ds[i][0] for i in range(len(ds))]); a = model(batch); b = folded(batch); diff = (a - b).abs()
    return {"samples": int(batch.shape[0]), "max_abs_logit_diff": float(diff.max()), "mean_abs_logit_diff": float(diff.mean()), "allclose_atol_2e-5_rtol_1e-5": bool(torch.allclose(a, b, atol=2e-5, rtol=1e-5))}


def run_integer(params: dict[str, np.ndarray], scales: dict[str, float], images: np.ndarray, labels: np.ndarray, batch_size: int) -> tuple[np.ndarray, dict[str, int]]:
    pred = np.empty(labels.size, dtype=np.int64); stats = {"max_abs_accumulator": 0, "accumulator_checks": 0}
    for start in range(0, labels.size, batch_size):
        end = min(start + batch_size, labels.size); x = np.clip(images[start:end].astype(np.int16) - 128, -128, 127).astype(np.int8)
        x = conv3_q(x, params["stem.weight"], params["stem.bias"], params["stem.multiplier"], params["stem.shift"], 1, "stem", stats); x = np.clip(x, 0, 127).astype(np.int8); in_s = scales["stem"]
        def mb(prefix: str, stride: int, residual: bool) -> None:
            nonlocal x, in_s
            identity = x.copy() if residual else None; identity_s = in_s
            x = conv1_q(x, params[prefix + ".expand.weight"], params[prefix + ".expand.bias"], params[prefix + ".expand.multiplier"], params[prefix + ".expand.shift"], 1, prefix + ".expand", stats); x = np.clip(x, 0, 127).astype(np.int8)
            x = conv3_q(x, params[prefix + ".spatial.weight"], params[prefix + ".spatial.bias"], params[prefix + ".spatial.multiplier"], params[prefix + ".spatial.shift"], stride, prefix + ".spatial", stats); x = np.clip(x, 0, 127).astype(np.int8)
            x = conv1_q(x, params[prefix + ".project.weight"], params[prefix + ".project.bias"], params[prefix + ".project.multiplier"], params[prefix + ".project.shift"], 1, prefix + ".project", stats)
            if residual: x = add_q(identity, identity_s, x, scales[prefix + ".project"], scales[prefix + ".out"])
            in_s = scales[prefix + ".out"]
        mb("mb32", 1, True); mb("mb16_down", 2, False); mb("mb16.1", 1, True); mb("mb16.2", 1, True); mb("mb8.down", 2, False); mb("mb8.1", 1, True); mb("mb8.2", 1, True); mb("mb4.down", 2, False); mb("mb4.1", 1, True); mb("mb4.2", 1, True)
        x = conv1_q(x, params["head.weight"], params["head.bias"], params["head.multiplier"], params["head.shift"], 1, "head", stats); gap = round_away(x.astype(np.int64).sum(axis=(1, 2)) / 16.0).clip(-128, 127).astype(np.int8)
        acc = np.einsum("nc,oc->no", gap.astype(np.int64), params["fc.weight"].astype(np.int64), optimize=True) + params["fc.bias"].reshape(1, -1).astype(np.int64); check_acc(acc, "fc", stats); pred[start:end] = (acc.astype(np.float64) * params["fc.weight_scale"].reshape(1, -1)).argmax(1)
    return pred, stats


def curve_summary(path: Path) -> dict[str, Any]:
    if not path.exists(): return {"path": str(path), "exists": False}
    rows = json.loads(path.read_text(encoding="utf-8")).get("history", [])
    if not rows: return {"path": str(path.relative_to(ROOT)).replace("\\", "/"), "exists": True, "epochs": 0}
    best = max(rows, key=lambda r: float(r.get("val_acc", -1))); last = rows[-1]
    return {"path": str(path.relative_to(ROOT)).replace("\\", "/"), "exists": True, "epochs": len(rows), "best_epoch": int(best["epoch"]), "best_val_acc": float(best["val_acc"]), "first_val_acc": float(rows[0]["val_acc"]), "last_val_acc": float(last["val_acc"]), "last_train_acc": float(last.get("train_acc", 0.0))}


def report_text(result: dict[str, Any], manifest: dict[str, Any], profile: dict[str, Any], bn_fold: dict[str, Any], artifact_hash_path: str) -> str:
    fp, q, cmp = result["fp32"], result["int8"], result["comparison"]; drop = result["drop_pp"]
    lines = ["# EdgeMBConv hardware-aware candidate D8 — C10-HWQA-v1 result", "", "D8 is an independent frozen ablation: candidate C with exactly one 8x8 residual MBConv removed (the third block). C0, A, B, C, and D4 artifacts remain untouched.", "", "## Frozen graph guard", "", f"- Profile guard: **PASS** — params={profile['parameter_count']:,}, semantic MACs={profile['semantic_macs']:,}; dense3x3={LOCKED_PROFILE['dense3x3']:,}, PW={LOCKED_PROFILE['pw1x1']:,}, DW={LOCKED_PROFILE['dw3x3']:,}.", "- D8 removes `mb8.3` and retains `mb8.1`/`mb8.2`; the graph uses only dense3x3 stem, PW1x1, DW3x3, residual add, ReLU6, GAP, and FC primitives.", "- Dense 3x3 is 3.81% of semantic MACs (3.81% of convolution MACs); PW+DW are 96.17% of semantic MACs. No Fused-MBConv block exists and no single fused block can dominate.", "- BN is folded before QAT. Weights are symmetric per-output-channel INT8; activations are signed INT8; accumulators/folded biases follow the INT32 contract.", "", "## Accuracy (official CIFAR-10 test10k, final evaluation)", "", f"- FP32 top-1: **{100 * fp['top1']:.2f}%** ({fp['correct']}/{result['samples']})", f"- Deployment INT8 top-1: **{100 * q['top1']:.2f}%** ({q['correct']}/{result['samples']})", f"- FP32 → INT8 drop: **{drop:.3f} percentage points**", f"- Quality gate (INT8 >= 90%, drop <= 0.5 pp): **{'PASS' if result['quality_gate'] else 'FAIL'}**", "", "### Per-class top-1", "", "| Class | FP32 | INT8 |", "| --- | ---: | ---: |"]
    for name in fp["per_class"]: lines.append(f"| {name} | {100 * fp['per_class'][name]['top1']:.2f}% | {100 * q['per_class'][name]['top1']:.2f}% |")
    lines += ["", "## Training and quantization evidence", "", f"- FP32 learning curve: `{result['learning_curves']['fp32']['path']}`; {result['learning_curves']['fp32'].get('epochs', 0)} epochs, best validation {100 * result['learning_curves']['fp32'].get('best_val_acc', 0):.2f}% at epoch {result['learning_curves']['fp32'].get('best_epoch', 0)}.", f"- QAT learning curve: `{result['learning_curves']['qat']['path']}`; {result['learning_curves']['qat'].get('epochs', 0)} epochs, best validation {100 * result['learning_curves']['qat'].get('best_val_acc', 0):.2f}% at epoch {result['learning_curves']['qat'].get('best_epoch', 0)}.", f"- BN-fold equivalence: {bn_fold['samples']} images, max absolute logit difference {bn_fold['max_abs_logit_diff']:.6g}, allclose={bn_fold['allclose_atol_2e-5_rtol_1e-5']}.", f"- QAT fake-quant vs exported integer evaluator argmax agreement: {result['quant_equivalence']['matching_predictions']}/{result['samples']} ({100 * result['quant_equivalence']['agreement']:.3f}%).", f"- Integer overflow audit: {q['accumulator_checks']} checks; maximum absolute accumulator {q['max_abs_accumulator']:,}; INT32 limit 2,147,483,647; overflow={q['overflow']}.", "- Requantization: nearest-away-from-zero followed by INT8 saturation; integer reference uses INT64 only to audit the INT32 bound.", "", "## D8 versus candidate C, D4, and retained C0", "", f"- Removing `mb8.3` lowers D8 by {cmp['c_semantic_macs'] - profile['semantic_macs']:,} semantic MACs ({100 * (profile['semantic_macs'] / cmp['c_semantic_macs'] - 1):.2f}%) and {cmp['c_parameter_count'] - profile['parameter_count']:,} deployed parameters ({100 * (profile['parameter_count'] / cmp['c_parameter_count'] - 1):.2f}%).", "- D4 is referenced only as a quality/static-ledger comparison; no D8 cycle, synthesis, post-route, power, or energy claim is made.", "", "| Item | D8 | C | D4 | C0 anchor |", "| --- | ---: | ---: | ---: | ---: |", f"| FP32 top-1 | {100 * fp['top1']:.2f}% | {100 * cmp['c_fp32_top1']:.2f}% | {100 * cmp['d4_fp32_top1']:.2f}% | 70.05% |", f"| Deployment INT8 top-1 | {100 * q['top1']:.2f}% | {100 * cmp['c_int8_top1']:.2f}% | {100 * cmp['d4_int8_top1']:.2f}% | 66.16% |", f"| Semantic MAC | {profile['semantic_macs']:,} | {cmp['c_semantic_macs']:,} | {cmp['d4_semantic_macs']:,} | 5,136,896 |", f"| Parameters | {profile['parameter_count']:,} | {cmp['c_parameter_count']:,} | {cmp['d4_parameter_count']:,} | 72,010 |", "", "## Artifact hashes and evidence boundary", "", f"- D8 artifact hashes: `{artifact_hash_path}`.", f"- Deployment arrays/manifest: `{manifest['arrays']}` and `{manifest['manifest_file']}`.", "- No D8 cycle-model, RTL equivalence, synthesis, post-route, power, or energy claim is made here.", ""]
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__); p.add_argument("--qat", type=Path, default=DEFAULT_QAT); p.add_argument("--fp32", type=Path, default=DEFAULT_FP32); p.add_argument("--out", type=Path, default=DEFAULT_OUT); p.add_argument("--result", type=Path, default=DEFAULT_RESULT); p.add_argument("--report", type=Path, default=DEFAULT_REPORT); p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data")); p.add_argument("--batch-size", type=int, default=128); p.add_argument("--seed", type=int, default=20260902); return p.parse_args()


def main(args: argparse.Namespace) -> None:
    profile = assert_locked_profile()
    if not args.qat.exists() or not args.fp32.exists(): raise FileNotFoundError("candidate D8 FP32 and QAT checkpoints are required")
    qat = load_state(args.qat); fp_ckpt = load_state(args.fp32); verify_checkpoint(qat, profile, "QAT"); verify_checkpoint(fp_ckpt, profile, "FP32")
    params, scales, deploy_manifest = export_arrays(qat, args.out); images, labels = load_cifar10(args.data, "test")
    if labels.size != 10_000: raise RuntimeError(f"official test set must contain exactly 10000 samples, got {labels.size}")
    fp_pred, fp_top1 = fp32_predict(fp_ckpt, images, labels, args.batch_size); q_pred, q_stats = run_integer(params, scales, images, labels, args.batch_size); q_top1 = float(np.mean(q_pred == labels)); qat_pred, qat_top1 = qat_predict(qat, fp_ckpt, images, labels, args.batch_size); bn_fold = bn_fold_equivalence(fp_ckpt, images, labels)
    c_path = ROOT / "build" / "edgembconv_hwacandidate_c" / "edgembconv_hwacandidate_c_test10k.json"; d4_path = ROOT / "build" / "edgembconv_hwacandidate_d4" / "edgembconv_hwacandidate_d4_test10k.json"
    if not c_path.exists() or not d4_path.exists(): raise FileNotFoundError("candidate C and D4 comparison results are required")
    c, d4 = json.loads(c_path.read_text(encoding="utf-8")), json.loads(d4_path.read_text(encoding="utf-8"))
    result: dict[str, Any] = {"schema": "C10-HWQA-v1-edgembconv-hwacandidate-D8-test10k", "variant_id": "D8", "samples": int(labels.size), "profile": LOCKED_PROFILE, "fp32": {"top1": fp_top1, "correct": int(np.sum(fp_pred == labels)), "per_class": per_class(fp_pred, labels)}, "int8": {"top1": q_top1, "correct": int(np.sum(q_pred == labels)), "per_class": per_class(q_pred, labels), **q_stats, "overflow": bool(q_stats["max_abs_accumulator"] > 2 ** 31 - 1)}, "qat_fake_quant": {"top1": qat_top1, "correct": int(np.sum(qat_pred == labels))}, "drop_pp": (fp_top1 - q_top1) * 100.0, "quality_gate": bool(q_top1 >= 0.90 and (fp_top1 - q_top1) * 100.0 <= 0.5), "quant_equivalence": {"reference": "CandidateQATD8 argmax vs exported integer evaluator argmax", "matching_predictions": int(np.sum(qat_pred == q_pred)), "agreement": float(np.mean(qat_pred == q_pred))}, "bn_fold_equivalence": bn_fold, "learning_curves": {"fp32": curve_summary(DEFAULT_ROOT / "edgembconv_hwacandidate_d8_fp32_learning_curve.json"), "qat": curve_summary(DEFAULT_ROOT / "edgembconv_hwacandidate_d8_qat_learning_curve.json")}, "comparison": {"c_fp32_top1": float(c["fp32"]["top1"]), "c_int8_top1": float(c["int8"]["top1"]), "c_semantic_macs": int(c["profile"]["semantic_macs"]), "c_parameter_count": int(c["profile"]["parameter_count"]), "d4_fp32_top1": float(d4["fp32"]["top1"]), "d4_int8_top1": float(d4["int8"]["top1"]), "d4_semantic_macs": int(d4["profile"]["semantic_macs"]), "d4_parameter_count": int(d4["profile"]["parameter_count"]), "source": [str(c_path.relative_to(ROOT)).replace("\\", "/"), str(d4_path.relative_to(ROOT)).replace("\\", "/")]}}
    args.result.parent.mkdir(parents=True, exist_ok=True); args.result.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8"); args.report.parent.mkdir(parents=True, exist_ok=True)
    hash_files = [f for f in sorted(DEFAULT_ROOT.rglob("*")) if f.is_file()]; hash_files.extend([ROOT / PROFILE_REL, ROOT / STATIC_MANIFEST_REL, Path(__file__), Path(__file__).with_name("train_edgembconv_hwacandidate_d8.py"), Path(__file__).with_name("qat_edgembconv_hwacandidate_d8.py"), Path(__file__).with_name("edgembconv_hwacandidate_d8_model.py")]); hashes: dict[str, str] = {}
    for file in hash_files:
        if file.exists() and file.suffix.lower() != ".log" and file.name not in {"edgembconv_hwacandidate_d8_artifact_hashes.json", "edgembconv_hwacandidate_d8_manifest_sha256.json"}: hashes[str(file.relative_to(ROOT)).replace("\\", "/")] = sha256_file(file)
    hash_path = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_artifact_hashes.json"; hash_path.write_text(json.dumps({"schema": "C10-HWQA-v1-artifact-hashes", "variant_id": "D8", "files": hashes}, indent=2) + "\n", encoding="utf-8"); manifest_path = args.out.resolve() / deploy_manifest["manifest_file"]; manifest_sha_path = DEFAULT_ROOT / "edgembconv_hwacandidate_d8_manifest_sha256.json"; manifest_sha_path.write_text(json.dumps({"path": str(manifest_path.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256_file(manifest_path)}, indent=2) + "\n", encoding="utf-8"); args.report.write_text(report_text(result, deploy_manifest, profile, bn_fold, str(hash_path.relative_to(ROOT)).replace("\\", "/")), encoding="utf-8")
    print(json.dumps(result, indent=2)); print(f"wrote {args.out / deploy_manifest['arrays']}"); print(f"wrote {args.result}"); print(f"wrote {args.report}")


if __name__ == "__main__": main(parse_args())
