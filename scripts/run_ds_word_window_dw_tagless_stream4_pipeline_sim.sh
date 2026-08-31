#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_ds_word_window_dw_tagless_stream4_pipeline"
rm -rf "$build"
mkdir -p "$build"
verilator --binary --timing --Wno-fatal -Wall \
  --top-module tb_ds_word_window_dw_tagless_stream4_pipeline \
  -f "$root/sim/filelist_ds_word_window_dw_tagless_stream4_pipeline.f" \
  -Mdir "$build" -o sim_ds_word_window_dw_tagless_stream4_pipeline
"$build/sim_ds_word_window_dw_tagless_stream4_pipeline"
