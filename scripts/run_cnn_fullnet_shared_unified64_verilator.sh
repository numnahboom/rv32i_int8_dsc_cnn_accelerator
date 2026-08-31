#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_cnn_fullnet_shared_unified64"
mkdir -p "$obj"
verilator --binary --timing --top-module tb_cnn_top_fullnet_sram_datapath \
  -DDEBUG_SHARED_FULLNET \
  -GUSE_SHARED_UNIFIED64=1 -GUSE_UNIFIED64_STEM=0 -GUSE_UNIFIED64_DS=0 \
  --Mdir "$obj" --build-jobs 8 -Wno-fatal -Wno-DECLFILENAME \
  -Wno-WIDTH -Wno-UNSIGNED -f "$root/sim/filelist_cnn_current.f" \
  "$root/sim/tb_cnn_top_fullnet_sram_datapath.v" \
  -o sim_cnn_fullnet_shared_unified64
"$obj/sim_cnn_fullnet_shared_unified64"
