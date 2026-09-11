#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_ds_group_published_shared64_runner_adapter_exact"
rm -rf "$obj"
mkdir -p "$obj"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_ds_group_published_shared64_runner_adapter_exact \
  -f "$root/sim/filelist_ds_group_published_shared64_runner_adapter_exact.f" \
  -Mdir "$obj" -o sim_ds_group_published_shared64_runner_adapter_exact
"$obj/sim_ds_group_published_shared64_runner_adapter_exact"
