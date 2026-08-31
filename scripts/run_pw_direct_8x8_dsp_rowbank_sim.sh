#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_pw_direct_8x8_dsp_rowbank"
rm -rf "$build"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ --Wno-CASEINCOMPLETE \
  --top-module tb_pw_direct_8x8_dsp_rowbank \
  -f "$root/sim/filelist_pw_direct_8x8_dsp_rowbank.f" \
  -Mdir "$build" -o sim_pw_direct_8x8_dsp_rowbank
"$build/sim_pw_direct_8x8_dsp_rowbank"
