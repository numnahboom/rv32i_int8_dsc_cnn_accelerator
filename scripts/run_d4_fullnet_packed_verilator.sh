#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/verilator_d4_fullnet_packed
logs="build/reports/d4_fullnet_${D4_RUN_TAG:-affine_packed_20261018}"
mkdir -p "$out" "$logs"
verilator --binary --build-jobs 8 --timing -Wall -Wno-fatal \
    --top-module tb_d4_fullnet_packed rtl/cnn/d4_fullnet_clocking.sv \
    rtl/cnn/d4_fullnet_top.sv \
    rtl/cnn/d4_fullnet_impl_top.sv sim/tb_d4_fullnet_packed.sv \
    --Mdir "$out" -o sim_d4_fullnet_packed > "$logs/compile.log" 2>&1
samples=(build/d4_fullnet_vectors/sample_*)
if (( $# )); then samples=("$@"); fi
pass_count=0
for sample in "${samples[@]}"; do
  tag="${sample##*/}"
  for mode in 0 1 2; do
    "$out/sim_d4_fullnet_packed" +vectors="$sample" +mode="$mode" +epochs=2 > "$logs/${tag}_mode${mode}.log" 2>&1
    count=$(grep -c '^D4_PACKED_FULLNET_PASS' "$logs/${tag}_mode${mode}.log")
    [[ "$count" -eq 2 ]]
    pass_count=$((pass_count + count))
  done
done
"$out/sim_d4_fullnet_packed" +mode=0 +control_probe > "$logs/control_probe.log" 2>&1
control_count=$(grep -c '^D4_PACKED_FULLNET_PASS' "$logs/control_probe.log")
[[ "$control_count" -eq 2 ]]
"$out/sim_d4_fullnet_packed" +mode=0 +epochs=3 +throughput > "$logs/throughput.log" 2>&1
expected_count=$((${#samples[@]} * 6))
[[ "$pass_count" -eq "$expected_count" ]]
interval_count=$(grep -Ec '^D4_PACKED_START_INTERVAL cycles=[0-9]+$' "$logs/throughput.log")
[[ "$interval_count" -eq 2 ]]
# The testbench independently requires interval == measured latency + 2.
grep '^D4_PACKED_START_INTERVAL' "$logs/throughput.log"
echo "PASS D4_PACKED_REGRESSION samples=${#samples[@]} mode_runs=$pass_count control_probe=$control_count tight_intervals=$interval_count"
