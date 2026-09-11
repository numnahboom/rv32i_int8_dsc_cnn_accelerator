#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
obj="$root/build/verilator_dense128_os_8x16"
mkdir -p "$obj"
cd "$root"
verilator --timing --binary -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
  -Irtl/common -Irtl/cnn \
  -f sim/filelist_dense128_os_8x16.f sim/tb_dense128_os_8x16.v \
  --top-module tb_dense128_os_8x16 \
  --Mdir "$obj" -o sim_dense128_os_8x16
"$obj/sim_dense128_os_8x16"
