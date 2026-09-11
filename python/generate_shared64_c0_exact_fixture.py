#!/usr/bin/env python3
"""Generate the independent six-layer C0 fixture for the shared64 adapter.

The expected values in this fixture are produced only from the checked-in C0
firmware headers.  RTL output is never read by this script.  Each layer gets
an NHWC input stream, complete depthwise and pointwise reference streams, and
the scalar configuration transactions consumed by
``ds_group_published_shared64_runner_adapter``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
WEIGHTS_H = ROOT / "sw/model/model_weights.h"
QUANT_H = ROOT / "sw/model/model_quant.h"
DESC_H = ROOT / "sw/model/model_desc.h"

LAYERS = (
    # name, H, W, Cin, Cout, stride, header suffix
    (1, 32, 32, 16, 32, 1, "ds1"),
    (2, 32, 32, 32, 64, 2, "ds2"),
    (3, 16, 16, 64, 64, 1, "ds3"),
    (4, 16, 16, 64, 128, 2, "ds4"),
    (5, 8, 8, 128, 128, 1, "ds5"),
    (6, 8, 8, 128, 256, 2, "ds6"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_c_array(source: str, symbol: str) -> list[int]:
    match = re.search(rf"{re.escape(symbol)}\s*\[[^]]+\]\s*=\s*\{{(.*?)\}};", source, re.S)
    if not match:
        raise ValueError(f"missing C array {symbol}")
    values = [int(token) for token in re.findall(r"[-+]?\d+", match.group(1))]
    if not values:
        raise ValueError(f"empty C array {symbol}")
    return values


def parse_c_scalar(source: str, symbol: str) -> int:
    match = re.search(rf"{re.escape(symbol)}\s*=\s*([-+]?\d+)", source)
    if not match:
        raise ValueError(f"missing C scalar {symbol}")
    return int(match.group(1))


def reshape(values: list[int], shape: tuple[int, ...]) -> Any:
    expected = 1
    for dim in shape:
        expected *= dim
    if len(values) != expected:
        raise ValueError(f"shape {shape} needs {expected} values, got {len(values)}")

    def build(offset: int, dims: tuple[int, ...]) -> tuple[Any, int]:
        if not dims:
            return values[offset], offset + 1
        result = []
        for _ in range(dims[0]):
            item, offset = build(offset, dims[1:])
            result.append(item)
        return result, offset

    result, final = build(0, shape)
    if final != len(values):
        raise AssertionError("reshape did not consume the source array")
    return result


def flatten(values: Any) -> list[int]:
    if isinstance(values, list):
        out: list[int] = []
        for item in values:
            out.extend(flatten(item))
        return out
    return [int(values)]


def round_away_q31(product: int) -> int:
    """Round a signed Q31 product to nearest, ties away from zero."""
    if product >= 0:
        return (product + (1 << 30)) >> 31
    return -(((-product) + (1 << 30)) >> 31)


def requant(
    acc: int,
    bias: int,
    multiplier: int,
    shift: int,
    zero_point: int,
    activation_min: int = 0,
    activation_max: int = 127,
) -> int:
    rounded = round_away_q31((int(acc) + int(bias)) * int(multiplier))
    shifted = rounded >> int(shift)
    value = shifted + int(zero_point)
    value = max(-128, min(127, value))
    return max(int(activation_min), min(int(activation_max), value))


def depthwise_reference(
    feature: list[list[list[int]]],
    weights: list[list[list[int]]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    input_zero_point: int,
    output_zero_point: int,
    stride: int,
) -> list[list[list[int]]]:
    height, width, channels = len(feature), len(feature[0]), len(feature[0][0])
    out_height = (height + stride - 1) // stride
    out_width = (width + stride - 1) // stride
    output: list[list[list[int]]] = []
    for oy in range(out_height):
        row: list[list[int]] = []
        for ox in range(out_width):
            pixel: list[int] = []
            for channel in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy = oy * stride + kh - 1
                        ix = ox * stride + kw - 1
                        if iy < 0 or ix < 0 or iy >= height or ix >= width:
                            act = input_zero_point
                        else:
                            act = feature[iy][ix][channel]
                        acc += int(act) * int(weights[channel][kh][kw])
                pixel.append(
                    requant(
                        acc,
                        bias[channel],
                        multiplier[channel],
                        shift[channel],
                        output_zero_point,
                    )
                )
            row.append(pixel)
        output.append(row)
    return output


def pointwise_reference(
    feature: list[list[list[int]]],
    weights: list[list[int]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    output_zero_point: int,
) -> list[list[list[int]]]:
    height, width, channels = len(feature), len(feature[0]), len(feature[0][0])
    output: list[list[list[int]]] = []
    for y in range(height):
        row: list[list[int]] = []
        for x in range(width):
            pixel: list[int] = []
            for channel in range(len(weights)):
                acc = sum(int(feature[y][x][ci]) * int(weights[channel][ci]) for ci in range(channels))
                pixel.append(
                    requant(
                        acc,
                        bias[channel],
                        multiplier[channel],
                        shift[channel],
                        output_zero_point,
                    )
                )
            row.append(pixel)
        output.append(row)
    return output


def write_i8(path: Path, values: Iterable[int]) -> int:
    values_list = [int(value) for value in values]
    path.write_text("".join(f"{value & 0xFF:02x}\n" for value in values_list), encoding="ascii")
    return len(values_list)


def write_config(path: Path, cin: int, cout: int, dw_w: list[list[list[int]]], dw_bias: list[int], dw_mul: list[int], dw_shift: list[int], pw_w: list[list[int]], pw_bias: list[int], pw_mul: list[int], pw_shift: list[int]) -> int:
    # Target IDs are the scalar runner ABI: DW weight/bias/mul/shift then PW
    # weight/bias/mul/shift.  PW weight indices intentionally use the fixed
    # MAX_CIN=128 stride used by the adapter, not a layer-local stride.
    rows: list[str] = []

    def add(target: int, index: int, value: int) -> None:
        rows.append(f"{target} {index} {int(value) & 0xFFFFFFFF:08x}\n")

    for channel in range(cin):
        for tap in range(9):
            add(1, channel * 9 + tap, dw_w[channel][tap // 3][tap % 3])
    for channel in range(cin):
        add(2, channel, dw_bias[channel])
        add(3, channel, dw_mul[channel])
        add(4, channel, dw_shift[channel])
    for channel in range(cout):
        for input_channel in range(cin):
            add(5, channel * 128 + input_channel, pw_w[channel][input_channel])
    for channel in range(cout):
        add(6, channel, pw_bias[channel])
        add(7, channel, pw_mul[channel])
        add(8, channel, pw_shift[channel])
    path.write_text("".join(rows), encoding="ascii")
    return len(rows)


def stats(values: list[int], shape: tuple[int, ...], layout: str, source_symbol: str | None = None) -> dict[str, Any]:
    if not values:
        raise ValueError("fixture arrays may not be empty")
    item: dict[str, Any] = {
        "shape": list(shape),
        "layout": layout,
        "count": len(values),
        "nonzero_count": sum(value != 0 for value in values),
        "min": min(values),
        "max": max(values),
    }
    if source_symbol is not None:
        item["source_symbol"] = source_symbol
    return item


def arithmetic_spot_checks(layer_data: list[dict[str, Any]]) -> list[dict[str, int]]:
    """Recompute fixed, non-trivial DW/PW terms for every layer."""
    checks: list[dict[str, int]] = []
    for data in layer_data:
        layer = data["layer"]
        feature = data["input"]
        dw_w = data["dw_w"]
        dw_out = data["dw_out"]
        pw_w = data["pw_w"]
        pw_out = data["pw_out"]
        # First interior pixel/channel with a signed product mix and a halo
        # pixel/channel.  The search order is deterministic and independent
        # of any stream ordering in the RTL.
        dw_choice: tuple[int, int] | None = None
        for y in range(len(dw_out)):
            for x in range(len(dw_out[0])):
                for channel in range(len(dw_out[0][0])):
                    terms: list[int] = []
                    for kh in range(3):
                        for kw in range(3):
                            iy, ix = y * data["stride"] + kh - 1, x * data["stride"] + kw - 1
                            act = data["input_zero_point"] if iy < 0 or ix < 0 or iy >= len(feature) or ix >= len(feature[0]) else feature[iy][ix][channel]
                            terms.append(int(act) * int(dw_w[channel][kh][kw]))
                    if min(terms) < 0 < max(terms) and any(abs(term) for term in terms):
                        dw_choice = (y, x, channel)
                        break
                if dw_choice:
                    break
            if dw_choice:
                break
        if dw_choice is None:
            raise AssertionError(f"no signed DW spot check for DS{layer}")
        y, x, channel = dw_choice
        acc = sum(
            (data["input_zero_point"] if y * data["stride"] + kh - 1 < 0 or x * data["stride"] + kw - 1 < 0 or y * data["stride"] + kh - 1 >= len(feature) or x * data["stride"] + kw - 1 >= len(feature[0]) else feature[y * data["stride"] + kh - 1][x * data["stride"] + kw - 1][channel]) * dw_w[channel][kh][kw]
            for kh in range(3) for kw in range(3)
        )
        value = requant(acc, data["dw_bias"][channel], data["dw_mul"][channel], data["dw_shift"][channel], data["dw_output_zero_point"])
        if value != dw_out[y][x][channel]:
            raise AssertionError(f"DW spot mismatch DS{layer}")
        checks.append({"layer": layer, "kind": 0, "y": y, "x": x, "channel": channel, "acc": acc, "output": value})

        pw_choice: tuple[int, int, int] | None = None
        for y in range(len(pw_out)):
            for x in range(len(pw_out[0])):
                for channel in range(len(pw_out[0][0])):
                    terms = [int(dw_out[y][x][ci]) * int(pw_w[channel][ci]) for ci in range(len(pw_w[channel]))]
                    if min(terms) < 0 < max(terms) and any(abs(term) for term in terms):
                        pw_choice = (y, x, channel)
                        break
                if pw_choice:
                    break
            if pw_choice:
                break
        if pw_choice is None:
            raise AssertionError(f"no signed PW spot check for DS{layer}")
        y, x, channel = pw_choice
        acc = sum(int(dw_out[y][x][ci]) * int(pw_w[channel][ci]) for ci in range(len(pw_w[channel])))
        value = requant(acc, data["pw_bias"][channel], data["pw_mul"][channel], data["pw_shift"][channel], data["pw_output_zero_point"])
        if value != pw_out[y][x][channel]:
            raise AssertionError(f"PW spot mismatch DS{layer}")
        checks.append({"layer": layer, "kind": 1, "y": y, "x": x, "channel": channel, "acc": acc, "output": value})
    return checks


def build_fixture(out_dir: Path) -> dict[str, Any]:
    weights_source = WEIGHTS_H.read_text(encoding="utf-8")
    quant_source = QUANT_H.read_text(encoding="utf-8")
    desc_source = DESC_H.read_text(encoding="utf-8")

    model_input = reshape(parse_c_array(weights_source, "g_model_input_image_i8_packed"), (32, 32, 3))
    stem_w = reshape(parse_c_array(weights_source, "g_stem_weight_i8_packed"), (16, 3, 3, 3))

    def q_array(symbol: str) -> list[int]:
        return parse_c_array(quant_source, symbol)

    q: dict[str, int] = {
        "model_input_zero_point": parse_c_scalar(quant_source, "g_model_input_zero_point"),
        "stem_output_zero_point": parse_c_scalar(quant_source, "g_stem_output_zero_point"),
    }
    for _, _, _, _, _, _, suffix in LAYERS:
        q[f"{suffix}_input_zero_point"] = parse_c_scalar(quant_source, f"g_{suffix}_input_zero_point")
        q[f"{suffix}_dw_output_zero_point"] = parse_c_scalar(quant_source, f"g_{suffix}_dw_output_zero_point")
        q[f"{suffix}_pw_output_zero_point"] = parse_c_scalar(quant_source, f"g_{suffix}_pw_output_zero_point")

    # The checked-in C0 graph's stem is only provenance for DS1 input; all six
    # DS transactions below are independently driven through the adapter.
    # Keep the reference formula local so expected data cannot come from RTL.
    stem_bias = q_array("g_stem_bias")
    stem_mul = q_array("g_stem_mul")
    stem_shift = q_array("g_stem_shift_words")
    stem: list[list[list[int]]] = []
    for y in range(32):
        row: list[list[int]] = []
        for x in range(32):
            pixel: list[int] = []
            for co in range(16):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy, ix = y + kh - 1, x + kw - 1
                        for ci in range(3):
                            act = q["model_input_zero_point"] if iy < 0 or ix < 0 or iy >= 32 or ix >= 32 else model_input[iy][ix][ci]
                            acc += int(act) * int(stem_w[co][ci][kh][kw])
                pixel.append(requant(acc, stem_bias[co], stem_mul[co], stem_shift[co], q["stem_output_zero_point"]))
            row.append(pixel)
        stem.append(row)

    layer_data: list[dict[str, Any]] = []
    current = stem
    out_dir.mkdir(parents=True, exist_ok=True)
    write_i8(out_dir / "stem_output_i8.hex", flatten(stem))
    for layer, height, width, cin, cout, stride, suffix in LAYERS:
        dw_w = reshape(parse_c_array(weights_source, f"g_{suffix}_dw_weight_i8_packed"), (cin, 3, 3))
        pw_w = reshape(parse_c_array(weights_source, f"g_{suffix}_pw_weight_i8_packed"), (cout, cin))
        dw_bias, dw_mul, dw_shift = q_array(f"g_{suffix}_dw_bias"), q_array(f"g_{suffix}_dw_mul"), q_array(f"g_{suffix}_dw_shift_words")
        pw_bias, pw_mul, pw_shift = q_array(f"g_{suffix}_pw_bias"), q_array(f"g_{suffix}_pw_mul"), q_array(f"g_{suffix}_pw_shift_words")
        if len(current) != height or len(current[0]) != width or len(current[0][0]) != cin:
            raise AssertionError(f"DS{layer} input chain shape mismatch")
        dw_out = depthwise_reference(current, dw_w, dw_bias, dw_mul, dw_shift, q[f"{suffix}_input_zero_point"], q[f"{suffix}_dw_output_zero_point"], stride)
        pw_out = pointwise_reference(dw_out, pw_w, pw_bias, pw_mul, pw_shift, q[f"{suffix}_pw_output_zero_point"])
        input_flat, dw_flat, pw_flat = flatten(current), flatten(dw_out), flatten(pw_out)
        write_i8(out_dir / f"layer{layer}_input_i8.hex", input_flat)
        write_i8(out_dir / f"layer{layer}_dw_expected_i8.hex", dw_flat)
        write_i8(out_dir / f"layer{layer}_pw_expected_i8.hex", pw_flat)
        write_i8(out_dir / f"layer{layer}_dw_weight_i8.hex", flatten(dw_w))
        write_i8(out_dir / f"layer{layer}_pw_weight_i8.hex", flatten(pw_w))
        cfg_count = write_config(out_dir / f"layer{layer}_cfg.hex", cin, cout, dw_w, dw_bias, dw_mul, dw_shift, pw_w, pw_bias, pw_mul, pw_shift)
        layer_data.append({
            "layer": layer,
            "height": height,
            "width": width,
            "cin": cin,
            "cout": cout,
            "stride": stride,
            "suffix": suffix,
            "input": current,
            "dw_w": dw_w,
            "pw_w": pw_w,
            "dw_bias": dw_bias,
            "dw_mul": dw_mul,
            "dw_shift": dw_shift,
            "pw_bias": pw_bias,
            "pw_mul": pw_mul,
            "pw_shift": pw_shift,
            "dw_out": dw_out,
            "pw_out": pw_out,
            "input_zero_point": q[f"{suffix}_input_zero_point"],
            "dw_output_zero_point": q[f"{suffix}_dw_output_zero_point"],
            "pw_output_zero_point": q[f"{suffix}_pw_output_zero_point"],
            "cfg_count": cfg_count,
        })
        current = pw_out

    spot_checks = arithmetic_spot_checks(layer_data)
    layer_manifest: list[dict[str, Any]] = []
    total_pw_macs = 0
    total_dw_macs = 0
    total_physical_dw_beats = 0
    for data in layer_data:
        layer = data["layer"]
        out_h = (data["height"] + data["stride"] - 1) // data["stride"]
        out_w = (data["width"] + data["stride"] - 1) // data["stride"]
        pixels = out_h * out_w
        dw_mac = pixels * data["cin"] * 9
        pw_mac = pixels * data["cin"] * data["cout"]
        total_pw_macs += pw_mac
        total_dw_macs += dw_mac
        macro_count = ((out_h + 3) // 4) * ((out_w + 7) // 8)
        physical_dw_beats = macro_count * 32 * data["cin"] // 4
        total_physical_dw_beats += physical_dw_beats
        layer_manifest.append({
            "layer": layer,
            "shape": {"input": [data["height"], data["width"], data["cin"]], "output": [out_h, out_w, data["cout"]]},
            "stride": data["stride"],
            "input_zero_point": data["input_zero_point"],
            "dw_output_zero_point": data["dw_output_zero_point"],
            "pw_output_zero_point": data["pw_output_zero_point"],
            "activation": [0, 127],
            "files": {"input": f"layer{layer}_input_i8.hex", "dw_expected": f"layer{layer}_dw_expected_i8.hex", "pw_expected": f"layer{layer}_pw_expected_i8.hex", "dw_weight": f"layer{layer}_dw_weight_i8.hex", "pw_weight": f"layer{layer}_pw_weight_i8.hex", "config": f"layer{layer}_cfg.hex"},
            "config_writes": data["cfg_count"],
            "dw_semantic_mac": pixels * data["cin"] * 9,
            "pw_semantic_mac": pixels * data["cin"] * data["cout"],
            # The required shared64 ledger counts useful PW MACs (the
            # six-layer shared arithmetic island), exactly matching the C0
            # handoff convention.  DW producer MACs are retained separately;
            # they are not hidden or credited as shared64 work.
            "shared64_semantic_mac": pw_mac,
            "shared64_semantic_ops": 2 * pw_mac,
            "dw_producer_semantic_mac": dw_mac,
            "combined_ds_semantic_mac": dw_mac + pw_mac,
            "physical_dw_beats": physical_dw_beats,
            "valid_input_bytes": data["height"] * data["width"] * data["cin"],
            "valid_dw_bytes": pixels * data["cin"],
            "valid_pw_bytes": pixels * data["cout"],
            "stats": {"input": stats(flatten(data["input"]), (data["height"], data["width"], data["cin"]), "NHWC pixel-major signed int8"), "dw_expected": stats(flatten(data["dw_out"]), (out_h, out_w, data["cin"]), "NHWC pixel-major signed int8"), "pw_expected": stats(flatten(data["pw_out"]), (out_h, out_w, data["cout"]), "NHWC pixel-major signed int8")},
        })

    manifest: dict[str, Any] = {
        "schema": "shared64-c0-exact-fixture-v1",
        "status": "REFERENCE_FIXTURE_PASS",
        "source": {"weights_header": {"path": str(WEIGHTS_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(WEIGHTS_H)}, "quant_header": {"path": str(QUANT_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(QUANT_H)}, "descriptor_header": {"path": str(DESC_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(DESC_H)}, "expected_source_boundary": "checked-in C0 headers plus this software reference; no RTL output"},
        "reference": {"layout": "NHWC pixel-major signed INT8", "padding": "input zero-point", "requant": "(acc+bias)*multiplier; Q31 nearest-away-from-zero; arithmetic shift; zero-point; INT8 clamp; activation clamp [0,127]", "stem_provenance": "g_model_input_image_i8_packed -> checked-in stem weights/quant -> DS1 input"},
        "layers": layer_manifest,
        "totals": {"shared64_semantic_mac": total_pw_macs, "shared64_semantic_ops": 2 * total_pw_macs, "dw_producer_semantic_mac": total_dw_macs, "combined_ds_semantic_mac": total_pw_macs + total_dw_macs, "physical_dw_beats": total_physical_dw_beats, "config_writes": sum(item["config_writes"] for item in layer_manifest)},
        "arithmetic_spot_checks": {"status": "PASS", "checks": len(spot_checks), "items": spot_checks},
        "fixture_hashes": {path.name: sha256(path) for path in sorted(out_dir.glob("*.hex"))},
        "rtl_evidence_boundary": "The generated fixture is independent software evidence. RTL exactness, protocol, and cycles are reported only by the dedicated simulation.",
    }
    manifest_path = out_dir / "shared64_c0_exact_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/shared64_c0_exact")
    args = parser.parse_args()
    manifest = build_fixture(args.out)
    print(json.dumps({"status": manifest["status"], "out": str(args.out), "layers": len(manifest["layers"]), "shared64_semantic_mac": manifest["totals"]["shared64_semantic_mac"], "shared64_semantic_ops": manifest["totals"]["shared64_semantic_ops"], "config_writes": manifest["totals"]["config_writes"], "spot_checks": manifest["arithmetic_spot_checks"]["checks"]}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
