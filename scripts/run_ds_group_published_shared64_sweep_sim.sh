#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_ds_group_published_shared64_sweep"
mkdir -p "$obj"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_ds_group_published_shared64_sweep \
  -f "$root/sim/filelist_ds_group_published_shared64_sweep.f" \
  -Mdir "$obj" -o sim_ds_group_published_shared64_sweep
"$obj/sim_ds_group_published_shared64_sweep"
