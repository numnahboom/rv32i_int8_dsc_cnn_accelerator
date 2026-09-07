#!/usr/bin/env python3
"""Generate the M1.1-A non-zero DS1/DS2 functional fixture.

The fixture is deliberately sourced from the checked-in firmware headers,
not from RTL output and not from the C0 ``.npz`` smoke package.  It carries
both pixel-major reference tensors (for the DS1 -> DS2 hand-off) and the
context/tile ordered sink stream consumed by ``tb_m11a_runtime_dw_pw_core``.
The reference implementation below is kept local to this generator so a
future change to the C0 stream helper cannot silently change this gate.
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


def stats(values: Iterable[int], shape: tuple[int, ...] | list[int], layout: str, source_symbol: str | None = None) -> dict[str, Any]:
    flat = [int(value) for value in values]
    if not flat:
        raise ValueError("fixture arrays may not be empty")
    result: dict[str, Any] = {
        "shape": list(shape),
        "layout": layout,
        "count": len(flat),
        "nonzero_count": sum(value != 0 for value in flat),
        "min": min(flat),
        "max": max(flat),
    }
    if source_symbol:
        result["source_symbol"] = source_symbol
    return result


def round_away_q31(product: int) -> int:
    """Round a signed Q31 product to nearest, ties away from zero."""
    if product >= 0:
        return (product + (1 << 30)) >> 31
    return -(((-product) + (1 << 30)) >> 31)


def requant_trace(
    acc: int,
    bias: int,
    multiplier: int,
    shift: int,
    zero_point: int,
    activation_min: int,
    activation_max: int,
) -> tuple[int, dict[str, int]]:
    x = int(acc) + int(bias)
    product = x * int(multiplier)
    rounded = round_away_q31(product)
    shifted = rounded >> int(shift)
    before_int8 = shifted + int(zero_point)
    int8_clamped = max(-128, min(127, before_int8))
    output = max(int(activation_min), min(int(activation_max), int8_clamped))
    return output, {
        "acc": int(acc),
        "bias": int(bias),
        "x": x,
        "multiplier": int(multiplier),
        "product": product,
        "rounded_q31": rounded,
        "shift": int(shift),
        "shifted": shifted,
        "zero_point": int(zero_point),
        "before_int8_clamp": before_int8,
        "int8_clamped": int8_clamped,
        "activation_min": int(activation_min),
        "activation_max": int(activation_max),
        "output": int(output),
    }


def stem_reference(
    feature: list[list[list[int]]],
    weights: list[list[list[list[int]]]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    input_zero_point: int,
    output_zero_point: int,
) -> list[list[list[int]]]:
    height, width, channels = len(feature), len(feature[0]), len(feature[0][0])
    output: list[list[list[int]]] = []
    for oy in range(height):
        row: list[list[int]] = []
        for ox in range(width):
            pixel: list[int] = []
            for co in range(len(weights)):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy, ix = oy + kh - 1, ox + kw - 1
                        for ci in range(channels):
                            act = input_zero_point if iy < 0 or ix < 0 or iy >= height or ix >= width else feature[iy][ix][ci]
                            acc += int(act) * int(weights[co][ci][kh][kw])
                value, _ = requant_trace(acc, bias[co], multiplier[co], shift[co], output_zero_point, 0, 127)
                pixel.append(value)
            row.append(pixel)
        output.append(row)
    return output


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
    out_height, out_width = (height + stride - 1) // stride, (width + stride - 1) // stride
    output: list[list[list[int]]] = []
    for oy in range(out_height):
        row: list[list[int]] = []
        for ox in range(out_width):
            pixel: list[int] = []
            for channel in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy, ix = oy * stride + kh - 1, ox * stride + kw - 1
                        act = input_zero_point if iy < 0 or ix < 0 or iy >= height or ix >= width else feature[iy][ix][channel]
                        acc += int(act) * int(weights[channel][kh][kw])
                value, _ = requant_trace(acc, bias[channel], multiplier[channel], shift[channel], output_zero_point, 0, 127)
                pixel.append(value)
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
            for co in range(len(weights)):
                acc = sum(int(feature[y][x][ci]) * int(weights[co][ci]) for ci in range(channels))
                value, _ = requant_trace(acc, bias[co], multiplier[co], shift[co], output_zero_point, 0, 127)
                pixel.append(value)
            row.append(pixel)
        output.append(row)
    return output


def dw_terms(feature: list[list[list[int]]], weights: list[list[list[int]]], y: int, x: int, channel: int, stride: int, input_zero_point: int) -> tuple[int, list[dict[str, int]]]:
    height, width = len(feature), len(feature[0])
    acc = 0
    terms: list[dict[str, int]] = []
    for kh in range(3):
        for kw in range(3):
            iy, ix = y * stride + kh - 1, x * stride + kw - 1
            act = input_zero_point if iy < 0 or ix < 0 or iy >= height or ix >= width else int(feature[iy][ix][channel])
            weight = int(weights[channel][kh][kw])
            terms.append({"kh": kh, "kw": kw, "iy": iy, "ix": ix, "act": act, "weight": weight, "product": act * weight})
            acc += act * weight
    return acc, terms


def pw_terms(feature: list[list[list[int]]], weights: list[list[int]], y: int, x: int, channel: int) -> tuple[int, list[dict[str, int]]]:
    terms: list[dict[str, int]] = []
    acc = 0
    for ci, weight in enumerate(weights[channel]):
        act = int(feature[y][x][ci])
        weight = int(weight)
        terms.append({"ci": ci, "act": act, "weight": weight, "product": act * weight})
        acc += act * weight
    return acc, terms


def find_spot_checks(
    ds1_input: list[list[list[int]]], ds1_dw_weights: list[list[list[int]]], ds1_dw_bias: list[int], ds1_dw_mul: list[int], ds1_dw_shift: list[int],
    ds1_dw_output: list[list[list[int]]], ds1_pw_weights: list[list[int]], ds1_pw_bias: list[int], ds1_pw_mul: list[int], ds1_pw_shift: list[int], ds1_output: list[list[list[int]]],
    ds2_input: list[list[list[int]]], ds2_dw_weights: list[list[list[int]]], ds2_dw_bias: list[int], ds2_dw_mul: list[int], ds2_dw_shift: list[int], ds2_dw_output: list[list[list[int]]],
    ds2_pw_weights: list[list[int]], ds2_pw_bias: list[int], ds2_pw_mul: list[int], ds2_pw_shift: list[int], ds2_output: list[list[list[int]]],
    q: dict[str, int],
) -> list[dict[str, Any]]:
    """Return deterministic, independently recomputed arithmetic spot checks."""
    candidates: list[dict[str, Any]] = []

    def add_dw(name: str, feature: list[list[list[int]]], weights: list[list[list[int]]], bias: list[int], mul: list[int], shift: list[int], expected: list[list[list[int]]], stride: int, zp: int, y: int, x: int, channel: int) -> dict[str, Any]:
        acc, terms = dw_terms(feature, weights, y, x, channel, stride, q["input_zero_point"] if name.startswith("DS1") else q["ds2_input_zero_point"])
        value, trace = requant_trace(acc, bias[channel], mul[channel], shift[channel], zp, 0, 127)
        assert value == expected[y][x][channel]
        assert value == max(0, min(127, trace["shifted"] + zp))
        return {"name": name, "kind": "depthwise", "pixel": [y, x], "channel": channel, "terms": terms, "trace": trace, "expected": value}

    def add_pw(name: str, feature: list[list[list[int]]], weights: list[list[int]], bias: list[int], mul: list[int], shift: list[int], expected: list[list[list[int]]], zp: int, y: int, x: int, channel: int) -> dict[str, Any]:
        acc, terms = pw_terms(feature, weights, y, x, channel)
        value, trace = requant_trace(acc, bias[channel], mul[channel], shift[channel], zp, 0, 127)
        assert value == expected[y][x][channel]
        assert value == max(0, min(127, trace["shifted"] + zp))
        return {"name": name, "kind": "pointwise", "pixel": [y, x], "channel": channel, "terms": terms, "trace": trace, "expected": value}

    # Search order is fixed so the manifest remains reproducible.  At least
    # one sample has both positive and negative signed products, a non-zero
    # Q31 remainder, a non-zero shift, and activation saturation.
    searches = [
        ("DS1_DW", ds1_input, ds1_dw_weights, ds1_dw_bias, ds1_dw_mul, ds1_dw_shift, ds1_dw_output, 1, q["ds1_dw_output_zero_point"], "dw", "positive"),
        ("DS1_PW", ds1_dw_output, ds1_pw_weights, ds1_pw_bias, ds1_pw_mul, ds1_pw_shift, ds1_output, 1, q["ds1_pw_output_zero_point"], "pw", "positive"),
        ("DS2_DW", ds2_input, ds2_dw_weights, ds2_dw_bias, ds2_dw_mul, ds2_dw_shift, ds2_dw_output, 2, q["ds2_dw_output_zero_point"], "dw", "positive"),
        ("DS2_PW", ds2_dw_output, ds2_pw_weights, ds2_pw_bias, ds2_pw_mul, ds2_pw_shift, ds2_output, 1, q["ds2_pw_output_zero_point"], "pw", "positive_saturation"),
    ]
    for name, feature, weights, bias, mul, shift, expected, stride, zp, kind, target in searches:
        found: dict[str, Any] | None = None
        for y in range(len(expected)):
            for x in range(len(expected[0])):
                for channel in range(len(expected[0][0])):
                    if kind == "dw":
                        candidate = add_dw(name, feature, weights, bias, mul, shift, expected, stride, zp, y, x, channel)
                    else:
                        candidate = add_pw(name, feature, weights, bias, mul, shift, expected, zp, y, x, channel)
                    terms = candidate["terms"]
                    trace = candidate["trace"]
                    value = int(candidate["expected"])
                    has_signed_mix = any(term["product"] < 0 for term in terms) and any(term["product"] > 0 for term in terms)
                    has_rounding_remainder = abs(trace["product"]) & ((1 << 31) - 1)
                    if target == "positive":
                        target_match = value > 0
                    else:
                        target_match = value == 127 and trace["before_int8_clamp"] > 127
                    if has_signed_mix and has_rounding_remainder and trace["shift"] > 0 and target_match:
                        found = candidate
                        break
                if found:
                    break
            if found:
                break
        if found is None:
            raise AssertionError(f"could not find a non-trivial arithmetic spot check for {name}")
        candidates.append(found)

    # The headers use zero-point 0 for this C0 export.  Keep this explicit in
    # the evidence: the sample has a real padding/quantized path and the
    # independent formula includes the zero-point addition before saturation.
    if any(item["trace"]["zero_point"] != 0 for item in candidates):
        raise AssertionError("unexpected header zero-point drift")
    return candidates


def write_i8(path: Path, values: Iterable[int]) -> None:
    path.write_text("".join(f"{int(value) & 0xFF:02x}\n" for value in values), encoding="ascii")


def pack_words(values: Iterable[int], byte_values: bool) -> list[int]:
    source = [int(value) for value in values]
    if byte_values:
        words: list[int] = []
        for start in range(0, len(source), 4):
            word = 0
            for lane, value in enumerate(source[start : start + 4]):
                word |= (value & 0xFF) << (lane * 8)
            words.append(word)
        return words
    return [value & 0xFFFFFFFF for value in source]


def write_cfg(path: Path, arrays: dict[int, dict[str, list[int]]]) -> dict[int, int]:
    regions = {
        1: {"dw_weight": 0x00003000, "dw_bias": 0x00003100, "dw_multiplier": 0x00003140, "dw_shift": 0x00003180, "pw_weight": 0x00003200, "pw_bias": 0x00003400, "pw_multiplier": 0x00003480, "pw_shift": 0x00003500},
        2: {"dw_weight": 0x00004000, "dw_bias": 0x00004200, "dw_multiplier": 0x00004280, "dw_shift": 0x00004300, "pw_weight": 0x00004400, "pw_bias": 0x00004C00, "pw_multiplier": 0x00004D00, "pw_shift": 0x00004E00},
    }
    order = ("dw_weight", "dw_bias", "dw_multiplier", "dw_shift", "pw_weight", "pw_bias", "pw_multiplier", "pw_shift")
    kind_ids = {name: idx for idx, name in enumerate(order)}
    counts: dict[int, int] = {}
    lines: list[str] = []
    for layer in (1, 2):
        index = 0
        for kind in order:
            values = arrays[layer][kind]
            words = pack_words(values, kind.endswith("weight"))
            for word_offset, word in enumerate(words):
                lines.append(f"{layer} {kind_ids[kind]} {index} {regions[layer][kind] + word_offset * 4:08x} f {word:08x}")
                index += 1
        counts[layer] = index
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return counts


def sink_stream(output: list[list[list[int]]], sink_base: int, layer: int) -> tuple[list[int], list[dict[str, int]]]:
    height, width, channels = len(output), len(output[0]), len(output[0][0])
    tiles = channels // 8
    if channels % 8:
        raise ValueError("M1.1-A sink requires Cout divisible by 8")
    pixels_per_context = 8
    words: list[int] = []
    rows: list[dict[str, int]] = []
    context_count = (height * width) // pixels_per_context
    for context in range(context_count):
        for tile in range(tiles):
            for drain_word in range(16):
                pixel_slot = drain_word // 2
                pixel = context * pixels_per_context + pixel_slot
                channel_base = tile * 8 + (drain_word % 2) * 4
                bytes4 = [int(output[pixel // width][pixel % width][channel_base + lane]) for lane in range(4)]
                data = sum((value & 0xFF) << (lane * 8) for lane, value in enumerate(bytes4))
                word_index = len(rows)
                rows.append({
                    "layer": layer,
                    "word_index": word_index,
                    "address": sink_base + word_index * 4,
                    "data": data,
                    "byte_mask": 0xF,
                    "owner": context & 1,
                    "epoch": context >> 1,
                    "context": context & 3,
                    "request_cycle": word_index,
                    "response_cycle": word_index + 1,
                })
                words.extend(bytes4)
    if len(words) != height * width * channels:
        raise AssertionError(f"layer {layer} sink byte count mismatch")
    return words, rows


def write_sink(path: Path, rows: list[dict[str, int]]) -> None:
    path.write_text(
        "".join(
            f"{row['layer']} {row['word_index']} {row['address']:08x} {row['data']:08x} {row['byte_mask']:x} "
            f"{row['owner']} {row['epoch']} {row['context']} {row['request_cycle']} {row['response_cycle']}\n"
            for row in rows
        ),
        encoding="ascii",
    )


def build_fixture(out_dir: Path, report_path: Path) -> dict[str, Any]:
    weights_source, quant_source = WEIGHTS_H.read_text(encoding="utf-8"), QUANT_H.read_text(encoding="utf-8")
    model_input = reshape(parse_c_array(weights_source, "g_model_input_image_i8_packed"), (32, 32, 3))
    stem_weights = reshape(parse_c_array(weights_source, "g_stem_weight_i8_packed"), (16, 3, 3, 3))
    ds1_dw_weights = reshape(parse_c_array(weights_source, "g_ds1_dw_weight_i8_packed"), (16, 3, 3))
    ds1_pw_weights = reshape(parse_c_array(weights_source, "g_ds1_pw_weight_i8_packed"), (32, 16))
    ds2_dw_weights = reshape(parse_c_array(weights_source, "g_ds2_dw_weight_i8_packed"), (32, 3, 3))
    ds2_pw_weights = reshape(parse_c_array(weights_source, "g_ds2_pw_weight_i8_packed"), (64, 32))

    def q_array(symbol: str) -> list[int]:
        return parse_c_array(quant_source, symbol)

    q = {
        "input_zero_point": parse_c_scalar(quant_source, "g_model_input_zero_point"),
        "stem_output_zero_point": parse_c_scalar(quant_source, "g_stem_output_zero_point"),
        "ds1_input_zero_point": parse_c_scalar(quant_source, "g_ds1_input_zero_point"),
        "ds1_dw_output_zero_point": parse_c_scalar(quant_source, "g_ds1_dw_output_zero_point"),
        "ds1_pw_output_zero_point": parse_c_scalar(quant_source, "g_ds1_pw_output_zero_point"),
        "ds2_input_zero_point": parse_c_scalar(quant_source, "g_ds2_input_zero_point"),
        "ds2_dw_output_zero_point": parse_c_scalar(quant_source, "g_ds2_dw_output_zero_point"),
        "ds2_pw_output_zero_point": parse_c_scalar(quant_source, "g_ds2_pw_output_zero_point"),
    }
    stem_bias, stem_mul, stem_shift = q_array("g_stem_bias"), q_array("g_stem_mul"), q_array("g_stem_shift_words")
    ds1_dw_bias, ds1_dw_mul, ds1_dw_shift = q_array("g_ds1_dw_bias"), q_array("g_ds1_dw_mul"), q_array("g_ds1_dw_shift_words")
    ds1_pw_bias, ds1_pw_mul, ds1_pw_shift = q_array("g_ds1_pw_bias"), q_array("g_ds1_pw_mul"), q_array("g_ds1_pw_shift_words")
    ds2_dw_bias, ds2_dw_mul, ds2_dw_shift = q_array("g_ds2_dw_bias"), q_array("g_ds2_dw_mul"), q_array("g_ds2_dw_shift_words")
    ds2_pw_bias, ds2_pw_mul, ds2_pw_shift = q_array("g_ds2_pw_bias"), q_array("g_ds2_pw_mul"), q_array("g_ds2_pw_shift_words")

    stem = stem_reference(model_input, stem_weights, stem_bias, stem_mul, stem_shift, q["input_zero_point"], q["stem_output_zero_point"])
    ds1_dw = depthwise_reference(stem, ds1_dw_weights, ds1_dw_bias, ds1_dw_mul, ds1_dw_shift, q["ds1_input_zero_point"], q["ds1_dw_output_zero_point"], 1)
    ds1 = pointwise_reference(ds1_dw, ds1_pw_weights, ds1_pw_bias, ds1_pw_mul, ds1_pw_shift, q["ds1_pw_output_zero_point"])
    ds2_dw = depthwise_reference(ds1, ds2_dw_weights, ds2_dw_bias, ds2_dw_mul, ds2_dw_shift, q["ds2_input_zero_point"], q["ds2_dw_output_zero_point"], 2)
    ds2 = pointwise_reference(ds2_dw, ds2_pw_weights, ds2_pw_bias, ds2_pw_mul, ds2_pw_shift, q["ds2_pw_output_zero_point"])

    arrays_for_cfg = {
        1: {
            "dw_weight": flatten(ds1_dw_weights), "dw_bias": ds1_dw_bias, "dw_multiplier": ds1_dw_mul, "dw_shift": ds1_dw_shift,
            "pw_weight": flatten(ds1_pw_weights), "pw_bias": ds1_pw_bias, "pw_multiplier": ds1_pw_mul, "pw_shift": ds1_pw_shift,
        },
        2: {
            "dw_weight": flatten(ds2_dw_weights), "dw_bias": ds2_dw_bias, "dw_multiplier": ds2_dw_mul, "dw_shift": ds2_dw_shift,
            "pw_weight": flatten(ds2_pw_weights), "pw_bias": ds2_pw_bias, "pw_multiplier": ds2_pw_mul, "pw_shift": ds2_pw_shift,
        },
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    write_i8(out_dir / "ds12_stream_input_i8.hex", flatten(model_input))
    write_i8(out_dir / "ds12_stream_ds1_input_i8.hex", flatten(stem))
    write_i8(out_dir / "ds12_stream_ds1_dw_output_i8.hex", flatten(ds1_dw))
    write_i8(out_dir / "ds12_stream_ds1_pw_output_i8.hex", flatten(ds1))
    write_i8(out_dir / "ds12_stream_ds2_input_i8.hex", flatten(ds1))
    write_i8(out_dir / "ds12_stream_ds2_dw_output_i8.hex", flatten(ds2_dw))
    write_i8(out_dir / "ds12_stream_ds2_pw_output_i8.hex", flatten(ds2))
    sink1_bytes, sink1_rows = sink_stream(ds1, 0x0010_0000, 1)
    sink2_bytes, sink2_rows = sink_stream(ds2, 0x0020_0000, 2)
    write_i8(out_dir / "ds12_stream_ds1_output_i8.hex", sink1_bytes)
    write_i8(out_dir / "ds12_stream_ds2_output_i8.hex", sink2_bytes)
    write_sink(out_dir / "ds12_stream_sink_words.hex", sink1_rows + sink2_rows)
    cfg_counts = write_cfg(out_dir / "ds12_stream_cfg_transactions.hex", arrays_for_cfg)

    # These are the exact packed weight streams that the runtime config store
    # receives.  They are useful when diagnosing an address/byte-lane mismatch.
    write_i8(out_dir / "ds12_stream_ds1_dw_weight_i8.hex", flatten(ds1_dw_weights))
    write_i8(out_dir / "ds12_stream_ds1_pw_weight_i8.hex", flatten(ds1_pw_weights))
    write_i8(out_dir / "ds12_stream_ds2_dw_weight_i8.hex", flatten(ds2_dw_weights))
    write_i8(out_dir / "ds12_stream_ds2_pw_weight_i8.hex", flatten(ds2_pw_weights))

    spot_checks = find_spot_checks(
        stem, ds1_dw_weights, ds1_dw_bias, ds1_dw_mul, ds1_dw_shift, ds1_dw,
        ds1_pw_weights, ds1_pw_bias, ds1_pw_mul, ds1_pw_shift, ds1,
        ds1, ds2_dw_weights, ds2_dw_bias, ds2_dw_mul, ds2_dw_shift, ds2_dw,
        ds2_pw_weights, ds2_pw_bias, ds2_pw_mul, ds2_pw_shift, ds2, q,
    )
    # A second, intentionally simple scalar pass catches accidental reliance
    # on an intermediate list's ordering when producing fixture files.
    for sample in spot_checks:
        trace = sample["trace"]
        product = int(trace["x"]) * int(trace["multiplier"])
        scalar_value = max(0, min(127, (round_away_q31(product) >> int(trace["shift"])) + int(trace["zero_point"])))
        if scalar_value != int(sample["expected"]):
            raise AssertionError(f"software spot check disagreement: {sample['name']}")

    stream_specs = {
        "model_input": (flatten(model_input), [32, 32, 3], "NHWC pixel-major signed int8", "g_model_input_image_i8_packed"),
        "DS1_input": (flatten(stem), [32, 32, 16], "NHWC pixel-major signed int8 (stem output)", None),
        "DS1_DW_expected": (flatten(ds1_dw), [32, 32, 16], "NHWC pixel-major signed int8", None),
        "DS1_PW_expected": (flatten(ds1), [32, 32, 32], "NHWC pixel-major signed int8", None),
        "DS2_input": (flatten(ds1), [32, 32, 32], "NHWC pixel-major signed int8 (DS1 PW output)", None),
        "DS2_DW_expected": (flatten(ds2_dw), [16, 16, 32], "NHWC pixel-major signed int8", None),
        "DS2_PW_expected": (flatten(ds2), [16, 16, 64], "NHWC pixel-major signed int8", None),
        "DS1_sink_bytes": (sink1_bytes, [32, 32, 32], "context/tile/drain-word sink byte order", None),
        "DS2_sink_bytes": (sink2_bytes, [16, 16, 64], "context/tile/drain-word sink byte order", None),
    }
    stream_stats = {name: stats(values, shape, layout, symbol) for name, (values, shape, layout, symbol) in stream_specs.items()}
    for name in ("DS1_input", "DS2_input", "DS1_DW_expected", "DS1_PW_expected", "DS2_DW_expected", "DS2_PW_expected", "DS1_sink_bytes", "DS2_sink_bytes"):
        if stream_stats[name]["nonzero_count"] == 0:
            raise AssertionError(f"all-zero fixture stream rejected: {name}")

    array_stats = {
        "model_input": stats(flatten(model_input), (32, 32, 3), "NHWC pixel-major signed int8", "g_model_input_image_i8_packed"),
        "stem_weight": stats(flatten(stem_weights), (16, 3, 3, 3), "[Cout,Cin,Kh,Kw] signed int8", "g_stem_weight_i8_packed"),
        "DS1_dw_weight": stats(flatten(ds1_dw_weights), (16, 3, 3), "[Cin,Kh,Kw] signed int8", "g_ds1_dw_weight_i8_packed"),
        "DS1_pw_weight": stats(flatten(ds1_pw_weights), (32, 16), "[Cout,Cin] signed int8", "g_ds1_pw_weight_i8_packed"),
        "DS2_dw_weight": stats(flatten(ds2_dw_weights), (32, 3, 3), "[Cin,Kh,Kw] signed int8", "g_ds2_dw_weight_i8_packed"),
        "DS2_pw_weight": stats(flatten(ds2_pw_weights), (64, 32), "[Cout,Cin] signed int8", "g_ds2_pw_weight_i8_packed"),
    }
    quant_stats: dict[str, Any] = {}
    for name, symbol, shape in (
        ("stem_bias", "g_stem_bias", (16,)), ("stem_multiplier", "g_stem_mul", (16,)), ("stem_shift", "g_stem_shift_words", (16,)),
        ("DS1_dw_bias", "g_ds1_dw_bias", (16,)), ("DS1_dw_multiplier", "g_ds1_dw_mul", (16,)), ("DS1_dw_shift", "g_ds1_dw_shift_words", (16,)),
        ("DS1_pw_bias", "g_ds1_pw_bias", (32,)), ("DS1_pw_multiplier", "g_ds1_pw_mul", (32,)), ("DS1_pw_shift", "g_ds1_pw_shift_words", (32,)),
        ("DS2_dw_bias", "g_ds2_dw_bias", (32,)), ("DS2_dw_multiplier", "g_ds2_dw_mul", (32,)), ("DS2_dw_shift", "g_ds2_dw_shift_words", (32,)),
        ("DS2_pw_bias", "g_ds2_pw_bias", (64,)), ("DS2_pw_multiplier", "g_ds2_pw_mul", (64,)), ("DS2_pw_shift", "g_ds2_pw_shift_words", (64,)),
    ):
        quant_stats[name] = stats(q_array(symbol), shape, "signed int32 quantization words", symbol)

    manifest: dict[str, Any] = {
        "schema": "m11a-nonzero-fixture-v1",
        "status": "NONZERO_FIXTURE_REFERENCE_PASS",
        "source": {
            "weights_header": {"path": str(WEIGHTS_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(WEIGHTS_H)},
            "quant_header": {"path": str(QUANT_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(QUANT_H)},
            "descriptor_header": {"path": str(DESC_H.relative_to(ROOT)).replace("\\", "/"), "sha256": sha256(DESC_H)},
            "expected_source_boundary": "headers and this independent software reference; never RTL output",
        },
        "descriptor": {
            "activation_min": 0, "activation_max": 127, "input_layout": "NHWC pixel-major signed int8; 16-byte per-pixel memory beat",
            "DS1": {"in_shape": [32, 32, 16], "out_shape": [32, 32, 32], "stride": 1, "row_stride_bytes": 512, "input_base": "0x00000000", "sink_base": "0x00100000", "input_zero_point": q["ds1_input_zero_point"], "dw_output_zero_point": q["ds1_dw_output_zero_point"], "pw_output_zero_point": q["ds1_pw_output_zero_point"], "cfg_words": cfg_counts[1], "output_words": len(sink1_rows), "dw_mac": 147456, "pw_mac": 524288, "dw_vectors": 1024, "pw_tokens": 8192},
            "DS2": {"in_shape": [32, 32, 32], "out_shape": [16, 16, 64], "stride": 2, "row_stride_bytes": 1024, "input_base": "0x00000000", "sink_base": "0x00200000", "input_zero_point": q["ds2_input_zero_point"], "dw_output_zero_point": q["ds2_dw_output_zero_point"], "pw_output_zero_point": q["ds2_pw_output_zero_point"], "cfg_words": cfg_counts[2], "output_words": len(sink2_rows), "dw_mac": 73728, "pw_mac": 524288, "dw_vectors": 512, "pw_tokens": 8192},
        },
        "quant": q,
        "arrays": array_stats,
        "quant_arrays": quant_stats,
        "streams": stream_stats,
        "files": {
            "config": "ds12_stream_cfg_transactions.hex", "sink_words": "ds12_stream_sink_words.hex",
            "DS1_input": "ds12_stream_ds1_input_i8.hex", "DS1_DW_expected": "ds12_stream_ds1_dw_output_i8.hex", "DS1_PW_expected": "ds12_stream_ds1_pw_output_i8.hex", "DS1_sink_bytes": "ds12_stream_ds1_output_i8.hex",
            "DS2_input": "ds12_stream_ds2_input_i8.hex", "DS2_DW_expected": "ds12_stream_ds2_dw_output_i8.hex", "DS2_PW_expected": "ds12_stream_ds2_pw_output_i8.hex", "DS2_sink_bytes": "ds12_stream_ds2_output_i8.hex",
        },
        "spot_checks": spot_checks,
        "independent_software_spot_checks": {"status": "PASS", "checks": len(spot_checks), "coverage": ["signed products", "multiply", "Q31 nearest-away-from-zero rounding", "arithmetic right shift", "zero-point addition (header zp=0)", "INT8/activation saturation"]},
        "rtl_evidence_boundary": "This fixture is a direct M1.1-A unit gate only; it is not full-network or full-top evidence.",
    }
    manifest_path = out_dir / "m11a_nonzero_fixture_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    # Keep a small, reviewable source-controlled copy of the metadata while
    # leaving the generated hex streams under build/ (which is intentionally
    # ignored).  The manifest contains source hashes and all stream/descriptor
    # statistics needed to audit a regenerated fixture.
    tracked_manifest = ROOT / "tests/fixtures/m11a_nonzero/m11a_nonzero_fixture_manifest.json"
    tracked_manifest.parent.mkdir(parents=True, exist_ok=True)
    tracked_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_lines = [
        "# M1.1-A non-zero DS1/DS2 functional fixture",
        "",
        "Status: `NONZERO_FIXTURE_REFERENCE_PASS` (independent software reference; RTL gate is reported by the simulator).",
        "",
        "The fixture is generated directly from the checked-in firmware headers. No RTL output is used as an expected value.",
        "",
        "## Sources",
        "",
        f"- `{WEIGHTS_H.relative_to(ROOT).as_posix()}` SHA256 `{manifest['source']['weights_header']['sha256']}`",
        f"- `{QUANT_H.relative_to(ROOT).as_posix()}` SHA256 `{manifest['source']['quant_header']['sha256']}`",
        f"- `{DESC_H.relative_to(ROOT).as_posix()}` SHA256 `{manifest['source']['descriptor_header']['sha256']}`",
        "",
        "## Descriptor and arithmetic contract",
        "",
        "| Layer | Input -> output | Stride | Row stride | Config words | DW vectors/MAC | PW tokens/MAC | Sink words |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
        f"| DS1 | 32x32x16 -> 32x32x32 | 1 | 512 | {cfg_counts[1]} | 1024 / 147456 | 8192 / 524288 | {len(sink1_rows)} |",
        f"| DS2 | 32x32x32 -> 16x16x64 | 2 | 1024 | {cfg_counts[2]} | 512 / 73728 | 8192 / 524288 | {len(sink2_rows)} |",
        "",
        "Quantization uses the header bias/multiplier/shift arrays, Q31 nearest-away-from-zero rounding, arithmetic right shift, header zero-points, INT8 saturation, and ReLU range [0,127].",
        "",
        "## Non-zero stream evidence",
        "",
        "| Stream | Shape/layout | Non-zero | Min | Max |",
        "|---|---|---:|---:|---:|",
    ]
    for name in ("DS1_input", "DS1_DW_expected", "DS1_PW_expected", "DS2_input", "DS2_DW_expected", "DS2_PW_expected", "DS1_sink_bytes", "DS2_sink_bytes"):
        item = stream_stats[name]
        report_lines.append(f"| {name} | `{'x'.join(str(v) for v in item['shape'])}`, {item['layout']} | {item['nonzero_count']} | {item['min']} | {item['max']} |")
    report_lines += [
        "",
        "## Independent spot checks",
        "",
        "The four checks below recompute selected DW/PW outputs from scalar terms and compare them with the emitted tensors. Each selected sample has signed products, a non-zero Q31 remainder, and a positive shift; the DS2 PW sample also exercises positive activation saturation to 127. All header zero-points are explicitly applied (and are zero for this export).",
        "",
        "| Check | Pixel | Channel | Acc | Product | Rounded | Shift | Pre-clamp | Output |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for check in spot_checks:
        trace = check["trace"]
        report_lines.append(f"| {check['name']} | {check['pixel']} | {check['channel']} | {trace['acc']} | {trace['product']} | {trace['rounded_q31']} | {trace['shift']} | {trace['before_int8_clamp']} | {check['expected']} |")
    report_lines += [
        "",
        "The simulator consumes the sink-byte files and sink-word metadata under the fixture directory. This evidence is limited to the standalone M1.1-A core; it is not full-network/full-top evidence.",
        "",
    ]
    report_path.write_text("\n".join(report_lines), encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/m11a_nonzero_fixture")
    parser.add_argument("--report", type=Path, default=ROOT / "docs/reports/m11a_nonzero_fixture_20260907.md")
    args = parser.parse_args()
    manifest = build_fixture(args.out, args.report)
    print(json.dumps({"status": manifest["status"], "out": str(args.out), "DS1_nonzero": manifest["streams"]["DS1_input"]["nonzero_count"], "DS2_nonzero": manifest["streams"]["DS2_input"]["nonzero_count"], "DS1_sink_words": manifest["descriptor"]["DS1"]["output_words"], "DS2_sink_words": manifest["descriptor"]["DS2"]["output_words"]}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
