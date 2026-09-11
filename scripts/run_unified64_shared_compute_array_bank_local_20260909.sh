#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

out="build/unified64_shared_compute_array_bank_local_20260909"
report="build/reports/unified64_shared_compute_array_bank_local_20260909"
mkdir -p "$out" "$report"

verilator --binary --timing --Wno-fatal -Wall --build-jobs 8 \
  --top-module tb_unified64_shared_compute_array_bank_local_20260909 \
  -f sim/filelist_unified64_shared_compute_array_bank_local_20260909.f \
  -Mdir "$out/obj_dir" -o sim_unified64_shared_compute_array_bank_local_20260909

"$out/obj_dir/sim_unified64_shared_compute_array_bank_local_20260909" \
  > "$report/run.log" 2>&1

echo "ARRAY_BANK_LOCAL_REPORT=$root/$report"
