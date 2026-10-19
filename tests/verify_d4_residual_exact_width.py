#!/usr/bin/env python3
"""Prove the lossless 9-bit residual-ROM and 10-bit sum representation."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def signed(value: int, width: int) -> int:
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


def read_hex_words(path: Path) -> list[int]:
    return [int(line.strip(), 16) for line in path.read_text(encoding="ascii").splitlines()
            if line.strip() and not line.lstrip().startswith("//")]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("vectors", type=Path, help="frozen D4 vector directory")
    parser.add_argument("--report", type=Path, help="write machine-readable proof details")
    args = parser.parse_args()

    vectors = args.vectors
    lut_path = vectors / "residual_lut.mem"
    descriptor_path = vectors / "descriptors.mem"
    lut_words = read_hex_words(lut_path)
    assert len(lut_words) == 3584, f"expected 3584 LUT words, got {len(lut_words)}"
    values = [signed(word, 32) for word in lut_words]
    narrow_values = [signed(word, 9) for word in lut_words]
    assert all(value == narrow for value, narrow in zip(values, narrow_values)), \
        "a residual word changes when stored as signed 9-bit"
    assert min(values) >= -256 and max(values) <= 255

    descriptors = read_hex_words(descriptor_path)
    assert len(descriptors) == 41 * 32, f"expected 1312 descriptor words, got {len(descriptors)}"
    adds = []
    for op in range(41):
        base = op * 32
        if descriptors[base] & 0x3 != 1:
            continue
        a_base = descriptors[base + 16] & 0xFFF
        b_base = descriptors[base + 17] & 0xFFF
        for branch, branch_base in (("a", a_base), ("b", b_base)):
            assert branch_base + 255 < len(values), (
                f"ADD op {op} branch {branch}: [{branch_base}, {branch_base + 255}] "
                f"exceeds {len(values)} entries"
            )

        a_values = values[a_base:a_base + 256]
        b_values = values[b_base:b_base + 256]
        pair_count = 0
        sum_min = 1 << 31
        sum_max = -(1 << 31)
        for a in a_values:
            for b in b_values:
                # Independent 32-bit reference, followed by the RTL's signed
                # 10-bit representation and signed 8-bit saturating reference.
                reference32 = signed(((a & 0xFFFFFFFF) + (b & 0xFFFFFFFF)), 32)
                assert reference32 == a + b
                narrow_sum = signed(reference32 & 0x3FF, 10)
                assert narrow_sum == reference32, (
                    f"ADD op {op}: 10-bit sum changed {a}+{b}={reference32}"
                )
                expected_sat = max(-128, min(127, reference32))
                got_sat = signed(narrow_sum & 0xFF, 8) if -128 <= narrow_sum <= 127 \
                    else (127 if narrow_sum > 127 else -128)
                assert got_sat == expected_sat
                pair_count += 1
                sum_min = min(sum_min, reference32)
                sum_max = max(sum_max, reference32)
        adds.append({
            "op": op,
            "lut_a_base": a_base,
            "lut_a_range": [a_base, a_base + 255],
            "lut_b_base": b_base,
            "lut_b_range": [b_base, b_base + 255],
            "exhaustive_branch_pairs": pair_count,
            "sum_range": [sum_min, sum_max],
        })

    assert adds, "no residual ADD descriptors found"
    report = {
        "status": "PASS",
        "lut": {
            "path": str(lut_path),
            "sha256": hashlib.sha256(lut_path.read_bytes()).hexdigest(),
            "entries": len(values),
            "signed32_range": [min(values), max(values)],
            "signed9_range": [min(narrow_values), max(narrow_values)],
            "exact_signed9_sign_extensions": len(values),
        },
        "arithmetic": {
            "signed10_range": [-512, 511],
            "full_table_pair_sum_range": [2 * min(values), 2 * max(values)],
            "all_add_bases_and_256_offsets_in_range": True,
            "exhaustive_add_branch_pairs_checked": sum(item["exhaustive_branch_pairs"] for item in adds),
            "independent_signed32_and_saturate8_checks": "PASS",
        },
        "adds": adds,
    }
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": report["status"],
        "entries": len(values),
        "value_range": report["lut"]["signed32_range"],
        "add_ops": len(adds),
        "exhaustive_pairs": report["arithmetic"]["exhaustive_add_branch_pairs_checked"],
        "report": str(args.report) if args.report else None,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
