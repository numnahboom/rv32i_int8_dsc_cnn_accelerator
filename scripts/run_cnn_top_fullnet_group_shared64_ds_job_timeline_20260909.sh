#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v verilator >/dev/null 2>&1; then
  echo "BLOCKED: verilator is required" >&2
  exit 2
fi

build_root="${VERILATOR_BUILD_ROOT:-build}"
out="$build_root/ds_job_timeline_20260909"
report="build/reports/ds_job_timeline_20260909"
rm -rf "$out"
mkdir -p "$out/obj_dir" "$report"

verilator --binary --timing --Wall --Wno-fatal \
  --top-module tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909 \
  -f sim/filelist_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.f \
  --Mdir "$out/obj_dir" -o sim_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909

"$out/obj_dir/sim_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909" \
  > "$report/run.log" 2>&1

{
  echo "manifest_version=1"
  echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "top=tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909"
  echo "dut_harness=sim/tb_cnn_top_fullnet_sram_datapath.v"
  echo "profiling_wrapper=sim/tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.v"
  echo "filelist=sim/filelist_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.f"
  echo "vector_file=tests/vectors/cnn_top_fullnet_sram_cases.hex"
  echo "tool_verilator=$(verilator --version)"
  echo "tool_gcc=$(g++ --version | head -n 1)"
  echo "command=verilator --binary --timing --Wall --Wno-fatal --top-module tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909 -f sim/filelist_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.f"
  echo "expected_layers=6"
  echo "expected_jobs=112"
  echo "expected_stream_beats=14336"
  echo "expected_dw_beats=14336"
  echo "expected_output_writes=21504"
  echo "expected_pw_tokens=73728"
  echo "expected_dw_macs=497664"
  echo "expected_pw_macs=4194304"
  echo "expected_network_mac=5136896"
  echo "expected_network_ops=10273792"
  echo "expected_exact_checks=10"
  echo "expected_hw_cycles=219970"
  echo "sha256_wrapper=$(sha256sum sim/tb_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.v | awk '{print $1}')"
  echo "sha256_filelist=$(sha256sum sim/filelist_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.f | awk '{print $1}')"
  echo "sha256_script=$(sha256sum scripts/run_cnn_top_fullnet_group_shared64_ds_job_timeline_20260909.sh | awk '{print $1}')"
  echo "sha256_vector=$(sha256sum tests/vectors/cnn_top_fullnet_sram_cases.hex | awk '{print $1}')"
  echo "output_profiler_checks=$report/profiler_checks.txt"
  echo "output_layer_timeline=$report/layer_timeline.csv"
  echo "output_job_timeline=$report/job_timeline.csv"
  echo "output_event_counts=$report/event_counts.csv"
  echo "output_run_log=$report/run.log"
} > "$report/manifest.txt"

echo "DS_JOB_TIMELINE_REPORT=$root/$report"
