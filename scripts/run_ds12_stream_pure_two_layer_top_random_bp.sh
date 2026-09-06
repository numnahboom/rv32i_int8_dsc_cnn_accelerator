#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/ds12_stream_pure_two_layer_top_random_bp
mkdir -p "$out"
verilator --binary --timing -DTB_RANDOM_BP --Wno-fatal --top-module tb_ds12_stream_pure_two_layer_top -f sim/filelist_ds12_stream_pure_two_layer_top.f --Mdir "$out/verilator" -o pure_two_layer_tb
"$out/verilator/pure_two_layer_tb"
