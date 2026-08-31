#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_dw_window_reuse_scheduler"
rm -rf "$build"
mkdir -p "$build"
verilator --binary --timing --Wno-fatal -Wall \
  --top-module tb_dw_window_reuse_scheduler \
  -f "$root/sim/filelist_dw_window_reuse_scheduler.f" \
  -Mdir "$build" -o sim_dw_window_reuse_scheduler
"$build/sim_dw_window_reuse_scheduler"
