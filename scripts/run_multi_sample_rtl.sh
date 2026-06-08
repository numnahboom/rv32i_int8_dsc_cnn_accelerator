#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOP="tb_npc_rv_core_cnn_top_fullnet"
OBJ_DIR="$ROOT/build/verilator/$TOP"
WORK_DIR="${WORK_DIR:-$ROOT/build/multi_sample_rtl}"
CKPT="${CKPT:-$ROOT/build/model/edgedscnet_c10_torch_cifar10.npz}"
PYTHON_BIN="${PYTHON:-/mnt/d/Software/anaconda/python.exe}"
SAMPLES="${SAMPLES:-3}"
START_INDEX="${START_INDEX:-0}"

if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON:-python3}"
fi

to_python_path() {
  local path="$1"
  if [[ "$PYTHON_BIN" == *.exe ]]; then
    wslpath -w "$path"
  else
    printf "%s" "$path"
  fi
}

parse_metric() {
  local line="$1"
  local key="$2"
  printf "%s\n" "$line" | sed -n "s/.*${key}=\([^ ]*\).*/\1/p"
}

cd "$ROOT"
mkdir -p "$WORK_DIR"
summary="$WORK_DIR/summary.csv"
printf "sample_index,label,expected_argmax,rtl_argmax,cycles,status,result\n" > "$summary"

compiled=0
for ((n = 0; n < SAMPLES; n++)); do
  sample_index=$((START_INDEX + n))
  export_dir="$WORK_DIR/export_$sample_index"
  vectors_dir="$WORK_DIR/vectors_$sample_index"
  model_dir="$WORK_DIR/model_$sample_index"
  log_path="$WORK_DIR/rtl_sample_$sample_index.log"

  rm -rf "$export_dir" "$vectors_dir" "$model_dir"
  mkdir -p "$export_dir" "$vectors_dir" "$model_dir"

  "$PYTHON_BIN" python/quantize_export.py \
    --ckpt "$(to_python_path "$CKPT")" \
    --out "$(to_python_path "$export_dir")" \
    --vectors "$(to_python_path "$vectors_dir")" \
    --sample-index "$sample_index" \
    --accuracy-samples 0

  "$PYTHON_BIN" python/export_firmware_headers.py \
    --npz "$(to_python_path "$export_dir/edgedscnet_c10_int8_smoke.npz")" \
    --model-dir "$(to_python_path "$model_dir")"
  cp "$ROOT/sw/model/model_desc.h" "$model_dir/model_desc.h"

  expected_argmax_hex="$(tr -d '[:space:]' < "$vectors_dir/expected_argmax.hex")"
  expected_argmax=$((16#$expected_argmax_hex))
  label="$(sed -n 's/^selected_sample_label=//p' "$export_dir/model_export_summary.txt" | tr -d '\r')"

  run_args="+expected_logits_hex=$vectors_dir/expected_fullnet_logits.hex +expected_argmax_hex=$vectors_dir/expected_argmax.hex"
  if [[ "$compiled" -eq 0 ]]; then
    MODEL_INCLUDE_DIR="$model_dir" RUN_ARGS="$run_args" ./scripts/run_sim.sh "$TOP" | tee "$log_path"
    compiled=1
  else
    MODEL_INCLUDE_DIR="$model_dir" ./scripts/build_firmware_rom.sh >/dev/null
    "$OBJ_DIR/V$TOP" $run_args | tee "$log_path"
  fi

  pass_line="$(grep "PASS $TOP" "$log_path" | tail -1 || true)"
  if [[ -z "$pass_line" ]]; then
    printf "%s,%s,%s,,,%s,FAIL\n" "$sample_index" "$label" "$expected_argmax" "" >> "$summary"
    echo "FAIL sample_index=$sample_index; see $log_path" >&2
    exit 1
  fi

  cycles="$(parse_metric "$pass_line" "cycles")"
  status="$(parse_metric "$pass_line" "status")"
  rtl_argmax="$(parse_metric "$pass_line" "argmax")"
  printf "%s,%s,%s,%s,%s,%s,PASS\n" \
    "$sample_index" "$label" "$expected_argmax" "$rtl_argmax" "$cycles" "$status" >> "$summary"
done

cat "$summary"
