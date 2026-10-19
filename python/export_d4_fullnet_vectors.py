#!/usr/bin/env python3
"""Export frozen D4 full-network RTL vectors and packed parameter memories.

This exporter consumes the already-frozen D4 INT8 NPZ and deployment manifest.
It does not retrain, requantize, or modify model parameters.  Activations and
FC accumulators are generated with the existing integer reference primitives.
Residual LUT entries are ordered by signed input code from -128 through 127;
an unsigned activation byte therefore addresses entry ``raw_byte XOR 0x80``.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np

import export_eval_edgembconv_hwacandidate_a as ref_a
from resnet20_hwqa import CLASS_NAMES, find_cifar_dir, load_cifar10


ROOT = Path(__file__).resolve().parents[1]
FROZEN_MANIFEST = ROOT / "docs/reports/edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json"
DEPLOY_ROOT = ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy"
DEPLOY_NPZ = DEPLOY_ROOT / "edgembconv_hwacandidate_d4_int8.npz"
DEPLOY_MANIFEST = DEPLOY_ROOT / "edgembconv_hwacandidate_d4_deploy_manifest.json"
DEFAULT_DATA = Path(r"D:\Stuff\data")
DEFAULT_OUT = ROOT / "build/d4_fullnet_vectors"
DEFAULT_REPORT = ROOT / "build/reports/d4_fullnet_vectors_20261018"
ACTIVATION_WORD_BITS = 128
PARAM_WORD_BITS = 512
ACTIVATION_SLOT_WORDS = 2048
DESCRIPTOR_WORDS = 32
INVALID_UNUSED_SLOT = 0

OP_CONV = 0
OP_ADD = 1
OP_GAP = 2
OP_FC = 3

BLOCKS: tuple[tuple[str, str, int, bool], ...] = (
    ("mb32", "mb32", 1, True),
    ("mb16_down", "mb16_down", 2, False),
    ("mb16.1", "mb16.0", 1, True),
    ("mb16.2", "mb16.1", 1, True),
    ("mb8.down", "mb8_down", 2, False),
    ("mb8.1", "mb8.0", 1, True),
    ("mb8.2", "mb8.1", 1, True),
    ("mb8.3", "mb8.2", 1, True),
    ("mb4.down", "mb4_down", 2, False),
    ("mb4.1", "mb4.0", 1, True),
)


class ExportError(RuntimeError):
    """Raised when an artifact does not satisfy the frozen D4 contract."""


@dataclass
class Operation:
    index: int
    name: str
    kind: int
    input_slot: int
    output_slot: int
    identity_slot: int
    hin: int
    win: int
    cin: int
    cout: int
    hout: int
    wout: int
    kernel: int = 1
    stride: int = 1
    depthwise: int = 0
    relu: int = 0
    weight_base: int = 0
    quant_base: int = 0
    lut_a_base: int = 0
    lut_b_base: int = 0
    semantic_macs: int = 0
    input_word_count: int = 0
    output_word_count: int = 0
    source: str = ""
    in_scale: float = 0.0
    out_scale: float = 0.0
    activation: str = ""
    tap_offset: int = 0

    def descriptor_words(self) -> list[int]:
        win_log = int(math.log2(self.win)) if self.win > 0 else 0
        cin_groups16 = max(1, (self.cin + 15) // 16)
        if cin_groups16 & (cin_groups16 - 1):
            raise ExportError(f"{self.name}: ceil(Cin/16) must be a power of two, got {cin_groups16}")
        cin_group_log = int(math.log2(cin_groups16))
        words = [
            self.kind, self.input_slot, self.output_slot, self.identity_slot,
            self.hin, self.win, self.cin, self.cout, self.hout, self.wout,
            self.kernel, self.stride, self.depthwise, self.relu,
            self.weight_base, self.quant_base, self.lut_a_base, self.lut_b_base,
            win_log, cin_group_log, self.output_word_count,
            self.input_word_count,
        ]
        words.extend([0] * (DESCRIPTOR_WORDS - len(words)))
        if len(words) != DESCRIPTOR_WORDS:
            raise AssertionError("descriptor size changed")
        return words


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_frozen_sources(frozen_manifest: Path = FROZEN_MANIFEST) -> dict[str, str]:
    """Verify every file recorded by the authoritative D4 software freeze."""
    manifest = json.loads(frozen_manifest.read_text(encoding="utf-8"))
    if manifest.get("variant_id") != "D4" or manifest.get("status") != "software_network_frozen_rtl_unpromoted":
        raise ExportError(f"not the expected frozen D4 software manifest: {frozen_manifest}")
    expected_profile = {
        "parameter_count": 204_090,
        "semantic_macs": 11_645_440,
        "ops": 23_290_880,
        "dense3x3_macs": 442_368,
        "pw1x1_macs": 10_223_616,
        "dw3x3_macs": 976_896,
    }
    recorded_ledger = manifest.get("ledger", {})
    if any(recorded_ledger.get(key) != value for key, value in expected_profile.items()):
        raise ExportError(f"frozen D4 semantic ledger changed: {recorded_ledger}")
    actual: dict[str, str] = {str(frozen_manifest.relative_to(ROOT)).replace("\\", "/"): sha256_file(frozen_manifest)}
    mismatches: list[str] = []
    for item in manifest.get("files", []):
        rel = str(item["path"])
        path = ROOT / Path(rel)
        if not path.is_file():
            mismatches.append(f"missing {rel}")
            continue
        got = sha256_file(path)
        actual[rel] = got
        if got.lower() != str(item["sha256"]).lower():
            mismatches.append(f"sha256 {rel}: expected {item['sha256']}, got {got}")
    if mismatches:
        raise ExportError("D4 frozen source audit failed: " + "; ".join(mismatches))
    return actual


def load_frozen_deployment(
    npz_path: Path = DEPLOY_NPZ, manifest_path: Path = DEPLOY_MANIFEST
) -> tuple[dict[str, np.ndarray], dict[str, Any], dict[str, float]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("variant_id") != "D4" or manifest.get("profile", {}).get("semantic_macs") != 11_645_440:
        raise ExportError("deployment manifest is not the frozen D4 graph")
    if manifest.get("arrays") != npz_path.name:
        raise ExportError(f"deployment manifest expects {manifest.get('arrays')}, got {npz_path.name}")
    expected_names = ["stem"]
    expected_names.extend(f"{prefix}.{part}" for prefix, _, _, _ in BLOCKS for part in ("expand", "spatial", "project"))
    expected_names.extend(["head", "fc"])
    layer_names = [layer.get("name") for layer in manifest.get("layers", [])]
    if layer_names != expected_names:
        raise ExportError(f"D4 deployment layer order changed: {layer_names}")
    arrays: dict[str, np.ndarray] = {}
    with np.load(npz_path, allow_pickle=False) as archive:
        arrays = {key: archive[key].copy() for key in archive.files}
    if "input_scale" not in arrays or not np.isclose(float(arrays["input_scale"]), 1.0 / 127.5):
        raise ExportError("frozen NPZ input scale disagrees with the D4 contract")
    for layer in manifest["layers"][:-1]:
        name = str(layer["name"])
        for suffix in ("weight", "bias", "multiplier", "shift"):
            if name + "." + suffix not in arrays:
                raise ExportError(f"frozen NPZ missing {name}.{suffix}")
    for key in ("fc.weight", "fc.bias", "fc.weight_scale"):
        if key not in arrays:
            raise ExportError(f"frozen NPZ missing {key}")
    scales: dict[str, float] = {}
    by_name = {str(layer["name"]): layer for layer in manifest["layers"]}
    for name, layer in by_name.items():
        if name != "fc":
            scales[name] = float(layer["out_scale"])
    # The residual output scale is the next block's input scale. The manifest
    # records that value on the next expand (or head), matching the frozen evaluator.
    block_prefixes = [prefix for prefix, _, _, _ in BLOCKS]
    next_expand_names = [f"{prefix}.expand" for prefix in block_prefixes[1:]] + ["head"]
    for i, prefix in enumerate(block_prefixes):
        scales[prefix + ".out"] = float(by_name[next_expand_names[i]]["in_scale"])
    scales["head"] = float(by_name["head"]["out_scale"])
    return arrays, manifest, scales


def _assert_source_names(manifest: dict[str, Any]) -> None:
    by_name = {str(item["name"]): str(item.get("source", "")) for item in manifest["layers"]}
    expected: dict[str, str] = {"stem": "stem", "head": "head"}
    for prefix, source, _, _ in BLOCKS:
        for part in ("expand", "spatial", "project"):
            expected[f"{prefix}.{part}"] = f"{source}.{part}"
    if {name: by_name.get(name) for name in expected} != expected:
        raise ExportError("D4 deployment source-name mapping disagrees with the frozen D4 mapping")


def round_away_integer(numerator: np.ndarray | int, denominator: np.ndarray | int) -> np.ndarray:
    n = np.asarray(numerator, dtype=np.int64)
    d = np.asarray(denominator, dtype=np.int64)
    if np.any(d <= 0):
        raise ValueError("rounding denominator must be positive")
    mag = (np.abs(n) + d // 2) // d
    return np.where(n < 0, -mag, mag).astype(np.int64)


def requant_exact(acc: np.ndarray, multiplier: np.ndarray, shift: np.ndarray) -> np.ndarray:
    """Signed INT32 multiply, nearest-away right shift, then INT8 saturation."""
    a = np.asarray(acc, dtype=np.int64)
    m = np.asarray(multiplier, dtype=np.int64)
    s = np.asarray(shift, dtype=np.int64)
    if np.any(s < 0) or np.any(s > 31):
        raise ExportError(f"requant shift outside hardware range: {s.min()}..{s.max()}")
    product = a * m
    divisor = np.left_shift(np.ones(np.broadcast_shapes(product.shape, s.shape), dtype=np.int64), s)
    rounded = round_away_integer(product, divisor)
    return np.clip(rounded, -128, 127).astype(np.int8)


def gap_round_away(x: np.ndarray) -> np.ndarray:
    values = np.asarray(x, dtype=np.int64)
    if values.ndim != 4 or values.shape[1:3] != (4, 4):
        raise ExportError(f"D4 GAP expects [N,4,4,C], got {values.shape}")
    total = values.sum(axis=(1, 2), dtype=np.int64)
    return np.clip(round_away_integer(total, 16), -128, 127).astype(np.int8)


def pack_lanes(values: Iterable[int], lane_bits: int, lane_count: int) -> str:
    vals = list(values)
    if len(vals) != lane_count:
        raise ValueError(f"expected {lane_count} lanes, got {len(vals)}")
    mask = (1 << lane_bits) - 1
    word = 0
    for lane, value in enumerate(vals):
        word |= (int(value) & mask) << (lane * lane_bits)
    return f"{word:0{lane_bits * lane_count // 4}x}"


def pack_signed32_word(values: Iterable[int]) -> str:
    return pack_lanes(values, 32, 16)


def pack_weight_word(values: Iterable[int]) -> str:
    return pack_lanes(values, 8, 64)


def decode_lanes(word_hex: str, lane_bits: int, lane_count: int, signed: bool = False) -> list[int]:
    word = int(word_hex, 16)
    mask = (1 << lane_bits) - 1
    out = []
    for lane in range(lane_count):
        value = (word >> (lane * lane_bits)) & mask
        if signed and value & (1 << (lane_bits - 1)):
            value -= 1 << lane_bits
        out.append(value)
    return out


def pack_activation_tensor(x: np.ndarray) -> list[str]:
    values = np.asarray(x)
    if values.ndim != 3:
        raise ExportError(f"activation image must be HWC, got {values.shape}")
    h, w, channels = values.shape
    padded_channels = ((channels + 15) // 16) * 16
    padded = np.zeros((h, w, padded_channels), dtype=np.int8)
    padded[:, :, :channels] = values.astype(np.int8)
    return [
        pack_lanes(padded[y, x, group : group + 16], 8, 16)
        for y in range(h)
        for x in range(w)
        for group in range(0, padded_channels, 16)
    ]


def unpack_activation_words(words: Iterable[str], h: int, w: int, channels: int) -> np.ndarray:
    count_groups = (channels + 15) // 16
    decoded = np.zeros((h, w, count_groups * 16), dtype=np.int8)
    items = list(words)
    expected = h * w * count_groups
    if len(items) != expected:
        raise ExportError(f"activation word count mismatch: expected {expected}, got {len(items)}")
    i = 0
    for y in range(h):
        for x in range(w):
            for group in range(count_groups):
                lanes = decode_lanes(items[i], 8, 16, signed=True)
                decoded[y, x, group * 16 : (group + 1) * 16] = lanes
                i += 1
    return decoded[:, :, :channels]


def _weight_at(w: np.ndarray, oc: int, ic: int, ky: int, kx: int) -> int:
    return int(w[oc, ic, ky, kx])


def pack_conv_weights(weight: np.ndarray, kernel: int, depthwise: bool) -> list[str]:
    w = np.asarray(weight, dtype=np.int8)
    cout = int(w.shape[0])
    groups_out = (cout + 15) // 16
    words: list[str] = []
    if depthwise:
        if w.ndim != 4 or w.shape[1] != 1 or w.shape[2:] != (kernel, kernel):
            raise ExportError(f"depthwise weight shape is invalid: {w.shape}")
        for og in range(groups_out):
            for ky in range(kernel):
                for kx in range(kernel):
                    lanes = [
                        (int(w[og * 16 + olane, 0, ky, kx]) & 0xFF)
                        if og * 16 + olane < cout else 0
                        for olane in range(16)
                    ]
                    # Each signed byte occupies the low byte of a 32-bit OC lane.
                    words.append(pack_lanes(lanes, 32, 16))
        return words
    if kernel == 1 and w.ndim == 4:
        w = w.reshape(w.shape[0], w.shape[1])
    if kernel == 1 and w.ndim == 2:
        cin = int(w.shape[1])
        for og in range(groups_out):
            for icg in range((cin + 3) // 4):
                bytes_out: list[int] = []
                for olane in range(16):
                    oc = og * 16 + olane
                    for ilane in range(4):
                        ic = icg * 4 + ilane
                        bytes_out.append(int(w[oc, ic]) if oc < cout and ic < cin else 0)
                words.append(pack_weight_word(bytes_out))
        return words
    if w.ndim != 4:
        raise ExportError(f"dense convolution weight shape is invalid: {w.shape}")
    cin = int(w.shape[1])
    for og in range(groups_out):
        for ky in range(kernel):
            for kx in range(kernel):
                for icg in range((cin + 3) // 4):
                    bytes_out = []
                    for olane in range(16):
                        oc = og * 16 + olane
                        for ilane in range(4):
                            ic = icg * 4 + ilane
                            bytes_out.append(_weight_at(w, oc, ic, ky, kx) if oc < cout and ic < cin else 0)
                    words.append(pack_weight_word(bytes_out))
    return words


def pack_fc_weights(weight: np.ndarray) -> list[str]:
    w = np.asarray(weight, dtype=np.int8)
    if w.ndim != 2 or w.shape[0] != 10 or w.shape[1] != 256:
        raise ExportError(f"FC weight shape changed: {w.shape}")
    words: list[str] = []
    for icg in range(64):
        values = []
        for oc in range(16):
            for ilane in range(4):
                ic = icg * 4 + ilane
                values.append(int(w[oc, ic]) if oc < 10 else 0)
        words.append(pack_weight_word(values))
    return words


def unpack_conv_weights(words: list[str], weight_shape: tuple[int, ...], kernel: int, depthwise: bool) -> np.ndarray:
    cout = int(weight_shape[0])
    decoded = np.zeros(weight_shape, dtype=np.int8)
    groups_out = (cout + 15) // 16
    cursor = 0
    if depthwise:
        for og in range(groups_out):
            for ky in range(kernel):
                for kx in range(kernel):
                    lanes32 = decode_lanes(words[cursor], 32, 16, signed=False)
                    cursor += 1
                    for olane, lane32 in enumerate(lanes32):
                        if lane32 & 0xFFFFFF00:
                            raise ExportError("depthwise weight lane has nonzero bits above low byte")
                        oc = og * 16 + olane
                        if oc < cout:
                            byte = lane32 & 0xFF
                            decoded[oc, 0, ky, kx] = byte - 256 if byte & 0x80 else byte
        return decoded
    if len(weight_shape) == 4:
        cin = int(weight_shape[1])
    elif len(weight_shape) == 2 and kernel == 1:
        cin = int(weight_shape[1])
    else:
        raise ExportError(f"unsupported weight shape for unpack: {weight_shape}")
    for og in range(groups_out):
        for ky in range(kernel):
            for kx in range(kernel):
                for icg in range((cin + 3) // 4):
                    lanes = decode_lanes(words[cursor], 8, 64, signed=True)
                    cursor += 1
                    for olane in range(16):
                        oc = og * 16 + olane
                        for ilane in range(4):
                            ic = icg * 4 + ilane
                            value = lanes[olane * 4 + ilane]
                            if oc < cout and ic < cin:
                                if len(weight_shape) == 4:
                                    decoded[oc, ic, ky, kx] = value
                                else:
                                    decoded[oc, ic] = value
                            elif value != 0:
                                raise ExportError("weight memory padding lane is nonzero")
    return decoded


def unpack_fc_weights(words: list[str]) -> np.ndarray:
    if len(words) != 64:
        raise ExportError(f"FC expected 64 words, got {len(words)}")
    decoded = np.zeros((10, 256), dtype=np.int8)
    for icg, word in enumerate(words):
        lanes = decode_lanes(word, 8, 64, signed=True)
        for oc in range(16):
            for ilane in range(4):
                value = lanes[oc * 4 + ilane]
                if oc < 10:
                    decoded[oc, icg * 4 + ilane] = value
                elif value != 0:
                    raise ExportError("FC padded output weight lane is nonzero")
    return decoded


def validate_parameter_rom_mapping(
    ops: list[Operation], roms: dict[str, list[str]], arrays: dict[str, np.ndarray],
) -> dict[str, int]:
    checked_conv_weights = 0
    checked_fc_weights = 0
    checked_quant_groups = 0
    for op in ops:
        if op.kind == OP_CONV:
            source = np.asarray(arrays[op.name + ".weight"], dtype=np.int8)
            words = pack_conv_weights(source, op.kernel, bool(op.depthwise))
            start = op.weight_base
            actual = unpack_conv_weights(roms["weights.mem"][start : start + len(words)], source.shape, op.kernel, bool(op.depthwise))
            if not np.array_equal(actual, source):
                raise ExportError(f"{op.name}: packed parameter inverse differs from frozen NPZ")
            checked_conv_weights += int(source.size)
            for group in range((op.cout + 15) // 16):
                for filename, key in (("bias.mem", "bias"), ("multiplier.mem", "multiplier"), ("shift.mem", "shift")):
                    packed = roms[filename][op.quant_base + group]
                    lanes = decode_lanes(packed, 32, 16, signed=True)
                    src = arrays[op.name + "." + key]
                    expected = [int(v) for v in src[group * 16 : group * 16 + 16]]
                    expected.extend([0] * (16 - len(expected)))
                    if lanes != expected:
                        raise ExportError(f"{op.name}: {filename} lane mapping differs from frozen NPZ")
                checked_quant_groups += 1
        elif op.kind == OP_FC:
            actual = unpack_fc_weights(roms["weights.mem"][op.weight_base : op.weight_base + 64])
            if not np.array_equal(actual, arrays["fc.weight"]):
                raise ExportError("FC packed weight inverse differs from frozen NPZ")
            checked_fc_weights = int(actual.size)
            for filename, key in (("bias.mem", "bias"), ("multiplier.mem", None), ("shift.mem", None)):
                lanes = decode_lanes(roms[filename][op.quant_base], 32, 16, signed=True)
                expected = ([int(v) for v in arrays["fc.bias"]] + [0] * 6) if key else [0] * 16
                if lanes != expected:
                    raise ExportError(f"FC {filename} lane mapping is invalid")
    return {"conv_weight_values": checked_conv_weights, "fc_weight_values": checked_fc_weights,
            "quant_groups": checked_quant_groups}


def build_residual_lut(identity_scale: float, project_scale: float, output_scale: float) -> tuple[list[int], list[int]]:
    """Return tables addressed by signed_code + 128 (raw byte XOR 0x80)."""
    codes = np.arange(-128, 128, dtype=np.int64)
    a = ref_a.round_away(codes.astype(np.float64) * (identity_scale / output_scale)).astype(np.int64)
    b = ref_a.round_away(codes.astype(np.float64) * (project_scale / output_scale)).astype(np.int64)
    limit = np.iinfo(np.int16)
    if np.any(a < limit.min) or np.any(a > limit.max) or np.any(b < limit.min) or np.any(b > limit.max):
        raise ExportError("residual contribution LUT exceeds signed16 bounds")
    return a.tolist(), b.tolist()


def _conv_shapes(arrays: dict[str, np.ndarray], name: str, layer: dict[str, Any]) -> tuple[int, int, int, int]:
    weight = np.asarray(arrays[name + ".weight"])
    kernel = int(layer["kernel"])
    if name == "stem":
        cin = int(weight.shape[1])
    elif name.endswith(".spatial"):
        if weight.ndim != 4 or weight.shape[1] != 1:
            raise ExportError(f"D4 spatial op is not depthwise: {name}, {weight.shape}")
        cin = int(weight.shape[0])
    elif kernel == 1:
        cin = int(weight.shape[1])
    else:
        raise ExportError(f"unexpected D4 conv kernel for {name}: {kernel}")
    cout = int(weight.shape[0])
    return cin, cout, kernel, int(layer["stride"])


def _conv_macs(hout: int, wout: int, cin: int, cout: int, kernel: int, depthwise: bool) -> int:
    return int(hout * wout * (cout if depthwise else cin * cout) * kernel * kernel)


def _make_conv_op(
    *, index: int, name: str, arrays: dict[str, np.ndarray], layer: dict[str, Any],
    h: int, w: int, input_slot: int, output_slot: int,
) -> Operation:
    cin, cout, kernel, stride = _conv_shapes(arrays, name, layer)
    hout, wout = (h + stride - 1) // stride, (w + stride - 1) // stride
    depthwise = int(name.endswith(".spatial"))
    in_words = h * w * ((cin + 15) // 16)
    out_words = hout * wout * ((cout + 15) // 16)
    if max(in_words, out_words) > ACTIVATION_SLOT_WORDS:
        raise ExportError(f"{name}: activation needs {max(in_words, out_words)} words, slot limit is {ACTIVATION_SLOT_WORDS}")
    return Operation(
        index=index, name=name, kind=OP_CONV, input_slot=input_slot,
        output_slot=output_slot, identity_slot=INVALID_UNUSED_SLOT,
        hin=h, win=w, cin=cin, cout=cout, hout=hout, wout=wout,
        kernel=kernel, stride=stride, depthwise=depthwise,
        relu=int(layer.get("activation") == "relu6"), semantic_macs=_conv_macs(hout, wout, cin, cout, kernel, bool(depthwise)),
        input_word_count=in_words, output_word_count=out_words,
        source=str(layer.get("source", "")), in_scale=float(layer["in_scale"]),
        out_scale=float(layer["out_scale"]), activation=str(layer.get("activation", "")),
    )


def build_operations(arrays: dict[str, np.ndarray], manifest: dict[str, Any], scales: dict[str, float]) -> list[Operation]:
    _assert_source_names(manifest)
    layers = {str(row["name"]): row for row in manifest["layers"]}
    ops: list[Operation] = []
    current_slot = 0  # input.mem is streamed into activation slot 0.
    stem = _make_conv_op(index=0, name="stem", arrays=arrays, layer=layers["stem"], h=32, w=32, input_slot=0, output_slot=1)
    ops.append(stem)
    current_slot = stem.output_slot
    current_h, current_w = stem.hout, stem.wout
    current_channels = stem.cout

    for prefix, _source, stride, residual in BLOCKS:
        input_slot = current_slot
        expand_slot = (input_slot + 1) % 3
        spatial_slot = (input_slot + 2) % 3
        part_names = (f"{prefix}.expand", f"{prefix}.spatial", f"{prefix}.project")
        expand = _make_conv_op(index=len(ops), name=part_names[0], arrays=arrays, layer=layers[part_names[0]], h=current_h, w=current_w, input_slot=input_slot, output_slot=expand_slot)
        ops.append(expand)
        spatial = _make_conv_op(index=len(ops), name=part_names[1], arrays=arrays, layer=layers[part_names[1]], h=expand.hout, w=expand.wout, input_slot=expand_slot, output_slot=spatial_slot)
        if spatial.cin != expand.cout:
            raise ExportError(f"{prefix}: expansion/spatial channel boundary mismatch")
        ops.append(spatial)
        project = _make_conv_op(index=len(ops), name=part_names[2], arrays=arrays, layer=layers[part_names[2]], h=spatial.hout, w=spatial.wout, input_slot=spatial_slot, output_slot=expand_slot)
        if project.cin != spatial.cout:
            raise ExportError(f"{prefix}: spatial/project channel boundary mismatch")
        ops.append(project)
        if residual:
            if current_h != project.hout or current_w != project.wout or current_channels != project.cout:
                raise ExportError(f"{prefix}: residual tensors do not have matching shapes")
            add = Operation(
                index=len(ops), name=prefix + ".add", kind=OP_ADD,
                input_slot=expand_slot, output_slot=expand_slot, identity_slot=input_slot,
                hin=current_h, win=current_w, cin=current_channels, cout=current_channels,
                hout=current_h, wout=current_w, semantic_macs=0,
                input_word_count=current_h * current_w * ((current_channels + 15) // 16),
                output_word_count=current_h * current_w * ((current_channels + 15) // 16),
                in_scale=float(layers[part_names[0]]["in_scale"]),
                out_scale=float(scales[prefix + ".out"]), activation="linear",
            )
            ops.append(add)
            current_slot = expand_slot
        else:
            current_slot = expand_slot
        current_h, current_w, current_channels = project.hout, project.wout, project.cout

    head = _make_conv_op(index=len(ops), name="head", arrays=arrays, layer=layers["head"], h=current_h, w=current_w, input_slot=current_slot, output_slot=(current_slot + 1) % 3)
    if head.cin != current_channels:
        raise ExportError("D4 final MBConv/head channel boundary mismatch")
    ops.append(head)

    gap_slot = (head.output_slot + 1) % 3
    gap = Operation(
        index=len(ops), name="gap", kind=OP_GAP, input_slot=head.output_slot,
        output_slot=gap_slot, identity_slot=INVALID_UNUSED_SLOT,
        hin=head.hout, win=head.wout, cin=head.cout, cout=head.cout,
        hout=1, wout=1, kernel=1, stride=1,
        input_word_count=head.hout * head.wout * ((head.cout + 15) // 16),
        output_word_count=(head.cout + 15) // 16,
    )
    ops.append(gap)

    fc = Operation(
        index=len(ops), name="fc", kind=OP_FC, input_slot=gap_slot,
        output_slot=INVALID_UNUSED_SLOT, identity_slot=INVALID_UNUSED_SLOT,
        hin=1, win=1, cin=256, cout=10, hout=1, wout=1,
        kernel=1, stride=1, input_word_count=16, output_word_count=10,
        semantic_macs=256 * 10,
    )
    ops.append(fc)
    if len(ops) != 41 or sum(op.kind == OP_ADD for op in ops) != 7:
        raise ExportError(f"D4 expected 41 ops with 7 residual adds, got {len(ops)} ops")
    return ops


def _capture_accumulators() -> tuple[dict[str, np.ndarray], Any]:
    captured: dict[str, np.ndarray] = {}
    original = ref_a.check_acc

    def capture(acc: np.ndarray, label: str, stats: dict[str, int]) -> None:
        original(acc, label, stats)
        captured[label] = np.asarray(acc, dtype=np.int64).copy()

    ref_a.check_acc = capture
    return captured, original


def _restore_check_acc(original: Any) -> None:
    ref_a.check_acc = original


def run_reference_taps(
    arrays: dict[str, np.ndarray], manifest: dict[str, Any], scales: dict[str, float],
    image: np.ndarray,
) -> tuple[dict[str, np.ndarray], dict[str, np.ndarray], np.ndarray, np.ndarray, dict[str, Any]]:
    """Run one unsigned CIFAR image through existing exact integer primitives."""
    x_u8 = np.asarray(image, dtype=np.uint8)
    if x_u8.shape != (32, 32, 3):
        raise ExportError(f"expected one CIFAR HWC image, got {x_u8.shape}")
    x = np.clip(x_u8.astype(np.int16) - 128, -128, 127).astype(np.int8)[None, ...]
    taps: dict[str, np.ndarray] = {}
    accumulators, original_check = _capture_accumulators()
    stats: dict[str, int] = {"max_abs_accumulator": 0, "accumulator_checks": 0}
    try:
        x = ref_a.conv3_q(x, arrays["stem.weight"], arrays["stem.bias"], arrays["stem.multiplier"], arrays["stem.shift"], 1, "stem", stats)
        x = np.clip(x, 0, 127).astype(np.int8)
        taps["stem"] = x[0].copy()
        in_s = scales["stem"]

        def run_block(prefix: str, stride: int, residual: bool) -> None:
            nonlocal x, in_s
            identity = x.copy() if residual else None
            identity_s = in_s
            x = ref_a.conv1_q(x, arrays[prefix + ".expand.weight"], arrays[prefix + ".expand.bias"], arrays[prefix + ".expand.multiplier"], arrays[prefix + ".expand.shift"], 1, prefix + ".expand", stats)
            x = np.clip(x, 0, 127).astype(np.int8)
            taps[prefix + ".expand"] = x[0].copy()
            x = ref_a.conv3_q(x, arrays[prefix + ".spatial.weight"], arrays[prefix + ".spatial.bias"], arrays[prefix + ".spatial.multiplier"], arrays[prefix + ".spatial.shift"], stride, prefix + ".spatial", stats)
            x = np.clip(x, 0, 127).astype(np.int8)
            taps[prefix + ".spatial"] = x[0].copy()
            x = ref_a.conv1_q(x, arrays[prefix + ".project.weight"], arrays[prefix + ".project.bias"], arrays[prefix + ".project.multiplier"], arrays[prefix + ".project.shift"], 1, prefix + ".project", stats)
            taps[prefix + ".project"] = x[0].copy()
            if residual:
                x = ref_a.add_q(identity, identity_s, x, scales[prefix + ".project"], scales[prefix + ".out"])
                taps[prefix + ".add"] = x[0].copy()
            in_s = scales[prefix + ".out"]

        for prefix, _source, stride, residual in BLOCKS:
            run_block(prefix, stride, residual)
        x = ref_a.conv1_q(x, arrays["head.weight"], arrays["head.bias"], arrays["head.multiplier"], arrays["head.shift"], 1, "head", stats)
        taps["head"] = x[0].copy()
        gap = ref_a.round_away(x.astype(np.int64).sum(axis=(1, 2)) / 16.0).clip(-128, 127).astype(np.int8)
        taps["gap"] = gap[0].reshape(1, 1, -1).copy()
        fc_acc64 = np.einsum("nc,oc->no", gap.astype(np.int64), arrays["fc.weight"].astype(np.int64), optimize=True)
        fc_acc64 += arrays["fc.bias"].reshape(1, -1).astype(np.int64)
        original_check(fc_acc64, "fc", stats)
        fc_acc = fc_acc64.astype(np.int32)
    finally:
        _restore_check_acc(original_check)
    return taps, accumulators, gap[0], fc_acc[0], stats


def validate_requant_observed(
    accumulators: dict[str, np.ndarray], arrays: dict[str, np.ndarray],
) -> dict[str, Any]:
    rows = []
    total_values = 0
    for name, acc in accumulators.items():
        prefix = name
        mul = arrays[prefix + ".multiplier"].reshape((1,) * (acc.ndim - 1) + (-1,))
        shift = arrays[prefix + ".shift"].reshape((1,) * (acc.ndim - 1) + (-1,))
        exact = requant_exact(acc, mul, shift)
        reference = ref_a.requant(acc, mul, shift)
        mismatches = int(np.count_nonzero(exact != reference))
        rows.append({"layer": name, "values": int(acc.size), "float_reference_mismatches": mismatches,
                     "max_abs_accumulator": int(np.max(np.abs(acc))) if acc.size else 0})
        total_values += int(acc.size)
        if mismatches:
            raise ExportError(f"integer vs existing float requant mismatch in {name}: {mismatches}/{acc.size}")
    return {"accumulator_values": total_values, "layers": rows, "mismatches": 0}


def _write_lines(path: Path, lines: Iterable[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for line in lines:
            stream.write(line.rstrip("\r\n") + "\n")


def _word_hex(value: int, bits: int) -> str:
    return f"{int(value) & ((1 << bits) - 1):0{bits // 4}x}"


def _build_roms(ops: list[Operation], arrays: dict[str, np.ndarray], manifest: dict[str, Any], scales: dict[str, float]) -> dict[str, list[str]]:
    weights: list[str] = []
    biases: list[str] = []
    multipliers: list[str] = []
    shifts: list[str] = []
    residual_lut: list[str] = []
    by_name = {str(row["name"]): row for row in manifest["layers"]}
    for op in ops:
        if op.kind == OP_CONV:
            op.weight_base = len(weights)
            w = arrays[op.name + ".weight"]
            weights.extend(pack_conv_weights(w, op.kernel, bool(op.depthwise)))
            if op.weight_base + len(weights) <= op.weight_base:
                raise AssertionError("weight bank did not grow")
            op.quant_base = len(biases)
            qgroups = (op.cout + 15) // 16
            for group in range(qgroups):
                start = group * 16
                bias_values = [int(v) for v in arrays[op.name + ".bias"][start : start + 16]]
                mul_values = [int(v) for v in arrays[op.name + ".multiplier"][start : start + 16]]
                shift_values = [int(v) for v in arrays[op.name + ".shift"][start : start + 16]]
                bias_values.extend([0] * (16 - len(bias_values)))
                mul_values.extend([0] * (16 - len(mul_values)))
                shift_values.extend([0] * (16 - len(shift_values)))
                biases.append(pack_signed32_word(bias_values))
                multipliers.append(pack_signed32_word(mul_values))
                shifts.append(pack_signed32_word(shift_values))
            expected_words = len(pack_conv_weights(w, op.kernel, bool(op.depthwise)))
            if op.weight_base + expected_words > len(weights):
                raise AssertionError("invalid conv weight bank range")
        elif op.kind == OP_ADD:
            op.lut_a_base = len(residual_lut)
            identity, project = build_residual_lut(op.in_scale, by_name[op.name.removesuffix(".add") + ".project"]["out_scale"], op.out_scale)
            residual_lut.extend(_word_hex(v, 32) for v in identity)
            op.lut_b_base = len(residual_lut)
            residual_lut.extend(_word_hex(v, 32) for v in project)
        elif op.kind == OP_FC:
            op.weight_base = len(weights)
            weights.extend(pack_fc_weights(arrays["fc.weight"]))
            op.quant_base = len(biases)
            bias_values = [int(v) for v in arrays["fc.bias"]] + [0] * 6
            biases.append(pack_signed32_word(bias_values))
            multipliers.append(pack_signed32_word([0] * 16))
            shifts.append(pack_signed32_word([0] * 16))
    return {"weights.mem": weights, "bias.mem": biases, "multiplier.mem": multipliers,
            "shift.mem": shifts, "residual_lut.mem": residual_lut}


def _validate_rom_inverse(roms: dict[str, list[str]]) -> dict[str, Any]:
    weight_words = roms["weights.mem"]
    if any(len(word) != PARAM_WORD_BITS // 4 for word in weight_words):
        raise ExportError("weight memory has a non-512-bit word")
    for word in weight_words:
        decode_lanes(word, 8, 64)
    for filename in ("bias.mem", "multiplier.mem", "shift.mem"):
        if any(len(word) != PARAM_WORD_BITS // 4 for word in roms[filename]):
            raise ExportError(f"{filename} has a non-512-bit word")
        for word in roms[filename]:
            decode_lanes(word, 32, 16, signed=True)
    if any(len(word) != 8 for word in roms["residual_lut.mem"]):
        raise ExportError("residual LUT must contain 32-bit words")
    for word in roms["residual_lut.mem"]:
        decode_lanes(word, 32, 1, signed=True)
    return {"weight_words": len(weight_words), "quant_words_per_bank": len(roms["bias.mem"]),
            "residual_lut_words": len(roms["residual_lut.mem"])}


def _serialize_operation(op: Operation) -> dict[str, Any]:
    return {
        "index": op.index, "name": op.name, "type": {OP_CONV: "CONV", OP_ADD: "ADD", OP_GAP: "GAP", OP_FC: "FC"}[op.kind],
        "input_slot": op.input_slot, "output_slot": op.output_slot, "identity_slot": op.identity_slot,
        "Hin": op.hin, "Win": op.win, "Cin": op.cin, "Cout": op.cout,
        "Hout": op.hout, "Wout": op.wout, "kernel": op.kernel, "stride": op.stride,
        "depthwise": op.depthwise, "relu": op.relu, "weight_base": op.weight_base,
        "quant_base": op.quant_base, "add_a_base": op.lut_a_base, "add_b_base": op.lut_b_base,
        "input_word_count": op.input_word_count, "output_word_count": op.output_word_count,
        "semantic_macs": op.semantic_macs, "source": op.source,
        "in_scale": op.in_scale, "out_scale": op.out_scale, "activation": op.activation,
        "tap_offset_words": op.tap_offset,
    }


def _tap_lines(taps: dict[str, np.ndarray], ops: list[Operation]) -> tuple[list[str], list[int], dict[str, Any]]:
    out: list[str] = []
    offsets: list[int] = []
    detail: dict[str, Any] = {}
    for op in ops:
        op.tap_offset = len(out)
        offsets.append(op.tap_offset)
        if op.kind == OP_FC:
            detail[op.name] = {"tap_offset_words": op.tap_offset, "word_count": 0, "kind": "raw_int32_accumulators"}
            continue
        tensor = taps[op.name]
        packed = pack_activation_tensor(tensor)
        expected = op.output_word_count
        if len(packed) != expected:
            raise ExportError(f"{op.name}: packed tap count {len(packed)} != descriptor count {expected}")
        inverse = unpack_activation_words(packed, op.hout, op.wout, op.cout)
        if not np.array_equal(inverse, tensor):
            raise ExportError(f"{op.name}: activation packing did not round-trip")
        out.extend(packed)
        detail[op.name] = {"tap_offset_words": op.tap_offset, "word_count": len(packed), "kind": "activation128"}
    return out, offsets, detail


def _verify_descriptor_graph(ops: list[Operation], roms: dict[str, list[str]], arrays: dict[str, np.ndarray]) -> dict[str, Any]:
    conv_macs = sum(op.semantic_macs for op in ops if op.kind == OP_CONV)
    total_macs = conv_macs + sum(op.semantic_macs for op in ops if op.kind == OP_FC)
    category = {"dense3x3": 0, "pw1x1": 0, "dw3x3": 0}
    for op in ops:
        if op.kind != OP_CONV:
            continue
        if op.name == "stem":
            category["dense3x3"] += op.semantic_macs
        elif op.depthwise:
            category["dw3x3"] += op.semantic_macs
        else:
            category["pw1x1"] += op.semantic_macs
    expected = {"semantic_macs": 11_645_440, "dense3x3": 442_368, "pw1x1": 10_223_616, "dw3x3": 976_896}
    got = {"semantic_macs": total_macs, **category}
    if got != expected:
        raise ExportError(f"D4 operation ledger mismatch: got={got}, expected={expected}")
    for op in ops:
        if op.kind == OP_CONV and op.input_slot == op.output_slot:
            raise ExportError(f"CONV op aliases input/output activation slot: {op.name}")
        if op.kind == OP_ADD and op.input_slot != op.output_slot:
            raise ExportError(f"ADD must write project buffer in place: {op.name}")
        if op.output_word_count > ACTIVATION_SLOT_WORDS and op.kind != OP_FC:
            raise ExportError(f"activation slot overflow at {op.name}")
    counts = _validate_rom_inverse(roms)
    mapping = validate_parameter_rom_mapping(ops, roms, arrays)
    return {**got, **counts, **mapping, "op_count": len(ops), "add_count": sum(op.kind == OP_ADD for op in ops),
            "activation_slot_words": ACTIVATION_SLOT_WORDS}


def _pack_one_input(image: np.ndarray) -> list[str]:
    codes = np.clip(np.asarray(image, dtype=np.int16) - 128, -128, 127).astype(np.int8)
    return pack_activation_tensor(codes)


def select_first_per_class(labels: np.ndarray) -> list[int]:
    selected = []
    for cls in range(10):
        indices = np.flatnonzero(np.asarray(labels) == cls)
        if indices.size == 0:
            raise ExportError(f"official CIFAR-10 test set has no class {cls}")
        selected.append(int(indices[0]))
    return sorted(selected)


def _float32_scales(manifest: dict[str, Any]) -> np.ndarray:
    fc = next(row for row in manifest["layers"] if row.get("name") == "fc")
    scales = np.asarray(fc.get("weight_scale"), dtype=np.float32)
    if scales.shape != (10,) or not np.all(np.isfinite(scales)) or np.any(scales <= 0):
        raise ExportError("manifest FC float32 weight scales invalid")
    return scales


def _write_sample(
    outdir: Path, image: np.ndarray, label: int | None, sample_index: int | None,
    taps: dict[str, np.ndarray], accumulators: dict[str, np.ndarray],
    gap: np.ndarray, fc_acc: np.ndarray, stats: dict[str, Any],
    ops: list[Operation], roms: dict[str, list[str]], descriptor_words: list[str],
    tap_lines: list[str], tap_offsets: list[int], tap_detail: dict[str, Any],
    fc_scales: np.ndarray, head_scale: float, source_hashes: dict[str, str],
    input_file_hash: str | None, requant_audit: dict[str, Any], ledger: dict[str, Any],
    input_provenance: dict[str, Any] | None = None,
) -> dict[str, Any]:
    outdir.mkdir(parents=True, exist_ok=True)
    _write_lines(outdir / "input.mem", _pack_one_input(image))
    for name, words in roms.items():
        _write_lines(outdir / name, words)
    _write_lines(outdir / "descriptors.mem", descriptor_words)
    _write_lines(outdir / "expected_taps.mem", tap_lines)
    _write_lines(outdir / "tap_offsets.mem", (_word_hex(v, 32) for v in tap_offsets))
    _write_lines(outdir / "fc_acc.mem", (_word_hex(v, 32) for v in fc_acc))

    dequant_scales = float(head_scale) * fc_scales.astype(np.float64)
    logits = fc_acc.astype(np.float64) * dequant_scales
    # Preserve the manifest float32 per-output scales while applying the Python
    # float head scale and reconstructing logits in float64.
    # A positive common head scale preserves the exact integer evaluator argmax.
    if int(np.argmax(logits)) != int(np.argmax(fc_acc.astype(np.float64) * fc_scales.astype(np.float64))):
        raise ExportError("FC reconstructed logits changed exact integer argmax")
    label_name = CLASS_NAMES[int(label)] if label is not None else None
    fc_record = {
        "sample_index": sample_index, "label": int(label) if label is not None else None,
        "raw_int32_accumulators": [int(v) for v in fc_acc],
        "head_scale": float(head_scale), "weight_scale_float32": [float(v) for v in fc_scales],
        "dequant_scales_float64": [float(v) for v in dequant_scales],
        "reconstructed_logits": [float(v) for v in logits],
        "argmax": int(np.argmax(logits)), "label_name": label_name,
    }
    if input_provenance is not None:
        fc_record["input_provenance"] = input_provenance
    (outdir / "expected_fc.json").write_text(json.dumps(fc_record, indent=2) + "\n", encoding="utf-8")
    operation_rows = [_serialize_operation(op) for op in ops]
    descriptor_doc = {
        "schema": "D4-fullnet-descriptor-v1", "descriptor_words": DESCRIPTOR_WORDS,
        "word_fields": ["type", "input_slot", "output_slot", "identity_slot", "Hin", "Win", "Cin", "Cout", "Hout", "Wout", "kernel", "stride", "depthwise", "relu", "weight_base", "quant_base", "add_a_base", "add_b_base", "log2_Win", "log2_ceil_Cin_div16", "output_word_count", "input_word_count", "reserved"],
        "operations": operation_rows,
        "residual_lut": {
            "file": "residual_lut.mem",
            "word_format": "signed_int32_twos_complement",
            "entry_order": "signed_int8_code_ascending_minus128_to_127",
            "address_from_raw_activation_byte": "raw_byte_xor_0x80",
            "table_value": "round_away_from_zero(input_code * input_scale / output_scale)",
        },
    }
    (outdir / "descriptor.json").write_text(json.dumps(descriptor_doc, indent=2) + "\n", encoding="utf-8")
    summary = {
        "schema": "D4-fullnet-vectors-v1", "variant_id": "D4", "sample_index": sample_index,
        "label": int(label) if label is not None else None, "label_name": label_name,
        "image_shape": [32, 32, 3],
        "input_words": len(_pack_one_input(image)), "expected_tap_words": len(tap_lines),
        "tap_op_count": len(tap_offsets), "fc_acc_words": 10,
        "ops": len(ops), "semantic_macs": ledger["semantic_macs"],
        "categories": {k: ledger[k] for k in ("dense3x3", "pw1x1", "dw3x3")},
        "weight_words": ledger["weight_words"], "quant_words_per_bank": ledger["quant_words_per_bank"],
        "residual_lut_words": ledger["residual_lut_words"], "requant_audit": requant_audit,
        "max_abs_accumulator": int(stats["max_abs_accumulator"]),
        "accumulator_checks": int(stats["accumulator_checks"]),
        "source_sha256": source_hashes, "cifar_test_batch_sha256": input_file_hash,
        "residual_lut_addressing": "signed_code_plus_128 (raw_activation_byte XOR 0x80)",
        "tap_offsets": tap_detail,
        "artifacts": ["input.mem", *roms.keys(), "descriptors.mem", "descriptor.json", "expected_taps.mem", "tap_offsets.mem", "fc_acc.mem", "expected_fc.json"],
        "evidence_boundary": (
            "synthetic functional vector only; no official CIFAR-10 accuracy label or accuracy claim"
            if input_provenance is not None
            else "one official CIFAR-10 test sample; no new official10k accuracy claim"
        ),
    }
    if input_provenance is not None:
        summary["input_provenance"] = input_provenance
    (outdir / "run_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    owned_artifacts = summary["artifacts"] + ["run_summary.json"]
    hashes = {name: sha256_file(outdir / name) for name in owned_artifacts}
    (outdir / "artifact_sha256.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    return summary


def _synthetic_edge_images() -> dict[str, tuple[np.ndarray, dict[str, Any]]]:
    shape = (32, 32, 3)
    yy, xx, cc = np.indices(shape, dtype=np.int16)
    checkerboard = np.where(((xx + yy + cc) & 1) == 0, 0, 255).astype(np.uint8)
    definitions = {
        "centered_zero": (
            np.full(shape, 128, dtype=np.uint8),
            "constant uint8 value 128 in every HWC pixel; signed input code is 0",
        ),
        "all_zero": (
            np.zeros(shape, dtype=np.uint8),
            "constant uint8 value 0 in every HWC pixel; signed input code is -128",
        ),
        "all_255": (
            np.full(shape, 255, dtype=np.uint8),
            "constant uint8 value 255 in every HWC pixel; signed input code is 127",
        ),
        "checkerboard": (
            checkerboard,
            "uint8 value 0 when (x + y + channel) is even, else 255; signed codes alternate -128 and 127 across x, y, and channel",
        ),
    }
    return {
        name: (
            image,
            {
                "kind": "synthetic_uint8_image",
                "name": name,
                "construction": construction,
                "dtype": "uint8",
                "shape": list(shape),
                "official_dataset": None,
                "official_dataset_index": None,
                "accuracy_label": None,
            },
        )
        for name, (image, construction) in definitions.items()
    }


def export_synthetic_edge_vectors(
    out_root: Path = DEFAULT_OUT, report_dir: Path = DEFAULT_REPORT,
    reference_sample_dir: Path = DEFAULT_OUT / "sample_0",
) -> dict[str, Any]:
    """Export deterministic edge-pattern inputs without reading or rewriting real samples."""
    source_hashes = verify_frozen_sources()
    exporter_key = str(Path(__file__).resolve().relative_to(ROOT)).replace("\\", "/")
    source_hashes[exporter_key] = sha256_file(Path(__file__).resolve())
    if sha256_file(DEPLOY_NPZ) != source_hashes.get(str(DEPLOY_NPZ.relative_to(ROOT)).replace("\\", "/")):
        raise ExportError("deployment NPZ hash is not the hash recorded by frozen software manifest")
    if sha256_file(DEPLOY_MANIFEST) != source_hashes.get(str(DEPLOY_MANIFEST.relative_to(ROOT)).replace("\\", "/")):
        raise ExportError("deployment manifest hash is not the hash recorded by frozen software manifest")
    arrays, manifest, scales = load_frozen_deployment()
    ops = build_operations(arrays, manifest, scales)
    roms = _build_roms(ops, arrays, manifest, scales)
    ledger = _verify_descriptor_graph(ops, roms, arrays)
    base_ops = [Operation(**vars(op)) for op in ops]
    for op in base_ops:
        op.tap_offset = 0
    descriptor_words = [_word_hex(word, 32) for op in base_ops for word in op.descriptor_words()]
    fc_scales = _float32_scales(manifest)
    head_scale = float(next(row for row in manifest["layers"] if row["name"] == "head")["out_scale"])

    shared_artifacts = [*roms.keys(), "descriptors.mem", "descriptor.json", "tap_offsets.mem"]
    if not reference_sample_dir.is_dir():
        raise ExportError(f"sample_0 reference directory missing: {reference_sample_dir}")
    missing = [name for name in shared_artifacts if not (reference_sample_dir / name).is_file()]
    if missing:
        raise ExportError(f"sample_0 is missing shared artifacts: {missing}")
    reference_hashes = {name: sha256_file(reference_sample_dir / name) for name in shared_artifacts}

    report_cases: dict[str, Any] = {}
    all_requant_rows = []
    tap_counts: dict[str, int] = {}
    for name, (image, provenance) in _synthetic_edge_images().items():
        if image.dtype != np.uint8 or image.shape != (32, 32, 3):
            raise ExportError(f"synthetic {name} image must be uint8 HWC 32x32x3")
        taps, accumulators, gap, fc_acc, stats = run_reference_taps(arrays, manifest, scales, image)
        audit = validate_requant_observed(accumulators, arrays)
        tap_lines, tap_offsets, tap_detail = _tap_lines(taps, base_ops)
        sample_dir = out_root / f"sample_synthetic_{name}"
        if sample_dir.resolve() == reference_sample_dir.resolve():
            raise ExportError("synthetic output directory aliases the real sample_0 reference")
        summary = _write_sample(
            sample_dir, image, None, None, taps, accumulators, gap, fc_acc, stats,
            base_ops, roms, descriptor_words, tap_lines, tap_offsets, tap_detail,
            fc_scales, head_scale, source_hashes, None, audit, ledger,
            input_provenance=provenance,
        )
        actual_shared_hashes = {name: sha256_file(sample_dir / name) for name in shared_artifacts}
        if actual_shared_hashes != reference_hashes:
            raise ExportError(f"synthetic {name} shared ROM/descriptor hashes differ from sample_0")
        report_cases[name] = {
            "artifact_dir": str(sample_dir),
            "input_provenance": provenance,
            "expected_tap_words": len(tap_lines),
            "requant_audit": audit,
            "max_abs_accumulator": int(stats["max_abs_accumulator"]),
            "accumulator_checks": int(stats["accumulator_checks"]),
            "shared_artifact_sha256": actual_shared_hashes,
        }
        all_requant_rows.append({"synthetic_name": name, **audit})
        tap_counts[name] = len(tap_lines)

    report = {
        "schema": "D4-fullnet-synthetic-vectors-v1",
        "synthetic_cases": report_cases,
        "official_dataset_indices": None,
        "accuracy_labels": None,
        "source_sha256": source_hashes,
        "ledger": ledger,
        "expected_tap_words_per_case": tap_counts,
        "requant_audit": all_requant_rows,
        "shared_artifacts_reference": str(reference_sample_dir),
        "shared_artifact_sha256": reference_hashes,
        "evidence_boundary": "synthetic functional vectors only; no official CIFAR-10 accuracy claim",
    }
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / "synthetic_export_summary.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (report_dir / "synthetic_export.log").write_text(
        "PASS frozen D4 source hashes\n"
        f"PASS synthetic cases: {list(report_cases)}\n"
        f"PASS ops={ledger['op_count']} semantic_macs={ledger['semantic_macs']}\n"
        f"PASS shared ROM/descriptor hashes match sample_0 for {len(shared_artifacts)} files\n"
        f"PASS expected_tap_words_per_case={next(iter(tap_counts.values()))}\n"
        f"PASS integer requant audits have zero mismatches across {sum(row['accumulator_values'] for row in all_requant_rows)} observed values\n"
        "PASS synthetic provenance has no official dataset index or accuracy label\n",
        encoding="utf-8",
    )
    return report


def export_vectors(
    data_root: Path = DEFAULT_DATA, out_root: Path = DEFAULT_OUT,
    report_dir: Path = DEFAULT_REPORT, sample_indices: list[int] | None = None,
    first_per_class: bool = False,
) -> dict[str, Any]:
    source_hashes = verify_frozen_sources()
    source_hashes[str(Path(__file__).resolve().relative_to(ROOT)).replace("\\", "/")] = sha256_file(Path(__file__).resolve())
    if sha256_file(DEPLOY_NPZ) != source_hashes.get(str(DEPLOY_NPZ.relative_to(ROOT)).replace("\\", "/")):
        raise ExportError("deployment NPZ hash is not the hash recorded by frozen software manifest")
    if sha256_file(DEPLOY_MANIFEST) != source_hashes.get(str(DEPLOY_MANIFEST.relative_to(ROOT)).replace("\\", "/")):
        raise ExportError("deployment manifest hash is not the hash recorded by frozen software manifest")
    arrays, manifest, scales = load_frozen_deployment()
    images, labels = load_cifar10(data_root, "test")
    if labels.shape != (10_000,) or images.shape != (10_000, 32, 32, 3):
        raise ExportError(f"expected official CIFAR-10 test10k, got {images.shape} / {labels.shape}")
    cifar_dir = find_cifar_dir(data_root)
    cifar_path = cifar_dir / "test_batch"
    input_file_hash = sha256_file(cifar_path)
    chosen = select_first_per_class(labels) if first_per_class else (sample_indices if sample_indices is not None else [0])
    chosen = list(dict.fromkeys(int(index) for index in chosen))
    if not chosen or any(index < 0 or index >= len(labels) for index in chosen):
        raise ExportError(f"sample indices outside official test split: {chosen}")
    ops = build_operations(arrays, manifest, scales)
    roms = _build_roms(ops, arrays, manifest, scales)
    ledger = _verify_descriptor_graph(ops, roms, arrays)
    # Parent's common compile directory is sample_0. The first-per-class set
    # includes original index 0, but keep a dedicated common image directory if
    # future selections omit it.
    if 0 not in chosen:
        chosen_with_base = [0, *chosen]
    else:
        chosen_with_base = chosen
    base_ops = [Operation(**vars(op)) for op in ops]
    for op in base_ops:
        op.tap_offset = 0
    descriptor_words = [_word_hex(word, 32) for op in base_ops for word in op.descriptor_words()]
    taps_by_index: dict[int, dict[str, np.ndarray]] = {}
    refs_by_index: dict[int, tuple[dict[str, np.ndarray], np.ndarray, np.ndarray, dict[str, Any], dict[str, Any]]] = {}
    all_requant_rows = []
    for index in chosen_with_base:
        taps, accums, gap, fc_acc, stats = run_reference_taps(arrays, manifest, scales, images[index])
        audit = validate_requant_observed(accums, arrays)
        taps_by_index[index] = taps
        refs_by_index[index] = (accums, gap, fc_acc, stats, audit)
        all_requant_rows.append({"sample_index": index, **audit})
    all_taps, offsets, tap_detail = _tap_lines(taps_by_index[chosen_with_base[0]], base_ops)
    tap_counts_by_sample: dict[str, int] = {}
    summaries: dict[str, Any] = {}
    fc_scales = _float32_scales(manifest)
    head_scale = float(next(row for row in manifest["layers"] if row["name"] == "head")["out_scale"])
    report_dir.mkdir(parents=True, exist_ok=True)
    for index in chosen_with_base:
        sample_dir = out_root / f"sample_{index}"
        accums, gap, fc_acc, stats, audit = refs_by_index[index]
        tap_lines, sample_offsets, sample_detail = _tap_lines(taps_by_index[index], base_ops)
        if sample_offsets != offsets:
            raise ExportError("tap offsets depend on sample data")
        summary = _write_sample(
            sample_dir, images[index], int(labels[index]), index,
            taps_by_index[index], accums, gap, fc_acc, stats, base_ops,
            roms, descriptor_words, tap_lines, sample_offsets, sample_detail,
            fc_scales, head_scale, source_hashes, input_file_hash, audit, ledger,
        )
        summaries[str(index)] = summary
        tap_counts_by_sample[str(index)] = len(tap_lines)
    report = {
        "schema": "D4-fullnet-export-report-v1", "selected_indices": chosen,
        "class_by_index": {str(i): CLASS_NAMES[int(labels[i])] for i in chosen},
        "data_root": str(data_root), "cifar_test_batch": str(cifar_path),
        "source_sha256": source_hashes, "cifar_test_batch_sha256": input_file_hash,
        "residual_lut_addressing": "signed_code_plus_128 (raw_activation_byte XOR 0x80)",
        "ledger": ledger, "expected_tap_words_per_sample": tap_counts_by_sample,
        "requant_audit": all_requant_rows,
        "artifact_dirs": {str(i): str(out_root / f"sample_{i}") for i in chosen_with_base},
        "evidence_boundary": "first official image per class only; no new official10k accuracy claim",
    }
    report_path = report_dir / "export_summary.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (report_dir / "export.log").write_text(
        "PASS frozen D4 source hashes\n"
        f"PASS selected official sample indices: {chosen}\n"
        f"PASS ops={ledger['op_count']} semantic_macs={ledger['semantic_macs']}\n"
        f"PASS weight_words={ledger['weight_words']} quant_words_per_bank={ledger['quant_words_per_bank']} residual_lut_words={ledger['residual_lut_words']}\n"
        f"PASS expected_tap_words_per_sample={next(iter(tap_counts_by_sample.values()))}\n"
        "PASS integer requant matches existing float reference on observed accumulators\n",
        encoding="utf-8",
    )
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA, help="root containing CIFAR-10 python batches")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="root directory for sample_<index> vector directories")
    parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--sample-index", type=int, action="append", help="official test index; repeat to select several")
    parser.add_argument("--first-per-class", action="store_true", help="select the first official test index of each class")
    parser.add_argument(
        "--synthetic-edges", action="store_true",
        help="export centered-zero, all-zero, all-255, and checkerboard synthetic inputs only",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.synthetic_edges:
        if args.sample_index is not None or args.first_per_class:
            raise SystemExit("--synthetic-edges cannot be combined with official sample selection")
        report = export_synthetic_edge_vectors(args.out, args.report_dir)
        print(json.dumps({
            "synthetic_cases": list(report["synthetic_cases"]),
            "ledger": report["ledger"],
            "expected_tap_words_per_case": report["expected_tap_words_per_case"],
        }, indent=2))
    else:
        report = export_vectors(args.data, args.out, args.report_dir, args.sample_index, args.first_per_class)
        print(json.dumps({"selected_indices": report["selected_indices"], "class_by_index": report["class_by_index"], "ledger": report["ledger"], "expected_tap_words_per_sample": report["expected_tap_words_per_sample"]}, indent=2))


if __name__ == "__main__":
    main()
