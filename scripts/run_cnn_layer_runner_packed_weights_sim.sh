#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
obj="$root/build/verilator_cnn_layer_runner_packed_weights"
mkdir -p "$obj"
verilator --binary --timing --top-module tb_cnn_layer_runner_packed_weights \
  --Mdir "$obj" --build-jobs 8 \
  -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNSIGNED \
  -f "$root/sim/filelist_cnn_layer_runner_packed_weights.f" \
  -o sim_packed_weights
"$obj/sim_packed_weights"
