#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline_ds1
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --build-jobs 8 \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  --top-module tb_ds_word_window_dw_pw_pair_scratch_pipeline_ds1 \
  -Mdir build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline_ds1 \
  -f sim/filelist_ds_word_window_dw_pw_pair_scratch_pipeline_ds1.f
build/verilator_ds_word_window_dw_pw_pair_scratch_pipeline_ds1/Vtb_ds_word_window_dw_pw_pair_scratch_pipeline_ds1
