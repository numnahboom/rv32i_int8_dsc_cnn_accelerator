#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

run_case() {
  local cin="$1"
  local stride="$2"
  local build="$root/build/verilator_ds_word_window_dw_producer_island_quadlocal_${cin}_${stride}"
  rm -rf "$build"
  mkdir -p "$build"
  verilator --binary --timing --Wno-fatal -Wall \
    --top-module tb_ds_word_window_dw_producer_island_quadlocal \
    -GTB_CIN="$cin" -GTB_STRIDE="$stride" \
    -f "$root/sim/filelist_ds_word_window_dw_producer_island_quadlocal.f" \
    -Mdir "$build" -o sim_quadlocal
  "$build/sim_quadlocal"
}

run_case 16 1
run_case 48 1
run_case 48 2
