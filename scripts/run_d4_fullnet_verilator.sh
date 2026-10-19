#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/verilator_d4_fullnet
logs="build/reports/d4_fullnet_${D4_RUN_TAG:-20261018}"
mkdir -p "$out" "$logs"
verilator --binary --build-jobs 8 --timing -Wall -Wno-fatal \
    --top-module tb_d4_fullnet rtl/cnn/d4_fullnet_top.sv sim/tb_d4_fullnet.sv \
    --Mdir "$out" -o sim_d4_fullnet > "$logs/compile.log" 2>&1
samples=(build/d4_fullnet_vectors/sample_[0-9]*)
if (( $# )); then samples=("$@"); fi
for sample in "${samples[@]}"; do
  tag="${sample##*/}"
  for mode in 0 1 2; do
    "$out/sim_d4_fullnet" +vectors="$sample" +mode="$mode" +epochs=2 > "$logs/${tag}_mode${mode}.log" 2>&1
    grep D4_FULLNET_PASS "$logs/${tag}_mode${mode}.log"
  done
done
