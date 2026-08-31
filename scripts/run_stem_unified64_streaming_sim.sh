#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_stem_unified64_streaming"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_stem_unified64_streaming \
  -f "$root/sim/filelist_stem_unified64_streaming.f" \
  -Mdir "$build" -o sim_stem_unified64_streaming
"$build/sim_stem_unified64_streaming"
