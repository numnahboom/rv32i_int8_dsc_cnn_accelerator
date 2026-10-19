#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tag="${D4_RUN_TAG:-asic_smic_sram_xcelium_20261019}"
logs="build/reports/$tag"
out="build/xcelium_$tag"
mkdir -p "$logs" "$out"
xrun_bin="${XRUN:-/opt/XCELIUM_2003/tools/bin/xrun}"
core=build/asic_eval/native_banked_logic_rom/d4_fullnet_eval.sv
macro=build/asic_macros/act_2048x128/RASP2048X16M16.v
if ! "$xrun_bin" -64bit -sv +define+D4_TECH_SRAM -top tb_d4_fullnet \
    -xmlibdirname "$out" -elaborate -l "$logs/compile.log" "$core" \
    rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks.sv \
    rtl/asic/d4_smic180_sram.sv "$macro" sim/d4_asic_sram_monitor.sv \
    sim/tb_d4_fullnet.sv > "$logs/compile.console.log" 2>&1; then
    tail -24 "$logs/compile.console.log" >&2
    exit 1
fi
samples=(build/d4_fullnet_vectors/sample_*)
if (( $# )); then samples=("$@"); fi
passes=0
for sample in "${samples[@]}"; do
    for mode in 0 1 2; do
        log="$logs/${sample##*/}_mode${mode}.log"
        # Functional macro model, no SDF or electrical/timing signoff claim.
        if ! "$xrun_bin" -64bit -R -xmlibdirname "$out" -l "$log" \
            +vectors="$sample" +mode="$mode" +epochs=2 > "${log%.log}.console.log" 2>&1; then
            tail -24 "${log%.log}.console.log" >&2
            exit 1
        fi
        count=$(grep -c '^D4_FULLNET_PASS' "$log")
        [[ "$count" -eq 2 ]]
        passes=$((passes+count))
    done
done
[[ "$passes" -eq "$((${#samples[@]}*6))" ]]
echo "D4_ASIC_MACRO_FULLNET_PASS samples=${#samples[@]} exact_inferences=$passes"
