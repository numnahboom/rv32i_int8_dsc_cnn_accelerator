#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${DATA_DIR:-/mnt/d/Stuff/data}"
CKPT="${CKPT:-$ROOT/build/model/edgedscnet_c10_smoke.npz}"
EXPORT_DIR="${EXPORT_DIR:-$ROOT/build/model_export}"
VECTOR_DIR="${VECTOR_DIR:-$ROOT/tests/vectors/training_smoke}"
MODEL_DIR="${MODEL_DIR:-$ROOT/sw/model}"
PYTHON_BIN="${PYTHON:-python3}"

if ! "$PYTHON_BIN" -c "import numpy" >/dev/null 2>&1; then
  FALLBACK_PY="/mnt/d/Stuff/Documented/Model/.venv/python.exe"
  if [[ -x "$FALLBACK_PY" ]] && "$FALLBACK_PY" -c "import numpy" >/dev/null 2>&1; then
    PYTHON_BIN="$FALLBACK_PY"
  else
    echo "error: no Python with NumPy found. Set PYTHON=/path/to/python." >&2
    exit 1
  fi
fi

to_python_path() {
  local path="$1"
  if [[ "$PYTHON_BIN" == *.exe ]]; then
    wslpath -w "$path"
  else
    printf "%s" "$path"
  fi
}

cd "$ROOT"

"$PYTHON_BIN" python/train_edgedscnet_c10.py \
  --data "$(to_python_path "$DATA_DIR")" \
  --out "$(to_python_path "$CKPT")" \
  --backend auto \
  --epochs "${EPOCHS:-1}" \
  --max-samples "${MAX_SAMPLES:-256}" \
  --eval-samples "${EVAL_SAMPLES:-128}" \
  --batch-size "${BATCH_SIZE:-64}"

"$PYTHON_BIN" python/quantize_export.py \
  --ckpt "$(to_python_path "$CKPT")" \
  --out "$(to_python_path "$EXPORT_DIR")" \
  --vectors "$(to_python_path "$VECTOR_DIR")"

"$PYTHON_BIN" python/export_firmware_headers.py \
  --npz "$(to_python_path "$EXPORT_DIR/edgedscnet_c10_int8_smoke.npz")" \
  --model-dir "$(to_python_path "$MODEL_DIR")"

"$PYTHON_BIN" python/compare_outputs.py \
  "$(to_python_path "$VECTOR_DIR/expected_logits.hex")" \
  "$(to_python_path "$VECTOR_DIR/expected_fullnet_logits.hex")" \
  --bits 8

echo "wrote $EXPORT_DIR"
