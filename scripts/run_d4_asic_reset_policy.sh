#!/usr/bin/env bash
# One full-core mapping experiment. No RTL/network/model initialization changes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$(pwd)
syn=asic_A3_sync_reset_tt_20261020
formal=asic_A3_sync_reset_formal_20261020
gate=asic_A3_sync_reset_gate_20261020
out="$root/build/reports/$syn"
mkdir -p "$out"
if [[ -e "$out/mapped.v" || -e "$out/console.log" ]];then
    echo 'D4_RESET_POLICY_REFUSE_OVERWRITE';exit 1
fi
sha256sum scripts/asic_all_macro_fullnet_synth.tcl scripts/asic_A3_formal.tcl \
    scripts/run_d4_asic_gate.sh scripts/prepare_d4_asic_gate_tb.py \
    build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv \
    rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks_asymmetric.sv \
    rtl/asic/d4_smic180_sram.sv rtl/asic/d4_weight_rom_banks.sv rtl/asic/d4_residual_rom_banks.sv \
    > "$out/executed_sources.sha256"
cd "$out"
SNPSLMD_LICENSE_FILE=27000@ic03 D4_PRESERVE_SYNC_RESET=1 timeout 10800 \
    /opt/synopsys/syn/O-2018.06-SP5/bin/dc_shell-xg-t -64bit \
    -f "$root/scripts/asic_all_macro_fullnet_synth.tcl" < /dev/null > console.log 2>&1
grep '^D4_A3_FULL_CORE_SYNTH_COMPLETE' console.log
cd "$root"
D4_SYNTH_TAG=$syn D4_GATE_TAG=${gate}_startup D4_GATE_START_PROBE=1 D4_GATE_CASE_ID=reset_policy \
    bash scripts/run_d4_asic_gate.sh > "$out/startup.summary.log" 2>&1
grep '^D4_GATE_START_PROBE_PASS' "$out/startup.summary.log"
mkdir -p "$root/build/reports/$formal"
(cd "$root/build/reports/$formal";SNPSLMD_LICENSE_FILE=27000@ic03 D4_SYNTH_TAG=$syn timeout 7200 \
    /opt/synopsys/fm/O-2018.06-SP1/bin/fm_shell -f "$root/scripts/asic_A3_formal.tcl" \
    < /dev/null > console.log 2>&1) &
formal_pid=$!
python3 scripts/prepare_d4_asic_gate_tb.py > "$out/gate_tb_prepare.log"
pids=()
for sample in sample_0 sample_synthetic_checkerboard;do
    for mode in 0 2;do
        D4_SYNTH_TAG=$syn D4_GATE_TAG=$gate D4_GATE_SAMPLE=$sample D4_GATE_MODE=$mode \
            D4_GATE_CASE_ID=${sample}_m${mode} D4_GATE_PREPARED=1 \
            bash scripts/run_d4_asic_gate.sh > "$out/${sample}_m${mode}.summary.log" 2>&1 &
        pids+=("$!")
    done
done
failed=0
for pid in "${pids[@]}";do wait "$pid" || failed=1;done
wait "$formal_pid" || failed=1
if [[ $failed != 0 ]];then echo 'D4_RESET_POLICY_FULL_VALIDATION_FAIL';exit 1;fi
grep '^D4_A3_RTL_TO_MAPPED_FORMAL_PASS' "$root/build/reports/$formal/console.log"
echo 'D4_RESET_POLICY_MAPPING_AND_VALIDATION_PASS full_exact_inferences=8 SDF=none power_claim=0'
