#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for cin in 16 48 128; do
  obj="$root/build/verilator_dw_pw_pair_scratch_rowbank2_packed_consumer_timing_${cin}"
  mkdir -p "$obj"
  verilator --binary --timing --Wno-fatal --Wno-DECLFILENAME \
    --Wno-WIDTH --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ \
    --build-jobs 8 --top-module tb_dw_pw_pair_scratch_rowbank2_packed_consumer_timing \
    -GTB_CIN="$cin" -f "$root/sim/filelist_dw_pw_pair_scratch_rowbank2_packed_consumer_timing.f" \
    --Mdir "$obj" -o sim_timing
  "$obj/sim_timing"
done
