#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator/tb_row_image_bram_store"
cd "$root"
rm -rf "$obj"
mkdir -p "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  -f sim/filelist_row_image_bram_store.f \
  --top-module tb_row_image_bram_store --Mdir "$obj"
"$obj/Vtb_row_image_bram_store"
