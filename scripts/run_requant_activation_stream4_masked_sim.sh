#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/verilator_requant_activation_stream4_masked"
rm -rf "$build"
mkdir -p "$build"
cd "$root"
verilator --binary --timing --Wno-fatal -Wall \
  --Wno-DECLFILENAME --Wno-WIDTH --Wno-UNUSEDSIGNAL \
  --Wno-SIDEEFFECT --Wno-BLKSEQ \
  --top-module tb_requant_activation_stream4_masked \
  -f "$root/sim/filelist_requant_activation_stream4_masked.f" \
  -Mdir "$build" -o sim_requant_activation_stream4_masked
"$build/sim_requant_activation_stream4_masked"
