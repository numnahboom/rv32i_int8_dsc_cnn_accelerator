#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_cnn_layer_runner_unified64_ds_tiled"
mkdir -p "$obj"
verilator --binary --timing --top-module tb_cnn_layer_runner_unified64_ds_tiled \
  --Mdir "$obj" --build-jobs 8 \
  -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f "$root/sim/filelist_cnn_layer_runner_unified64_ds_tiled.f" \
  -o sim_cnn_layer_runner_unified64_ds_tiled
"$obj/sim_cnn_layer_runner_unified64_ds_tiled"
