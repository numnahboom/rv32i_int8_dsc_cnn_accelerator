#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/ds12_stream_two_layer_top
mkdir -p "$OUT"
verilator --binary --timing --Wno-fatal --top-module tb_ds12_stream_two_layer_top -f sim/filelist_ds12_stream_two_layer_top.f --Mdir "$OUT/verilator" -o two_layer_tb
"$OUT/verilator/two_layer_tb"
