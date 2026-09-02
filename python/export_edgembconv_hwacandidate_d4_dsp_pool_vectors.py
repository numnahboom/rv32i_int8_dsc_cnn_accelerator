#!/usr/bin/env python3
"""Export independent D4 vectors for the shared 16-DSP primitive.

PW records are taken from the already exported, real D4 dense128 tile traces
(official CIFAR-10 test-image activations and deployment weights).  RQ records
use raw D4 depthwise accumulators and real per-channel multipliers from the
deployment archive, plus signed INT32 boundary records and the two audited
mb32 residual coefficients.  The output directory is intentionally separate
from every C0 and existing D4 artifact directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEPLOY = ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy"
DEFAULT_DENSE = ROOT / "build/edgembconv_hwacandidate_d4_dense128_vectors"
DEFAULT_DW = ROOT / "build/edgembconv_hwacandidate_d4_dw16_stream_vectors"
DEFAULT_OUT = ROOT / "build/edgembconv_hwacandidate_d4_dsp_pool_vectors"

MASK32 = (1 << 32) - 1


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def signed(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def pack(values: list[int], bits: int) -> int:
    mask = (1 << bits) - 1
    return sum((int(v) & mask) << (i * bits) for i, v in enumerate(values))


def hex_word(value: int, bits: int) -> str:
    return f"{int(value) & ((1 << bits) - 1):0{(bits + 3) // 4}x}"


def round_away(product: int, shift: int) -> int:
    if shift == 0:
        return product
    magnitude = abs(int(product))
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return -rounded if product < 0 else rounded


def quant(product: int, shift: int, zero_point: int,
          minimum: int, maximum: int) -> int:
    value = round_away(product, shift) + int(zero_point)
    value = max(-128, min(127, value))
    return max(int(minimum), min(int(maximum), value))


def read_words(path: Path, width: int) -> list[int]:
    return [int(line.strip(), 16) for line in path.read_text(encoding="ascii").splitlines() if line.strip()]


def make_pw_records() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    # The dense128 exporter emits 8 pixels and 16 output weights per K token.
    # Pair two real K tokens to create the 16 physical independent PW lanes.
    for name in ("d4_dense128_mb32_expand_tokens.mem",
                 "d4_dense128_mb16_1_expand_tokens.mem"):
        tokens = read_words(DEFAULT_DENSE / name, 258)
        if len(tokens) < 2:
            raise ValueError(f"not enough real tokens in {name}")
        acts: list[int] = []
        wgts: list[int] = []
        for token in tokens[:2]:
            acts.extend(signed((token >> (8 * p)) & 0xff, 8) for p in range(8))
            wgts.extend(signed((token >> (64 + 8 * p)) & 0xff, 8) for p in range(8))
        products = [a * w for a, w in zip(acts, wgts)]
        records.append({
            "source": name, "act": acts, "wgt": wgts, "products": products,
            "metadata": 0xD4000000 | (0 if "mb32" in name else 1),
        })
    # Add an all-lane signed edge record to prove the INT8 operand contract.
    acts = [(-128 if i & 1 else 127) for i in range(16)]
    wgts = [(127 if i & 1 else -128) for i in range(16)]
    records.append({"source": "int8_boundary", "act": acts, "wgt": wgts,
                    "products": [a * w for a, w in zip(acts, wgts)],
                    "metadata": 0xD4EE0000})
    return records


def make_rq_records() -> list[dict[str, object]]:
    archive = DEFAULT_DEPLOY / "edgembconv_hwacandidate_d4_int8.npz"
    params = np.load(archive)
    raw_lines = read_words(DEFAULT_DW / "mb32_stride1_dw16_raw_psum.mem", 16 * 32)
    # The DW exporter stores sixteen signed INT32 values per output pixel.
    raw = [signed((raw_lines[0] >> (32 * i)) & MASK32, 32) for i in range(16)]
    real_mul = [int(v) for v in params["mb32.spatial.multiplier"][:16]]
    records: list[dict[str, object]] = []

    def append(acc: list[int], mul: list[int], shifts: list[int], zps: list[int],
               mins: list[int], maxs: list[int], source: str) -> None:
        result = [quant(a * m, s, z, mn, mx)
                  for a, m, s, z, mn, mx in zip(acc, mul, shifts, zps, mins, maxs)]
        records.append({"source": source, "acc": acc, "multiplier": mul,
                        "shift": shifts, "zero_point": zps, "minimum": mins,
                        "maximum": maxs,
                        "product": [a * m for a, m in zip(acc, mul)],
                        "result": result})

    append(raw[:4], real_mul[:4], [31] * 4, [0] * 4, [0] * 4, [127] * 4,
           "real_mb32_spatial_raw_psum_and_multiplier")
    append(raw[4:8], real_mul[4:8], [31] * 4, [0] * 4, [0] * 4, [127] * 4,
           "real_mb32_spatial_channels_4_7")
    append([-2**31, 2**31 - 1, -1, 1], real_mul[8:12], [31] * 4,
           [0] * 4, [-128] * 4, [127] * 4, "int32_boundary_real_multipliers")
    # These are the audited D4 mb32 residual coefficients (shift 30), not
    # guessed layer constants.  Using both coefficients in one record catches
    # sign/shift metadata lane swaps.
    residual_mul = [678_924_505, 689_501_486, 678_924_505, 689_501_486]
    append([-2**31, -123456789, 123456789, 2**31 - 1], residual_mul,
           [30] * 4, [0] * 4, [-128] * 4, [127] * 4,
           "mb32_residual_a_b_coefficients_shift30")
    append([raw[8], raw[9], raw[10], raw[11]],
           [int(v) for v in params["mb16_down.spatial.multiplier"][:4]],
           [31] * 4, [0] * 4, [0] * 4, [127] * 4,
           "real_mb16_down_spatial_channels")
    return records


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    pw = make_pw_records()
    rq = make_rq_records()

    pw_files: dict[str, str] = {}
    for key, bits, values in (
        ("act", 128, [pack(r["act"], 8) for r in pw]),
        ("wgt", 128, [pack(r["wgt"], 8) for r in pw]),
        ("expected", 256, [pack(r["products"], 16) for r in pw]),
        ("metadata", 32, [int(r["metadata"]) for r in pw]),
    ):
        name = f"d4_dsp_pool_pw_{key}.mem"
        (args.out / name).write_text("\n".join(hex_word(v, bits) for v in values) + "\n", encoding="ascii")
        pw_files[key] = name

    rq_files: dict[str, str] = {}
    specs = (
        ("acc", 128, [pack(r["acc"], 32) for r in rq]),
        ("multiplier", 128, [pack(r["multiplier"], 32) for r in rq]),
        ("shift", 24, [pack(r["shift"], 6) for r in rq]),
        ("zero_point", 128, [pack(r["zero_point"], 32) for r in rq]),
        ("minimum", 128, [pack(r["minimum"], 32) for r in rq]),
        ("maximum", 128, [pack(r["maximum"], 32) for r in rq]),
        ("product", 256, [pack(r["product"], 64) for r in rq]),
        ("expected", 32, [pack(r["result"], 8) for r in rq]),
    )
    for key, bits, values in specs:
        name = f"d4_dsp_pool_rq_{key}.mem"
        (args.out / name).write_text("\n".join(hex_word(v, bits) for v in values) + "\n", encoding="ascii")
        rq_files[key] = name

    source_files = [DEFAULT_DEPLOY / "edgembconv_hwacandidate_d4_int8.npz",
                    DEFAULT_DENSE / "d4_dense128_mb32_expand_tokens.mem",
                    DEFAULT_DENSE / "d4_dense128_mb16_1_expand_tokens.mem",
                    DEFAULT_DW / "mb32_stride1_dw16_raw_psum.mem"]
    manifest = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-dsp-pool-v1",
        "primitive": "edgembconv_hwacandidate_d4_dsp_pool",
        "physical_dsp_count": 16,
        "pw_records": len(pw), "rq_records": len(rq),
        "source_sha256": {str(p.relative_to(ROOT)).replace("\\", "/"): sha256(p)
                          for p in source_files},
        "pw_records_meta": [{"source": r["source"], "metadata": r["metadata"]} for r in pw],
        "rq_records_meta": [{"source": r["source"], "shift": r["shift"],
                             "multiplier": r["multiplier"]} for r in rq],
        "files": {"pw": pw_files, "rq": rq_files},
        "contract": {"rq": "signed int32 x signed int32, nearest-away-from-zero, variable shift, int8 saturation",
                     "mode_boundary": "ready_in remains low while a result is blocked; mode is captured per accepted transaction"},
    }
    (args.out / "d4_dsp_pool_vector_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "out": str(args.out),
                      "physical_dsp_count": 16, "pw_records": len(pw), "rq_records": len(rq)}, indent=2))


if __name__ == "__main__":
    main()
