#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --build-jobs 8 \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  --top-module tb_ds_word_window_dw_pw_pair_scratch_pipeline \
  -Mdir build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline \
  -f sim/filelist_ds_word_window_dw_pw_pair_scratch_pipeline.f
build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline/Vtb_ds_word_window_dw_pw_pair_scratch_pipeline
