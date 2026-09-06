#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
command -v verilator >/dev/null 2>&1 || { echo 'BLOCKED: verilator is required' >&2; exit 2; }
out="build/ds12_stream_dual_vector_activation_store"
obj="$out/verilator"
mkdir -p "$out"
rm -rf "$obj"
verilator --binary --timing --Wall --Wno-fatal --top-module tb_ds12_stream_dual_vector_activation_store \
  --Mdir "$obj" -f sim/filelist_ds12_stream_dual_vector_activation_store.f --exe --build \
  2>&1 | tee "$out/verilator_build.log"
"$obj/Vtb_ds12_stream_dual_vector_activation_store" 2>&1 | tee "$out/run.log"
grep -q '^PASS ds12_stream_dual_vector_activation_store ' "$out/run.log"
echo "PASS report=$out/run.log"
