#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/verilator_ds_word_window_dw_pw_single_producer_pipeline
verilator --Wall --Wno-fatal --Wno-DECLFILENAME --Wno-WIDTH --build-jobs 8 \
  --Wno-UNUSEDSIGNAL --Wno-SIDEEFFECT --Wno-BLKSEQ --timing --binary \
  --top-module tb_ds_word_window_dw_pw_single_producer_pipeline \
  -Mdir build/verilator_ds_word_window_dw_pw_single_producer_pipeline \
  -f sim/filelist_ds_word_window_dw_pw_single_producer_pipeline.f
build/verilator_ds_word_window_dw_pw_single_producer_pipeline/Vtb_ds_word_window_dw_pw_single_producer_pipeline
