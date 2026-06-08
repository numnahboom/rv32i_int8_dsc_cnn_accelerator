import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Convert little-endian RV32 binary to rom.hex.")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    if len(data) % 4 != 0:
        data += bytes(4 - (len(data) % 4))

    lines = []
    for i in range(0, len(data), 4):
        word = int.from_bytes(data[i:i + 4], byteorder="little", signed=False)
        lines.append(f"{word:08x}")

    args.output.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
