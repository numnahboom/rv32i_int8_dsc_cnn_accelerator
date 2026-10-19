#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/verilator_d4_fullnet_trace
logs="build/reports/d4_fullnet_${D4_RUN_TAG:-cursor_20261018}"
mkdir -p "$out" "$logs"
verilator --binary --build-jobs 8 --timing -Wall -Wno-fatal \
    --trace --trace-depth 2 --trace-max-array 32 \
    --top-module tb_d4_fullnet rtl/cnn/d4_fullnet_top.sv sim/tb_d4_fullnet.sv \
    --Mdir "$out" -o sim_d4_fullnet_trace > "$logs/trace_compile.log" 2>&1
"$out/sim_d4_fullnet_trace" +mode=0 +epochs=1 \
    +vcd="$logs/inference.vcd" > "$logs/trace_sim.log" 2>&1
grep D4_FULLNET_PASS "$logs/trace_sim.log"
