#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for cin in 16 48 128; do
  for stride in 1 2; do
    build="$root/build/verilator_ds_word_window_dw_producer_c${cin}_s${stride}"
    rm -rf "$build"
    mkdir -p "$build"
    verilator --binary --timing --Wno-fatal -Wall \
      --top-module tb_ds_word_window_dw_producer_island \
      -GTB_CIN=$cin -GTB_STRIDE=$stride \
      -f "$root/sim/filelist_ds_word_window_dw_producer_island.f" \
      -Mdir "$build" -o sim_ds_word_window_dw_producer_island
    "$build/sim_ds_word_window_dw_producer_island"
  done
done
