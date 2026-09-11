#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

out="build/m11a_runner_adapter"
rm -rf "$out"
mkdir -p "$out"
obj="$out/verilator_obj"
verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_m11a_runner_adapter \
  --Mdir "$obj" -f sim/filelist_m11a_runner_adapter.f --exe --build
"$obj/Vtb_m11a_runner_adapter" "$@" | tee "$out/ds1.log"
if ! grep -q '^PASS tb_m11a_runner_adapter ' "$out/ds1.log"; then
  echo "M11A_RUNNER_ADAPTER_GATE_A_FAIL" >&2
  exit 1
fi
echo "M11A_RUNNER_ADAPTER_GATE_A_PASS"
