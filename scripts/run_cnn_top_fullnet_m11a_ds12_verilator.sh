#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

out="build/verilator_cnn_top_fullnet_m11a_ds12"
rm -rf "$out"
mkdir -p "$out"
obj="$out/obj_dir"
verilator --binary --timing --Wall --Wno-fatal \
  -DM11A_FULLNET_LEDGER \
  --top-module tb_cnn_top_fullnet_m11a_ds12 \
  -f sim/filelist_cnn_current.f \
  sim/tb_cnn_top_fullnet_sram_datapath.v \
  sim/tb_cnn_top_fullnet_m11a_ds12.v \
  --Mdir "$obj" -o sim_cnn_top_fullnet_m11a_ds12
"$obj/sim_cnn_top_fullnet_m11a_ds12"
