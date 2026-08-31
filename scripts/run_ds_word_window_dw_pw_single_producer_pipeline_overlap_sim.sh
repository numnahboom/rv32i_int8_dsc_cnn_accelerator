#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_ds_word_window_dw_pw_single_producer_pipeline_overlap"
mkdir -p "$obj"
cd "$root"
verilator --binary --timing --Wno-fatal --build-jobs 8 \
  --top-module tb_ds_word_window_dw_pw_single_producer_pipeline_overlap \
  -f sim/filelist_ds_word_window_dw_pw_single_producer_pipeline_overlap.f \
  --Mdir "$obj" -o sim_overlap
"$obj/sim_overlap"
