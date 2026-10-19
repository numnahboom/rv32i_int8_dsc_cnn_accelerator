#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tag="${D4_RUN_TAG:-asic_smic_sram_xcelium_20261019}"
logs="build/reports/$tag"
out="build/xcelium_$tag"
mkdir -p "$logs" "$out"
xrun_bin="${XRUN:-/opt/XCELIUM_2003/tools/bin/xrun}"
feature_style="${D4_FEATURE_STYLE:-banked}"
core="build/asic_eval/native_${feature_style}_logic_rom/d4_fullnet_eval.sv"
if [[ "${D4_WEIGHT_STYLE:-logic-rom}" == mask-rom ]];then core="${core%/d4_fullnet_eval.sv}_mask_weights/d4_fullnet_eval.sv";fi
if [[ "${D4_RESIDUAL_STYLE:-logic-rom}" == mask-rom ]];then core="${core%/d4_fullnet_eval.sv}_mask_residual/d4_fullnet_eval.sv";fi
macro=build/asic_macros/act_2048x128/RASP2048X16M16.v
extra_sources=()
if [[ "$feature_style" == asymmetric ]]; then
    extra_sources=(rtl/asic/d4_feature_banks_asymmetric.sv \
        build/asic_macros/act_1024x128/D4_ACT_1024X128_M8.v sim/d4_asic_asymmetric_monitor.sv)
elif [[ "$feature_style" != banked ]]; then
    echo "Unsupported feature bank style" >&2; exit 1
fi
if [[ "${D4_WEIGHT_STYLE:-logic-rom}" == mask-rom ]];then
    extra_sources+=(rtl/asic/d4_weight_rom_banks.sv)
    for bank in {0..7};do extra_sources+=("build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_sim.v");done
fi
if [[ "${D4_RESIDUAL_STYLE:-logic-rom}" == mask-rom ]];then
    extra_sources+=(rtl/asic/d4_residual_rom_banks.sv)
    for bank in {0..7};do extra_sources+=("build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v");done
fi
if ! "$xrun_bin" -64bit -sv +define+D4_TECH_SRAM -top tb_d4_fullnet \
    -xmlibdirname "$out" -elaborate -l "$logs/compile.log" "$core" \
    rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks.sv \
    rtl/asic/d4_smic180_sram.sv "$macro" sim/d4_asic_sram_monitor.sv \
    "${extra_sources[@]}" sim/tb_d4_fullnet.sv > "$logs/compile.console.log" 2>&1; then
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
