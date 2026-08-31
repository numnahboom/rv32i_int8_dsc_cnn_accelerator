#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_ds_spatial_word_window_bank"
rm -rf "$build"
mkdir -p "$build"
verilator --binary --timing --Wno-fatal -Wall \
  --top-module tb_ds_spatial_word_window_bank \
  -f "$root/sim/filelist_ds_spatial_word_window_bank.f" \
  -Mdir "$build" -o sim_ds_spatial_word_window_bank
"$build/sim_ds_spatial_word_window_bank"
