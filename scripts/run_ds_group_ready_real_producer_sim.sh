#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_ds_group_ready_real_producer"
mkdir -p "$obj"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_ds_group_ready_real_producer \
  -f "$root/sim/filelist_ds_group_ready_real_producer.f" \
  -Mdir "$obj" -o sim_real_producer
"$obj/sim_real_producer"
