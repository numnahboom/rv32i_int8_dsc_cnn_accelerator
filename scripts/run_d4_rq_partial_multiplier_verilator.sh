#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/verilator_d4_rq_valid_enable_l2
logs=build/reports/d4_fullnet_rq_valid_enable_20261018
mkdir -p "$out" "$logs"
verilator --binary --build-jobs 8 --timing -Wall -Wno-fatal \
    --top-module tb_d4_rq_partial_multiplier rtl/cnn/d4_fullnet_top.sv \
    sim/tb_d4_rq_partial_multiplier.sv --Mdir "$out" \
    -o sim_d4_rq_valid_enable_l2 > "$logs/unit_compile.log" 2>&1
"$out/sim_d4_rq_valid_enable_l2" > "$logs/unit.log" 2>&1
grep '^PASS D4_RQ_PARTIAL_MULTIPLIER' "$logs/unit.log"
