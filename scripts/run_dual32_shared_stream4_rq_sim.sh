#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_dual32_shared_stream4_rq"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_dual32_shared_stream4_rq \
  -f "$root/sim/filelist_dual32_shared_stream4_rq.f" \
  -Mdir "$build" -o sim_dual32_shared_stream4_rq --build-jobs 8
"$build/sim_dual32_shared_stream4_rq"
