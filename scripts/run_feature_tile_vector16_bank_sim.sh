#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_feature_tile_vector16_bank"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --timing --binary \
  -f sim/filelist_feature_tile_vector16_bank.f \
  --top-module tb_feature_tile_vector16_bank --Mdir "$obj"
"$obj/Vtb_feature_tile_vector16_bank"
