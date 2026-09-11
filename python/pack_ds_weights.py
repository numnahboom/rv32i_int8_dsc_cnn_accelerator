#!/usr/bin/env python3
"""Pack real DS INT8 weight streams into little-endian 32-bit words.

The runner's packed descriptor flag (word 18, bit 7) makes word 3 the DW
packed-byte base and word 7 the PW packed-byte base.  DW values are laid out
channel-major (C * 9 taps); PW values are output-channel-major (Cout * Cin).
The final word is zero padded, while hardware byte-enables keep those padding
bytes out of the weight store.

Example:
  python python/pack_ds_weights.py --dw dw_i8.txt --pw pw_i8.txt \
      --output ds_weights.hex --dw-base 0x3000 --pw-base 0x7000

Each input file contains one signed decimal or hexadecimal byte per line (or
whitespace-separated).  Output lines are ``byte_address 32bit_word``.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def read_values(path: Path) -> list[int]:
    values: list[int] = []
    for token in path.read_text(encoding="utf-8").replace(",", " ").split():
        value = int(token, 0)
        if not -128 <= value <= 255:
            raise ValueError(f"{path}: value {value} is outside INT8/byte range")
        values.append(value & 0xFF)
    return values


def pack_words(values: list[int]) -> list[int]:
    words: list[int] = []
    for offset in range(0, len(values), 4):
        word = 0
        for lane, value in enumerate(values[offset : offset + 4]):
            word |= value << (8 * lane)
        words.append(word)
    return words


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dw", type=Path, required=True, help="DW INT8 stream")
    parser.add_argument("--pw", type=Path, required=True, help="PW INT8 stream")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dw-base", type=lambda x: int(x, 0), default=0x3000)
    parser.add_argument("--pw-base", type=lambda x: int(x, 0), default=0x7000)
    args = parser.parse_args()

    dw = read_values(args.dw)
    pw = read_values(args.pw)
    dw_words = pack_words(dw)
    pw_words = pack_words(pw)
    lines = [
        f"# DW bytes={len(dw)} words={len(dw_words)} base=0x{args.dw_base:08x}",
        *(
            f"0x{args.dw_base + 4 * i:08x} 0x{word:08x}"
            for i, word in enumerate(dw_words)
        ),
        f"# PW bytes={len(pw)} words={len(pw_words)} base=0x{args.pw_base:08x}",
        *(
            f"0x{args.pw_base + 4 * i:08x} 0x{word:08x}"
            for i, word in enumerate(pw_words)
        ),
    ]
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"DW: {len(dw)} bytes -> {len(dw_words)} words")
    print(f"PW: {len(pw)} bytes -> {len(pw_words)} words")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
