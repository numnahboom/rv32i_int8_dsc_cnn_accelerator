#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

out="build/bank_local_drain_gate_20260909"
report="build/reports/bank_local_drain_gate_20260909"
mkdir -p "$out/obj_dir" "$report"

verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_unified64_bank_local_drain_gate_20260909 \
  -f sim/filelist_unified64_bank_local_drain_gate_20260909.f \
  --Mdir "$out/obj_dir" -o sim_unified64_bank_local_drain_gate_20260909

"$out/obj_dir/sim_unified64_bank_local_drain_gate_20260909" \
  > "$report/run.log" 2>&1

echo "BANK_LOCAL_DRAIN_GATE_REPORT=$root/$report"
