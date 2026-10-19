#!/usr/bin/env bash
# Compatibility-only reset/protocol probes reuse the legacy generic clock shell.
# This shell is not part of the ASIC physical netlist or its area/latency claim.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
logs=build/reports/asic_A2_control_probes_20261020
out=build/xcelium_asic_A2_control_probes
core=build/asic_eval/native_asymmetric_logic_rom_mask_weights/d4_fullnet_eval.sv
extra=()
if [[ "${D4_RESIDUAL_STYLE:-logic-rom}" == mask-rom ]];then
    logs=build/reports/asic_A3_control_probes_20261020
    out=build/xcelium_asic_A3_control_probes
    core=build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv
    extra=(rtl/asic/d4_residual_rom_banks.sv)
    for bank in {0..7};do extra+=("build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v");done
fi
mkdir -p "$logs" "$out"
models=()
for bank in {0..7};do models+=("build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_sim.v");done
if ! /opt/XCELIUM_2003/tools/bin/xrun -64bit -sv +define+D4_TECH_SRAM \
    -top tb_d4_fullnet_packed -xmlibdirname "$out" -elaborate -l "$logs/compile.log" \
    "$core" "${extra[@]}" \
    rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks.sv \
    rtl/asic/d4_feature_banks_asymmetric.sv rtl/asic/d4_smic180_sram.sv \
    rtl/asic/d4_weight_rom_banks.sv "${models[@]}" \
    build/asic_macros/act_2048x128/RASP2048X16M16.v \
    build/asic_macros/act_1024x128/D4_ACT_1024X128_M8.v \
    sim/d4_asic_sram_monitor.sv sim/d4_asic_asymmetric_monitor.sv \
    rtl/cnn/d4_fullnet_clocking.sv rtl/cnn/d4_fullnet_impl_top.sv sim/tb_d4_fullnet_packed.sv \
    > "$logs/compile.console.log" 2>&1;then tail -24 "$logs/compile.console.log";exit 1;fi
for probe in control_probe reset_pipeline_probe completion_reset_probe start_token_probe throughput;do
    if ! /opt/XCELIUM_2003/tools/bin/xrun -64bit -R -xmlibdirname "$out" \
        -l "$logs/$probe.log" +mode=0 +epochs=3 +"$probe" > "$logs/$probe.console.log" 2>&1;then
        tail -24 "$logs/$probe.console.log";exit 1
    fi
    grep -E '^D4_.*PASS|^D4_PACKED_START_INTERVAL' "$logs/$probe.log"
done
echo "D4_ASIC_CONTROL_COMPATIBILITY_PASS residual_style=${D4_RESIDUAL_STYLE:-logic-rom}"
