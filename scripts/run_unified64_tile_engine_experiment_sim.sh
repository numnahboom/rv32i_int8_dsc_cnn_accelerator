#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_unified64_tile_engine_experiment"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_unified64_tile_engine_experiment \
  -f "$root/sim/filelist_unified64_tile_engine_experiment.f" \
  -Mdir "$build" -o sim_unified64_tile_engine_experiment
"$build/sim_unified64_tile_engine_experiment"
