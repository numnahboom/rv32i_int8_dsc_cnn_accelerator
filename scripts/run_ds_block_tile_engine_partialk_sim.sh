#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_ds_block_tile_engine_partialk"
mkdir -p "$obj"
verilator --binary --timing --trace --top-module tb_ds_block_tile_engine_partialk \
  --Mdir "$obj" --build-jobs 8 \
  -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f "$root/sim/filelist_ds_block_tile_engine_partialk.f" \
  -o sim_ds_block_tile_engine_partialk
"$obj/sim_ds_block_tile_engine_partialk"
