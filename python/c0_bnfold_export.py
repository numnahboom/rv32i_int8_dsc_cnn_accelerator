#!/usr/bin/env python3
"""Fold C0 training BN and export the unchanged C0 INT8 primitive graph."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import torch

from c0_bnfold_model import C0BNTrainNet, fold_c0_bn
from quantize_export import (
    DS_SPECS,
    INPUT_SCALE,
    LOGIT_SCALE,
    RELU6_SCALE,
    evaluate_exported_int8_model,
    flat_to_dw_weight,
    flat_to_pw_weight,
    flat_to_stem_weight,
    make_qparams,
    quantize_weight_per_out_channel,
    run_exported_int8_model,
    i8_image_from_uint8,
)
from resnet20_hwqa import load_cifar10


def load_checkpoint(path: Path) -> dict[str, Any]:
    try:
        value = torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        value = torch.load(path, map_location="cpu")
    if not isinstance(value, dict) or "model_state" not in value:
        raise ValueError(f"invalid C0 BN-fold checkpoint: {path}")
    return value


def build_train_model(checkpoint: dict[str, Any]) -> C0BNTrainNet:
    model = C0BNTrainNet()
    model.load_state_dict(checkpoint["model_state"])
    return model.eval()


def fold_and_verify(checkpoint: dict[str, Any], images: np.ndarray, atol: float, rtol: float) -> tuple[dict[str, Any], torch.nn.Module]:
    train_model = build_train_model(checkpoint)
    folded = fold_c0_bn(train_model)
    # Use real frozen test images plus a deterministic non-image probe. This
    # catches both running-stat and per-channel affine mistakes.
    probe_u8 = np.concatenate([images[:16], np.random.default_rng(20260902).integers(0, 256, size=(4, 32, 32, 3), dtype=np.uint8)])
    probe = torch.from_numpy(probe_u8.transpose(0, 3, 1, 2)).float() * (1.0 / 127.5) - 1.0
    with torch.inference_mode():
        before = train_model(probe)
        after = folded(probe)
    difference = (before - after).abs()
    max_abs = float(difference.max())
    close = bool(torch.allclose(before, after, atol=atol, rtol=rtol))
    if not close:
        raise RuntimeError(f"BN fold mismatch max_abs={max_abs} atol={atol} rtol={rtol}")
    return {
        "samples": int(probe_u8.shape[0]),
        "max_abs_logit_diff": max_abs,
        "mean_abs_logit_diff": float(difference.mean()),
        "atol": atol,
        "rtol": rtol,
        "allclose": close,
        "input": "first 16 official test images plus four deterministic uint8 probes",
    }, folded


def tensor_np(value: torch.Tensor) -> np.ndarray:
    return value.detach().cpu().numpy().astype(np.float32)


def export_int8(folded: torch.nn.Module, sample: np.ndarray, checkpoint: dict[str, Any], out: Path, filename: str = "c0_bnfold_int8.npz") -> dict[str, Any]:
    params: dict[str, Any] = {
        "checkpoint_backend": np.asarray("torch_c0_bnfold_training_candidate"),
        "checkpoint_eval_acc": np.asarray(float(checkpoint.get("eval_acc", -1.0)), dtype=np.float32),
        "input_image_uint8": np.asarray(sample, dtype=np.uint8),
        "input_image_i8": np.asarray(i8_image_from_uint8(sample), dtype=np.int8),
        "input_zero_point": np.asarray(0, dtype=np.int32),
        "architecture": np.asarray("edgedscnet_c10_control_bn_folded"),
        "bn_runtime": np.asarray("none; all BN folded into predecessor"),
    }
    stem_w_q, stem_w_scale = quantize_weight_per_out_channel(tensor_np(folded.stem.weight))
    stem_b, stem_m, stem_s, stem_ozp, _, _ = make_qparams(tensor_np(folded.stem.bias), INPUT_SCALE, stem_w_scale, RELU6_SCALE, True)
    params.update({"stem_weight": np.asarray(flat_to_stem_weight(stem_w_q), dtype=np.int8), "stem_bias": stem_b, "stem_multiplier": stem_m, "stem_shift": stem_s, "stem_output_zero_point": np.asarray(stem_ozp, dtype=np.int32)})

    for block_idx, _, _, _, _, _ in DS_SPECS:
        block = folded.blocks[block_idx - 1]
        dw_w_q, dw_scale = quantize_weight_per_out_channel(tensor_np(block.dw.weight))
        pw_w_q, pw_scale = quantize_weight_per_out_channel(tensor_np(block.pw.weight))
        dw_b, dw_m, dw_s, dw_ozp, _, _ = make_qparams(tensor_np(block.dw.bias), RELU6_SCALE, dw_scale, RELU6_SCALE, True)
        pw_b, pw_m, pw_s, pw_ozp, _, _ = make_qparams(tensor_np(block.pw.bias), RELU6_SCALE, pw_scale, RELU6_SCALE, True)
        params.update({
            f"ds{block_idx}_dw_weight": np.asarray(flat_to_dw_weight(dw_w_q), dtype=np.int8),
            f"ds{block_idx}_dw_bias": dw_b, f"ds{block_idx}_dw_multiplier": dw_m, f"ds{block_idx}_dw_shift": dw_s, f"ds{block_idx}_dw_output_zero_point": np.asarray(dw_ozp, dtype=np.int32),
            f"ds{block_idx}_pw_weight": np.asarray(flat_to_pw_weight(pw_w_q), dtype=np.int8),
            f"ds{block_idx}_pw_bias": pw_b, f"ds{block_idx}_pw_multiplier": pw_m, f"ds{block_idx}_pw_shift": pw_s, f"ds{block_idx}_pw_output_zero_point": np.asarray(pw_ozp, dtype=np.int32),
        })

    fc_w_q, fc_scale = quantize_weight_per_out_channel(tensor_np(folded.fc.weight))
    fc_b, fc_m, fc_s, fc_ozp, _, _ = make_qparams(tensor_np(folded.fc.bias), RELU6_SCALE, fc_scale, LOGIT_SCALE, False)
    params.update({"fc_weight": np.asarray(fc_w_q, dtype=np.int8), "fc_bias": fc_b, "fc_multiplier": fc_m, "fc_shift": fc_s, "fc_output_zero_point": np.asarray(fc_ozp, dtype=np.int32)})
    logits, argmax = run_exported_int8_model(sample, params)
    params["expected_logits"] = np.asarray(logits, dtype=np.int8)
    params["expected_argmax"] = np.asarray(argmax, dtype=np.int32)
    out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out / filename, **params)
    return {"path": str(out / filename), "sample_logits": [int(v) for v in logits], "sample_argmax": int(argmax), "parameter_arrays": len(params)}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--checkpoint", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_fp32.pt"))
    p.add_argument("--data", type=Path, default=Path(r"D:\Stuff\data"))
    p.add_argument("--out", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_export"))
    p.add_argument("--equivalence", type=Path, default=Path("build/c0_bnfold_hwqa/c0_bnfold_bn_equivalence.json"))
    p.add_argument("--atol", type=float, default=2e-5)
    p.add_argument("--rtol", type=float, default=1e-5)
    args = p.parse_args()
    checkpoint = load_checkpoint(args.checkpoint)
    test_images, _ = load_cifar10(args.data, "test")
    equivalence, folded = fold_and_verify(checkpoint, test_images, args.atol, args.rtol)
    args.equivalence.parent.mkdir(parents=True, exist_ok=True)
    args.equivalence.write_text(json.dumps({"schema": "C10-HWQA-v1-c0-bnfold-equivalence", "checkpoint": str(args.checkpoint), "result": equivalence}, indent=2) + "\n", encoding="utf-8")
    folded_path = args.out.parent / "c0_bnfold_folded_fp32.pt"
    folded_path.parent.mkdir(parents=True, exist_ok=True)
    folded_ckpt = dict(checkpoint)
    folded_ckpt["schema"] = "C10-HWQA-v1-c0-bnfold-folded-fp32"
    folded_ckpt["architecture"] = "edgedscnet_c10_control_bn_folded"
    folded_ckpt["model_state"] = folded.state_dict()
    folded_ckpt["bn_fold_equivalence"] = equivalence
    torch.save(folded_ckpt, folded_path)
    export = export_int8(folded, test_images[0], checkpoint, args.out)
    manifest = {"schema": "C10-HWQA-v1-c0-bnfold-deploy", "architecture": "original C0 graph; BN folded before quantization", "checkpoint": str(folded_path), "export": export, "bn_fold_equivalence": equivalence, "quantization": "same C0 INT8 per-output-channel weights/int32 bias/requant contract"}
    manifest_path = args.out / "c0_bnfold_export_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"equivalence": equivalence, "folded_checkpoint": str(folded_path), "export": export, "manifest": str(manifest_path)}))


if __name__ == "__main__":
    main()
