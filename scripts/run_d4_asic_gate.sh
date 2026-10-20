#!/usr/bin/env bash
# Functional standard-cell mode with real memory models; no SDF.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$(pwd)
if [[ "${D4_GATE_PREPARED:-0}" != 1 ]];then python3 scripts/prepare_d4_asic_gate_tb.py;fi
tag=asic_A3_mapped_gate_20261020
netlist=build/reports/asic_A3_tt_20261020/mapped.v
if [[ "${D4_GATE_ROUTED:-0}" == 1 ]];then
    tag=asic_A3_routed_gate_20261020
    netlist=build/reports/${D4_PHYSICAL_TAG:-asic_A3_physical_20261020}/routed.v
fi
logs=$root/build/reports/$tag
case_id=${D4_GATE_CASE_ID:-}
out=$root/build/xcelium_${tag}${case_id:+_$case_id}
suffix=${case_id:+_$case_id}
netlist=$root/$netlist
mkdir -p "$logs" "$out/cwd"
models=(/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v
    "$root/build/asic_macros/act_2048x128/RASP2048X16M16.v"
    "$root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8.v")
for bank in {0..7};do
    models+=("$root/build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_sim.v"
             "$root/build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v")
done
# Isolate xrun history/key files as well as compiled libraries and logs.
cd "$out/cwd"
top=tb_d4_asic_gate
testbench=$root/build/asic_gate_tb/tb_d4_asic_gate.sv
extra_defines=()
if [[ "${D4_GATE_INTERNAL_DIAG:-0}" == 1 ]];then extra_defines+=(+define+D4_GATE_INTERNAL_DIAG);fi
if [[ "${D4_GATE_START_PROBE:-0}" == 1 ]];then
    top=tb_d4_asic_gate_start
    testbench=$root/sim/tb_d4_asic_gate_start.sv
fi
if ! /opt/XCELIUM_2003/tools/bin/xrun -64bit -sv +define+functional -notimingchecks -timescale 1ns/1ps \
    "${extra_defines[@]}" \
    -top "$top" -xmlibdirname "$out" -elaborate -l "$logs/compile$suffix.log" \
    "$netlist" "${models[@]}" "$testbench" > "$logs/compile$suffix.console.log" 2>&1;then
    tail -25 "$logs/compile$suffix.console.log";exit 1
fi
if [[ "${D4_GATE_START_PROBE:-0}" == 1 ]];then
    /opt/XCELIUM_2003/tools/bin/xrun -64bit -R -xmlibdirname "$out" \
        -l "$logs/start_probe.log" > "$logs/start_probe.console.log" 2>&1
    grep '^D4_GATE_START_PROBE_PASS' "$logs/start_probe.log"
    exit 0
fi
samples=(sample_0 sample_synthetic_checkerboard)
modes=(0 2)
if [[ -n "${D4_GATE_SAMPLE:-}" ]];then samples=("$D4_GATE_SAMPLE");fi
if [[ -n "${D4_GATE_MODE:-}" ]];then modes=("$D4_GATE_MODE");fi
for sample in "${samples[@]}";do
    for mode in "${modes[@]}";do
        /opt/XCELIUM_2003/tools/bin/xrun -64bit -R -xmlibdirname "$out" \
            -l "$logs/${sample}_mode${mode}.log" +vectors="$root/build/d4_fullnet_vectors/$sample" \
            +mode=$mode +epochs=2 > "$logs/${sample}_mode${mode}.console.log" 2>&1
        grep '^D4_FULLNET_PASS' "$logs/${sample}_mode${mode}.log"
    done
done
echo "D4_A3_GATE_FUNCTIONAL_PASS scope=$tag SDF=none"
