#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf}"
OUT_DIR="$ROOT/build/firmware"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
MODEL_INCLUDE_DIR="${MODEL_INCLUDE_DIR:-$ROOT/sw/model}"

mkdir -p "$OUT_DIR"

"$RISCV_PREFIX-gcc" \
  -march=rv32i \
  -mabi=ilp32 \
  $EXTRA_CFLAGS \
  -nostdlib \
  -nostartfiles \
  -T "$ROOT/sw/firmware/linker.ld" \
  -I "$ROOT/sw/firmware" \
  -I "$MODEL_INCLUDE_DIR" \
  -I "$ROOT/sw/model" \
  "$ROOT/sw/firmware/startup.S" \
  "$ROOT/sw/firmware/main.c" \
  "$ROOT/sw/firmware/cnn_accel.c" \
  -o "$OUT_DIR/cnn_demo.elf"

"$RISCV_PREFIX-objcopy" -O binary "$OUT_DIR/cnn_demo.elf" "$OUT_DIR/cnn_demo.bin"
echo "wrote $OUT_DIR/cnn_demo.elf"
