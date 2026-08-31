#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_feature_tile_word_feeder"
cd "$root"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --timing --binary -f sim/filelist_feature_tile_word_feeder.f \
  --top-module tb_feature_tile_word_feeder --Mdir "$obj"
"$obj/Vtb_feature_tile_word_feeder"
