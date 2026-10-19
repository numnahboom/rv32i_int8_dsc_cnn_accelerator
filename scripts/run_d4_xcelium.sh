#!/usr/bin/env bash
# Complete-network reference regression on the lab server; no Python packages.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tag="${D4_RUN_TAG:-asic_server_baseline_20261019}"
out="build/xcelium_${tag}"
logs="build/reports/${tag}"
mkdir -p "$out" "$logs"
xrun_bin="${XRUN:-/opt/XCELIUM_2003/tools/bin/xrun}"
core="${D4_CORE_SOURCE:-rtl/cnn/d4_fullnet_top.sv}"
"$xrun_bin" -64bit -sv -top tb_d4_fullnet -timescale 1ns/1ps \
    -xmlibdirname "$out" -elaborate -l "$logs/compile.log" \
    "$core" rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks.sv \
    sim/tb_d4_fullnet.sv > "$logs/compile.console.log" 2>&1
samples=(build/d4_fullnet_vectors/sample_*)
if (( $# )); then samples=("$@"); fi
passes=0
for sample in "${samples[@]}"; do
    for mode in 0 1 2; do
        log="$logs/${sample##*/}_mode${mode}.log"
        "$xrun_bin" -64bit -R -xmlibdirname "$out" -l "$log" \
            +vectors="$sample" +mode="$mode" +epochs=2 > "${log%.log}.console.log" 2>&1
        count=$(grep -c '^D4_FULLNET_PASS' "$log")
        [[ "$count" -eq 2 ]]
        passes=$((passes + count))
    done
done
[[ "$passes" -eq "$((${#samples[@]} * 6))" ]]
echo "D4_XCELIUM_PASS samples=${#samples[@]} exact_inferences=$passes"
