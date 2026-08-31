#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
for cin in 3 16 48; do
  obj="$root/build/verilator/tb_ds_tile_dma_writer_c${cin}"
  rm -rf "$obj"
  verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
    --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
    -f sim/filelist_ds_tile_dma_writer.f --top-module tb_ds_tile_dma_writer \
    -GTEST_CIN="$cin" --Mdir "$obj"
  "$obj/Vtb_ds_tile_dma_writer"
done

# Explicit short unaligned tail: one valid byte starts in lane 3 and the
# extent crosses into a second word.  This catches end-exclusive lane-count
# mistakes that full-shape tests do not reach.
obj="$root/build/verilator/tb_ds_tile_dma_writer_edge"
rm -rf "$obj"
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  -f sim/filelist_ds_tile_dma_writer.f --top-module tb_ds_tile_dma_writer \
  -GTEST_CIN=3 -GTEST_EXTENT_OVERRIDE=5 -GTEST_BASE_OVERRIDE=3 --Mdir "$obj"
"$obj/Vtb_ds_tile_dma_writer"
