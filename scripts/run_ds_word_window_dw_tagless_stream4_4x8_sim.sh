#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

run_case() {
  local cin="$1" stride="$2" tail="${3:-0}"
  local build="$root/build/verilator_ds_word_window_dw_tagless_stream4_4x8_${cin}_${stride}"
  rm -rf "$build"
  mkdir -p "$build"
  verilator --binary --timing --Wno-fatal -Wall \
    --top-module tb_ds_word_window_dw_tagless_stream4_4x8 \
    -GTB_CIN="$cin" -GTB_STRIDE="$stride" -GTB_TAIL="$tail" \
    -f "$root/sim/filelist_ds_word_window_dw_tagless_stream4_4x8.f" \
    -Mdir "$build" -o sim_4x8
  "$build/sim_4x8"
}

for cin in 16 48 128; do
  run_case "$cin" 1
  run_case "$cin" 2
done
run_case 48 1 1
