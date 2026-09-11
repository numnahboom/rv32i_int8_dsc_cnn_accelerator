#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

build_root="${VERILATOR_BUILD_ROOT:-build}"
out="$build_root/dw_rq_local_profiler_20260909"
report="build/reports/dw_rq_local_profiler_20260909"
rm -rf "$out"
mkdir -p "$out/obj_dir" "$report"

verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909 \
  -f sim/filelist_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909.f \
  --Mdir "$out/obj_dir" -o sim_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909

"$out/obj_dir/sim_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909" \
  > "$report/run.log" 2>&1

{
  echo "manifest_version=1"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "top=tb_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909"
  echo "dut_harness=sim/tb_cnn_top_fullnet_sram_datapath.v"
  echo "profiler_wrapper=sim/tb_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909.v"
  echo "filelist=sim/filelist_cnn_top_fullnet_group_shared64_dw_rq_profiler_20260909.f"
  echo "vector_file=tests/vectors/cnn_top_fullnet_sram_cases.hex"
  echo "tool_verilator=$(verilator --version)"
  echo "causal_window_cycles=16"
  echo "output_profile=$report/adapter_profile.csv"
  echo "output_checks=$report/profiler_checks.txt"
  echo "output_log=$report/run.log"
} > "$report/manifest.txt"

echo "DW_RQ_PROFILER_REPORT=$root/$report"
