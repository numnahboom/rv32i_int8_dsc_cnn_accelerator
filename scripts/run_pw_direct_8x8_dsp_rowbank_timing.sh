#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for cin in 16 48 128; do
  obj="$root/build/verilator_pw_direct_8x8_dsp_rowbank_timing_${cin}"
  mkdir -p "$obj"
  verilator --binary --timing --Wno-fatal --Wno-DECLFILENAME \
    --Wno-WIDTH --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ \
    --build-jobs 8 --top-module tb_pw_direct_8x8_dsp_rowbank_timing \
    -GTB_CIN="$cin" -f "$root/sim/filelist_pw_direct_8x8_dsp_rowbank_timing.f" \
    --Mdir "$obj" -o sim_timing
  "$obj/sim_timing"
done
