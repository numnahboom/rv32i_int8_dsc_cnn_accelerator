#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

build_root="${VERILATOR_BUILD_ROOT:-build}"
out="$build_root/verilator_cnn_top_fullnet_group_shared64_backpressure"
rm -rf "$out"
mkdir -p "$out"
obj="$out/obj_dir"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_cnn_top_fullnet_group_shared64_backpressure \
  -f sim/filelist_cnn_current.f \
  sim/tb_cnn_top_fullnet_sram_datapath.v \
  sim/tb_cnn_top_fullnet_group_shared64_backpressure.v \
  --Mdir "$obj" -o sim_cnn_top_fullnet_group_shared64_backpressure
"$obj/sim_cnn_top_fullnet_group_shared64_backpressure"
