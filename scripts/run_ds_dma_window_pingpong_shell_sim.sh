#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
for cin in 16 48; do
  build="$root/build/verilator_ds_dma_window_pingpong_c${cin}"
  rm -rf "$build"
  mkdir -p "$build"
  verilator --binary --timing --Wno-fatal -Wall \
    --top-module tb_ds_dma_window_pingpong_shell \
    -GTB_LAYOUT_CIN=$cin \
    -f "$root/sim/filelist_ds_dma_window_pingpong_shell.f" \
    -Mdir "$build" -o sim_ds_dma_window_pingpong_shell
  "$build/sim_ds_dma_window_pingpong_shell"
done
