#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
command -v verilator >/dev/null 2>&1 || { echo 'BLOCKED: verilator is required' >&2; exit 2; }
out="build/ds12_stream_activation_banks"
obj="$out/verilator"
mkdir -p "$out"
rm -rf "$obj"
verilator --binary --timing --Wall --Wno-fatal --top-module tb_ds12_stream_activation_banks \
  --Mdir "$obj" -f sim/filelist_ds12_stream_activation_banks.f --exe --build \
  2>&1 | tee "$out/verilator_build.log"
"$obj/Vtb_ds12_stream_activation_banks" 2>&1 | tee "$out/run.log"
grep -q '^PASS ds12_stream_activation_banks ' "$out/run.log"
echo "PASS report=$out/run.log"
