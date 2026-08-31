#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_cnn_fullnet_unified64_stem"
mkdir -p "$obj"
verilator --binary --timing --top-module tb_cnn_top_fullnet_sram_datapath \
  -GUSE_UNIFIED64_STEM=1 --Mdir "$obj" --build-jobs 8 \
  -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f "$root/sim/filelist_cnn_current.f" \
  "$root/sim/tb_cnn_top_fullnet_sram_datapath.v" \
  -o sim_cnn_fullnet_unified64_stem
"$obj/sim_cnn_fullnet_unified64_stem"
