#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_ds_rowlocal_4lane_feed_macro"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT \
  --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_ds_rowlocal_4lane_feed_macro \
  -f "$root/sim/filelist_ds_rowlocal_4lane_feed_macro.f" \
  -Mdir "$build" -o sim_ds_rowlocal_4lane_feed_macro
"$build/sim_ds_rowlocal_4lane_feed_macro"
