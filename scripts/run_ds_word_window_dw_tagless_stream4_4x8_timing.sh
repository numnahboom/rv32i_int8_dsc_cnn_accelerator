#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for stride in 1 2; do
  obj="$root/build/verilator_ds_word_window_dw_tagless_stream4_4x8_timing_${stride}"
  mkdir -p "$obj"
  verilator --binary --timing --Wno-fatal --Wno-DECLFILENAME \
    --Wno-WIDTH --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ \
    --build-jobs 8 --top-module tb_ds_word_window_dw_tagless_stream4_4x8_timing \
    -GTB_STRIDE="$stride" -f "$root/sim/filelist_ds_word_window_dw_tagless_stream4_4x8_timing.f" \
    --Mdir "$obj" -o sim_timing
  "$obj/sim_timing"
done
