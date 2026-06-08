#!/usr/bin/env python3
"""Compare hex output files and report mismatch locations."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_hex_file(path: Path, bits: int) -> list[int]:
    values: list[int] = []
    mask = (1 << bits) - 1
    sign = 1 << (bits - 1)
    with path.open("r", encoding="ascii") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            token = line.split()[0]
            if token.lower().startswith("0x"):
                token = token[2:]
            try:
                raw = int(token, 16) & mask
            except ValueError as exc:
                raise ValueError(f"{path}:{line_no}: invalid hex token {token!r}") from exc
            values.append(raw - (1 << bits) if raw & sign else raw)
    return values


def compare(expected: list[int], actual: list[int], max_mismatches: int) -> int:
    errors = 0
    common = min(len(expected), len(actual))
    for idx in range(common):
        if expected[idx] != actual[idx]:
            if errors < max_mismatches:
                print(f"mismatch index={idx} expected={expected[idx]} actual={actual[idx]}")
            errors += 1

    if len(expected) != len(actual):
        print(f"length mismatch expected={len(expected)} actual={len(actual)}")
        errors += abs(len(expected) - len(actual))

    if errors == 0:
        print(f"PASS compare_outputs count={len(expected)}")
        return 0

    print(f"FAIL compare_outputs mismatches={errors}")
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--bits", type=int, default=8, choices=(8, 16, 32))
    parser.add_argument("--max-mismatches", type=int, default=16)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    expected = parse_hex_file(args.expected, args.bits)
    actual = parse_hex_file(args.actual, args.bits)
    return compare(expected, actual, args.max_mismatches)


if __name__ == "__main__":
    raise SystemExit(main())
