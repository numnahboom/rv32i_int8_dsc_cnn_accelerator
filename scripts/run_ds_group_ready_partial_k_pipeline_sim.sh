#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
run_case() {
  local fence="$1" cin="$2" pixels="$3" cout="$4"
  local obj="$root/build/verilator_ds_group_ready_partial_k_${fence}_${cin}_${pixels}_${cout}"
  mkdir -p "$obj"
  verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
    --top-module tb_ds_group_ready_partial_k_pipeline \
    -GTB_FENCE="$fence" -GTB_CIN="$cin" -GTB_PIXELS="$pixels" -GTB_COUT="$cout" \
    -f "$root/sim/filelist_ds_group_ready_partial_k_pipeline.f" \
    -Mdir "$obj" -o sim_group_ready
  "$obj/sim_group_ready"
}

# Same source/weight stream, with and without descriptor fence.
run_case 0 16 1 8
run_case 0 16 8 13
run_case 0 13 17 13
run_case 0 48 17 16
run_case 1 48 17 16
