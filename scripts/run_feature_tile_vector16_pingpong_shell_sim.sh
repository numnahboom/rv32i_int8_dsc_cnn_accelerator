#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_feature_tile_vector16_pingpong_shell"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --Wno-UNDRIVEN --timing --binary \
  -f sim/filelist_feature_tile_vector16_pingpong_shell.f \
  --top-module tb_feature_tile_vector16_pingpong_shell --Mdir "$obj"
"$obj/Vtb_feature_tile_vector16_pingpong_shell"
