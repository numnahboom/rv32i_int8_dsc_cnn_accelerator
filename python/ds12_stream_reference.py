#!/usr/bin/env python3
"""Build an independent DS1 -> DS2 streaming contract package.

This is a reference/vector/traffic harness.  It does not instantiate or
modify a datapath.  The default input is the checked-in C0 HWQA INT8 export
(`build/c0_hwqa_export/...npz`), so DS1 and DS2 are evaluated with the real
weights and quantization arrays rather than a reduced synthetic network.

The generated files deliberately make the future interface observable:
packed parameter reads carry byte enables, output words carry owner/epoch and
one of four context tags, and each accepted read has a response exactly one
cycle later.  The Verilog companion consumes these files and reports the DUT
boundary as DEFERRED unless a future DUT is explicitly wired in.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_test_vectors import dsblock_same_golden, requantize_scalar, stem_same_golden  # noqa: E402
from quantize_export import flat_to_feature, i8_image_from_uint8, run_exported_int8_model  # noqa: E402


LAYERS = {
    1: {"name": "DS1", "in_h": 32, "in_w": 32, "in_c": 16, "out_h": 32, "out_w": 32, "out_c": 32, "stride": 1},
    2: {"name": "DS2", "in_h": 32, "in_w": 32, "in_c": 32, "out_h": 16, "out_w": 16, "out_c": 64, "stride": 2},
}

# The map is a stable harness address map, intentionally separate from any
# host pointer values used by the firmware image.  Every base is 32-bit-word
# aligned and each following region starts after the previous region.
REGIONS = {
    1: {
        "dw_weight": 0x00003000, "dw_bias": 0x00003100, "dw_multiplier": 0x00003140,
        "dw_shift": 0x00003180, "pw_weight": 0x00003200, "pw_bias": 0x00003400,
        "pw_multiplier": 0x00003480, "pw_shift": 0x00003500,
    },
    2: {
        "dw_weight": 0x00004000, "dw_bias": 0x00004200, "dw_multiplier": 0x00004280,
        "dw_shift": 0x00004300, "pw_weight": 0x00004400, "pw_bias": 0x00004C00,
        "pw_multiplier": 0x00004D00, "pw_shift": 0x00004E00,
    },
}

PARAM_ORDER = ("dw_weight", "dw_bias", "dw_multiplier", "dw_shift", "pw_weight", "pw_bias", "pw_multiplier", "pw_shift")


def dw_same_reference(
    feature: list[list[list[int]]], input_zero_point: int,
    weight: np.ndarray, bias: np.ndarray, multiplier: np.ndarray,
    shift: np.ndarray, output_zero_point: int,
) -> list[list[int]]:
    """Independent pixel-major DS depthwise reference (including SAME pads)."""
    in_h = len(feature)
    in_w = len(feature[0])
    channels = len(feature[0][0])
    out: list[list[int]] = [[0 for _ in range(channels)] for _ in range(in_h * in_w)]
    for oy in range(in_h):
        for ox in range(in_w):
            pixel = oy * in_w + ox
            for channel in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy = oy + kh - 1
                        ix = ox + kw - 1
                        act = input_zero_point if not (0 <= iy < in_h and 0 <= ix < in_w) else feature[iy][ix][channel]
                        acc += int(act) * int(weight[channel, kh * 3 + kw])
                out[pixel][channel] = requantize_scalar(
                    acc, int(bias[channel]), int(multiplier[channel]), int(shift[channel]),
                    output_zero_point, 0, 127,
                )
    return out


def dw_strided_same_reference(
    feature: list[list[list[int]]], input_zero_point: int,
    weight: np.ndarray, bias: np.ndarray, multiplier: np.ndarray,
    shift: np.ndarray, output_zero_point: int, stride: int,
) -> list[list[int]]:
    """Depthwise SAME reference for the strided DS2 window contract."""
    in_h = len(feature)
    in_w = len(feature[0])
    out_h = (in_h + stride - 1) // stride
    out_w = (in_w + stride - 1) // stride
    channels = len(feature[0][0])
    out: list[list[int]] = [[0 for _ in range(channels)] for _ in range(out_h * out_w)]
    for oy in range(out_h):
        for ox in range(out_w):
            pixel = oy * out_w + ox
            for channel in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy = oy * stride + kh - 1
                        ix = ox * stride + kw - 1
                        act = input_zero_point if not (0 <= iy < in_h and 0 <= ix < in_w) else feature[iy][ix][channel]
                        acc += int(act) * int(weight[channel, kh * 3 + kw])
                out[pixel][channel] = requantize_scalar(
                    acc, int(bias[channel]), int(multiplier[channel]), int(shift[channel]),
                    output_zero_point, 0, 127,
                )
    return out


def u32(value: int) -> int:
    return int(value) & 0xFFFFFFFF


def pack_words(values: Iterable[int], byte_values: bool = False) -> list[int]:
    vals = [u32(v) if not byte_values else int(v) & 0xFF for v in values]
    if byte_values:
        out = []
        for start in range(0, len(vals), 4):
            word = 0
            for lane, value in enumerate(vals[start : start + 4]):
                word |= value << (8 * lane)
            out.append(word)
        return out
    return vals


def scalar(values: np.lib.npyio.NpzFile, key: str) -> int:
    return int(np.asarray(values[key]).reshape(()))


def params_for_layer(values: np.lib.npyio.NpzFile, layer: int, kind: str) -> np.ndarray:
    return np.asarray(values[f"ds{layer}_{kind}"], dtype=np.int64).reshape(-1)


def validate_npz(values: np.lib.npyio.NpzFile) -> None:
    expected = {
        "input_image_i8": (32, 32, 3),
        "stem_weight": (16, 27), "stem_bias": (16,), "stem_multiplier": (16,), "stem_shift": (16,),
        "ds1_dw_weight": (16, 9), "ds1_pw_weight": (32, 16),
        "ds2_dw_weight": (32, 9), "ds2_pw_weight": (64, 32),
        "ds1_dw_bias": (16,), "ds1_dw_multiplier": (16,), "ds1_dw_shift": (16,),
        "ds1_pw_bias": (32,), "ds1_pw_multiplier": (32,), "ds1_pw_shift": (32,),
        "ds2_dw_bias": (32,), "ds2_dw_multiplier": (32,), "ds2_dw_shift": (32,),
        "ds2_pw_bias": (64,), "ds2_pw_multiplier": (64,), "ds2_pw_shift": (64,),
    }
    missing = [key for key in expected if key not in values]
    if missing:
        raise ValueError(f"C0 export missing required arrays: {missing}")
    bad = [(key, tuple(values[key].shape), shape) for key, shape in expected.items() if tuple(values[key].shape) != shape]
    if bad:
        raise ValueError(f"C0 export shape mismatch: {bad}")
    if values["input_image_i8"].dtype != np.int8:
        raise ValueError("input_image_i8 must be signed INT8")
    if "input_image_uint8" not in values or tuple(values["input_image_uint8"].shape) != (32, 32, 3):
        raise ValueError("C0 export must carry the real uint8 source image")


def write_i8(path: Path, data: np.ndarray | list[Any]) -> None:
    flat = np.asarray(data, dtype=np.int16).reshape(-1)
    path.write_text("".join(f"{int(value) & 0xFF:02x}\n" for value in flat), encoding="ascii")


def check_existing_input_vector(path: Path, image_i8: np.ndarray) -> None:
    if not path.exists():
        raise FileNotFoundError(f"current C0 input vector is missing: {path}")
    tokens = [token.strip() for token in path.read_text(encoding="ascii").split() if token.strip()]
    try:
        values = np.asarray([int(token, 16) & 0xFF for token in tokens], dtype=np.uint8)
    except ValueError as exc:
        raise ValueError(f"invalid byte in C0 input vector {path}") from exc
    expected = np.asarray(image_i8, dtype=np.int16).reshape(-1).astype(np.int8).view(np.uint8)
    if values.shape != expected.shape or not np.array_equal(values, expected):
        raise AssertionError(f"C0 input vector mismatch: {path}")


def write_cfg(path: Path, rows: list[dict[str, int | str]], counts: dict[int, int]) -> None:
    # Plain numeric rows keep the file consumable by Verilog $fscanf without
    # a parser-specific comment/header extension.  Counts live in JSON.
    lines: list[str] = []
    kind_ids = {name: idx for idx, name in enumerate(PARAM_ORDER)}
    for row in rows:
        lines.append(f"{row['layer']} {kind_ids[str(row['kind'])]} {row['index']} {int(row['address']):08x} {int(row['byte_enable']):x} {int(row['data']):08x}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_sink(path: Path, rows: list[dict[str, int]]) -> None:
    lines: list[str] = []
    for row in rows:
        lines.append("{layer} {word_index} {address:08x} {data:08x} {byte_mask:x} {owner} {epoch} {context} {request_cycle} {response_cycle}".format(**row))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def build_reference(npz_path: Path, out_dir: Path, input_vector: Path) -> dict[str, Any]:
    with np.load(npz_path, allow_pickle=True) as p:
        validate_npz(p)
        image_i8 = np.asarray(p["input_image_i8"], dtype=np.int8)
        image_from_u8 = np.asarray(i8_image_from_uint8(np.asarray(p["input_image_uint8"], dtype=np.uint8)), dtype=np.int8)
        if not np.array_equal(image_i8, image_from_u8):
            raise AssertionError("C0 input_image_i8 is not the centered form of input_image_uint8")
        check_existing_input_vector(input_vector, image_i8)
        feature = image_from_u8.astype(np.int16).tolist()
        _, _, stem_flat = stem_same_golden(
            feature, scalar(p, "input_zero_point"), np.asarray(p["stem_weight"], dtype=np.int8).astype(np.int16).tolist(),
            np.asarray(p["stem_bias"], dtype=np.int32).astype(int).tolist(), np.asarray(p["stem_multiplier"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["stem_shift"], dtype=np.int32).astype(int).tolist(), scalar(p, "stem_output_zero_point"), 0, 127,
        )
        ds1_in = flat_to_feature(stem_flat, 32, 32, 16)
        _, _, ds1_flat = dsblock_same_golden(
            ds1_in, scalar(p, "stem_output_zero_point"),
            np.asarray(p["ds1_dw_weight"], dtype=np.int8).astype(np.int16).tolist(), np.asarray(p["ds1_dw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds1_dw_multiplier"], dtype=np.int32).astype(int).tolist(), np.asarray(p["ds1_dw_shift"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds1_pw_weight"], dtype=np.int8).astype(np.int16).tolist(), np.asarray(p["ds1_pw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds1_pw_multiplier"], dtype=np.int32).astype(int).tolist(), np.asarray(p["ds1_pw_shift"], dtype=np.int32).astype(int).tolist(),
            1, scalar(p, "ds1_dw_output_zero_point"), 0, 127, scalar(p, "ds1_pw_output_zero_point"), 0, 127,
        )
        ds1_out = np.asarray(flat_to_feature(ds1_flat, 32, 32, 32), dtype=np.int8)
        ds1_dw = dw_same_reference(
            ds1_in, scalar(p, "stem_output_zero_point"), np.asarray(p["ds1_dw_weight"], dtype=np.int8),
            np.asarray(p["ds1_dw_bias"], dtype=np.int32), np.asarray(p["ds1_dw_multiplier"], dtype=np.int32),
            np.asarray(p["ds1_dw_shift"], dtype=np.int32), scalar(p, "ds1_dw_output_zero_point"),
        )
        _, _, ds2_flat = dsblock_same_golden(
            ds1_out.astype(np.int16).tolist(), scalar(p, "ds1_pw_output_zero_point"),
            np.asarray(p["ds2_dw_weight"], dtype=np.int8).astype(np.int16).tolist(), np.asarray(p["ds2_dw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds2_dw_multiplier"], dtype=np.int32).astype(int).tolist(), np.asarray(p["ds2_dw_shift"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds2_pw_weight"], dtype=np.int8).astype(np.int16).tolist(), np.asarray(p["ds2_pw_bias"], dtype=np.int32).astype(int).tolist(),
            np.asarray(p["ds2_pw_multiplier"], dtype=np.int32).astype(int).tolist(), np.asarray(p["ds2_pw_shift"], dtype=np.int32).astype(int).tolist(),
            2, scalar(p, "ds2_dw_output_zero_point"), 0, 127, scalar(p, "ds2_pw_output_zero_point"), 0, 127,
        )
        ds2_out = np.asarray(flat_to_feature(ds2_flat, 16, 16, 64), dtype=np.int8)
        # Keep the DS2 DW-only reference as a first-class stream artifact.
        # The standalone 16-lane DS2 endpoint consumes ds1_out and must be
        # checked before any pointwise stage is considered.
        ds2_dw = dw_strided_same_reference(
            ds1_out.astype(np.int16).tolist(), scalar(p, "ds1_pw_output_zero_point"),
            np.asarray(p["ds2_dw_weight"], dtype=np.int8),
            np.asarray(p["ds2_dw_bias"], dtype=np.int32),
            np.asarray(p["ds2_dw_multiplier"], dtype=np.int32),
            np.asarray(p["ds2_dw_shift"], dtype=np.int32),
            scalar(p, "ds2_dw_output_zero_point"), 2,
        )
        logits, argmax = run_exported_int8_model(np.asarray(p["input_image_uint8"], dtype=np.uint8), {key: p[key] for key in p.files})
        if "expected_logits" in p and logits != np.asarray(p["expected_logits"], dtype=np.int8).astype(int).tolist():
            raise AssertionError("reference logits disagree with the C0 export's expected_logits")
        if "expected_argmax" in p and int(argmax) != scalar(p, "expected_argmax"):
            raise AssertionError("reference argmax disagrees with the C0 export")

        out_dir.mkdir(parents=True, exist_ok=True)
        write_i8(out_dir / "ds12_stream_input_i8.hex", image_i8)
        write_i8(out_dir / "ds12_stream_ds1_input_i8.hex", np.asarray(ds1_in, dtype=np.int8))
        write_i8(out_dir / "ds12_stream_ds1_dw_output_i8.hex", np.asarray(ds1_dw, dtype=np.int8))
        write_i8(out_dir / "ds12_stream_ds1_output_i8.hex", ds1_out)
        write_i8(out_dir / "ds12_stream_ds2_input_i8.hex", ds1_out)
        write_i8(out_dir / "ds12_stream_ds2_dw_output_i8.hex", np.asarray(ds2_dw, dtype=np.int8))
        write_i8(out_dir / "ds12_stream_ds2_output_i8.hex", ds2_out)

        cfg_rows: list[dict[str, int | str]] = []
        config_counts: dict[int, int] = {}
        for layer in (1, 2):
            arrays: dict[str, list[int]] = {}
            for kind in PARAM_ORDER:
                data = params_for_layer(p, layer, kind)
                is_weight = kind.endswith("weight")
                arrays[kind] = pack_words(data, byte_values=is_weight)
                # Round-trip every packed value.  This is intentionally an
                # independent check instead of trusting the emitted text.
                if is_weight:
                    unpacked = [((word >> (8 * lane)) & 0xFF) for word in arrays[kind] for lane in range(4)]
                    expected_bytes = [int(value) & 0xFF for value in data]
                    if unpacked[: len(expected_bytes)] != expected_bytes or any(unpacked[len(expected_bytes) :]):
                        raise AssertionError(f"DS{layer} {kind} pack/unpack mismatch")
                else:
                    if arrays[kind] != [u32(value) for value in data]:
                        raise AssertionError(f"DS{layer} {kind} 32-bit pack mismatch")
            expected_count = sum(len(words) for words in arrays.values())
            config_counts[layer] = expected_count
            expected_words = {1: 308, 2: 872}[layer]
            if expected_count != expected_words:
                raise AssertionError(f"DS{layer} packed config count {expected_count} != {expected_words}")
            for kind in PARAM_ORDER:
                base = REGIONS[layer][kind]
                for index, word in enumerate(arrays[kind]):
                    cfg_rows.append({"layer": layer, "kind": kind, "index": index, "address": base + 4 * index, "byte_enable": 0xF, "data": word})
        write_cfg(out_dir / "ds12_stream_cfg_transactions.hex", cfg_rows, config_counts)
        for layer in (1, 2):
            write_i8(out_dir / f"ds12_stream_ds{layer}_dw_weight_i8.hex", p[f"ds{layer}_dw_weight"])
            write_i8(out_dir / f"ds12_stream_ds{layer}_pw_weight_i8.hex", p[f"ds{layer}_pw_weight"])

        sink_rows: list[dict[str, int]] = []
        sink_bases = {1: 0x00100000, 2: 0x00200000}
        outputs = {1: ds1_out, 2: ds2_out}
        layer_context_bases: dict[int, int] = {}
        global_context_ordinal = 0
        for layer in (1, 2):
            flat = outputs[layer].reshape(-1, LAYERS[layer]["out_c"])
            words_per_pixel = LAYERS[layer]["out_c"] // 4
            pixels = LAYERS[layer]["out_h"] * LAYERS[layer]["out_w"]
            layer_context_bases[layer] = global_context_ordinal
            if flat.shape != (pixels, LAYERS[layer]["out_c"]):
                raise AssertionError(f"DS{layer} output shape is not pixel-major")
            for pixel in range(pixels):
                # Owner/epoch are inference-global.  Thus DS2 cannot silently
                # reuse DS1's bank tag at the DS1->DS2 fence.
                context_ordinal = global_context_ordinal + pixel // 8
                owner = context_ordinal & 1
                epoch = context_ordinal >> 1
                context = context_ordinal & 3
                for word_in_pixel in range(words_per_pixel):
                    bytes4 = flat[pixel, word_in_pixel * 4 : word_in_pixel * 4 + 4].astype(np.int16).tolist()
                    data = sum((int(v) & 0xFF) << (8 * lane) for lane, v in enumerate(bytes4))
                    word_index = pixel * words_per_pixel + word_in_pixel
                    req = word_index
                    sink_rows.append({"layer": layer, "word_index": word_index, "address": sink_bases[layer] + 4 * word_index, "data": data, "byte_mask": 0xF, "owner": owner, "epoch": epoch, "context": context, "request_cycle": req, "response_cycle": req + 1})
            if len([r for r in sink_rows if r["layer"] == layer]) != pixels * words_per_pixel:
                raise AssertionError(f"DS{layer} sink word count mismatch")
            global_context_ordinal += pixels // 8
        write_sink(out_dir / "ds12_stream_sink_words.hex", sink_rows)

        # Transaction-level contract metadata consumed by both humans and
        # future adapters.  MAC counts are semantic, while stream counts are
        # the real macro ledger used by the current C10 admission screen.
        metadata: dict[str, Any] = {
            "schema": "ds12-stream-harness-v1",
            "status": "REFERENCE_PASS_DUT_DEFERRED",
            "source_npz": str(npz_path),
            "source_input": {"shape": list(image_i8.shape), "layout": "NHWC pixel-major signed int8", "zero_point": scalar(p, "input_zero_point"), "existing_vector": str(input_vector)},
            "reference": {
                "ds1_input_shape": list(np.asarray(ds1_in).shape), "ds1_dw_output_shape": [32, 32, 16], "ds1_output_shape": list(ds1_out.shape),
                "ds2_input_shape": list(ds1_out.shape), "ds2_dw_output_shape": [16, 16, 32], "ds2_output_shape": list(ds2_out.shape),
                "expected_logits": [int(x) for x in logits], "expected_argmax": int(argmax),
                "files": {"ds1_input": "ds12_stream_ds1_input_i8.hex", "ds1_dw_output": "ds12_stream_ds1_dw_output_i8.hex", "ds1_output": "ds12_stream_ds1_output_i8.hex", "ds2_input": "ds12_stream_ds2_input_i8.hex", "ds2_dw_output": "ds12_stream_ds2_dw_output_i8.hex", "ds2_output": "ds12_stream_ds2_output_i8.hex", "ds1_dw_weight": "ds12_stream_ds1_dw_weight_i8.hex", "ds1_pw_weight": "ds12_stream_ds1_pw_weight_i8.hex", "ds2_dw_weight": "ds12_stream_ds2_dw_weight_i8.hex", "ds2_pw_weight": "ds12_stream_ds2_pw_weight_i8.hex"},
            },
            "config": {"format": "little-endian packed INT8 words; quant arrays are 32-bit words", "byte_enable": "0xf for every complete word", "packer_round_trip": "checked for every source byte/word", "word_counts": {"DS1": config_counts[1], "DS2": config_counts[2]}, "regions": {f"DS{layer}": {kind: f"0x{REGIONS[layer][kind]:08x}" for kind in PARAM_ORDER} for layer in (1, 2)}, "transaction_file": "ds12_stream_cfg_transactions.hex"},
            "stream_contract": {"context_tags": 4, "pixels_per_context": 8, "response_delay_cycles": 1, "output_sink": "32-bit little-endian word with byte mask", "owner_rule": "owner=global_context_ordinal mod 2", "epoch_rule": "epoch=floor(global_context_ordinal/2)", "atomic_swap_rule": "owner/epoch change only after prior context's final sink word; DS2 continues after the DS1 fence", "layer_context_bases": {"DS1": layer_context_bases[1], "DS2": layer_context_bases[2]}, "sink_file": "ds12_stream_sink_words.hex"},
            "ledger": {
                "DS1": {"dw_mac": 32 * 32 * 16 * 9, "pw_mac": 32 * 32 * 16 * 32, "dw_beats": 4096, "dw_vectors": 1024, "dw_input_reads": 1024, "dw_padding_taps": 380, "pw_tokens": 8192, "output_words": 8192, "valid_output_bytes": 32768, "packed_config_words": config_counts[1]},
                "DS2": {"dw_mac": 16 * 16 * 32 * 9, "pw_mac": 16 * 16 * 32 * 64, "dw_beats": 2048, "pw_tokens": 8192, "output_words": 4096, "valid_output_bytes": 16384, "packed_config_words": config_counts[2]},
            },
            "dut_boundary": {"implemented": False, "required_action": "wire a candidate to ds12_stream_future_dut_if.v and run with DUT wiring enabled", "reference_checker_may_pass": True, "architecture_may_not_be_called_pass": True},
        }
        (out_dir / "ds12_stream_contract.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--npz", type=Path, default=ROOT / "build/c0_hwqa_export/edgedscnet_c10_int8_smoke.npz")
    parser.add_argument("--out", type=Path, default=ROOT / "build/ds12_stream_harness")
    parser.add_argument("--input-vector", type=Path, default=ROOT / "tests/vectors/training_smoke/input_image.hex")
    args = parser.parse_args()
    metadata = build_reference(args.npz, args.out, args.input_vector)
    print(json.dumps({"status": metadata["status"], "out": str(args.out), "DS1_config_words": 308, "DS2_config_words": 872, "DS1_output_bytes": metadata["ledger"]["DS1"]["valid_output_bytes"], "DS2_output_bytes": metadata["ledger"]["DS2"]["valid_output_bytes"]}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
