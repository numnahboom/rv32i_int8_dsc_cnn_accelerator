#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_pw_systolic_array_8x8_partial_k_random"
mkdir -p "$obj"
cd "$root"
verilator --timing --binary -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
  -Irtl/common -Irtl/cnn \
  -f sim/filelist_pw_systolic_array_8x8_partial_k_random.f \
  sim/tb_pw_systolic_array_8x8_partial_k_random.v \
  --top-module tb_pw_systolic_array_8x8_partial_k_random \
  --Mdir "$obj" -o sim_pw_systolic_array_8x8_partial_k_random
"$obj/sim_pw_systolic_array_8x8_partial_k_random" "$@"
