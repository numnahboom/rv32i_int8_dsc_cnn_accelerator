#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build/firmware"

"$ROOT/scripts/build_firmware.sh"
python3 "$ROOT/rtl/npc/bin_to_rom_hex.py" "$OUT_DIR/cnn_demo.bin" "$OUT_DIR/rom.hex"

echo "wrote $OUT_DIR/rom.hex"
