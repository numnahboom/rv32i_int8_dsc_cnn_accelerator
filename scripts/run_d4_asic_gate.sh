#!/usr/bin/env bash
# Actual standard-cell and memory models, functional zero-delay gates; no SDF.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 scripts/prepare_d4_asic_gate_tb.py
tag=asic_A3_mapped_gate_20261020
netlist=build/reports/asic_A3_tt_20261020/mapped.v
if [[ "${D4_GATE_ROUTED:-0}" == 1 ]];then
    tag=asic_A3_routed_gate_20261020
    netlist=build/reports/${D4_PHYSICAL_TAG:-asic_A3_physical_20261020}/routed.v
fi
logs=build/reports/$tag
out=build/xcelium_$tag
mkdir -p "$logs" "$out"
models=(/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v
    build/asic_macros/act_2048x128/RASP2048X16M16.v
    build/asic_macros/act_1024x128/D4_ACT_1024X128_M8.v)
for bank in {0..7};do
    models+=("build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_sim.v"
             "build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v")
done
if ! /opt/XCELIUM_2003/tools/bin/xrun -64bit -sv -notimingchecks -timescale 1ns/1ps \
    -top tb_d4_asic_gate -xmlibdirname "$out" -elaborate -l "$logs/compile.log" \
    "$netlist" "${models[@]}" build/asic_gate_tb/tb_d4_asic_gate.sv > "$logs/compile.console.log" 2>&1;then
    tail -25 "$logs/compile.console.log";exit 1
fi
for sample in sample_0 sample_synthetic_checkerboard;do
    for mode in 0 2;do
        /opt/XCELIUM_2003/tools/bin/xrun -64bit -R -xmlibdirname "$out" \
            -l "$logs/${sample}_mode${mode}.log" +vectors="build/d4_fullnet_vectors/$sample" \
            +mode=$mode +epochs=2 > "$logs/${sample}_mode${mode}.console.log" 2>&1
        grep '^D4_FULLNET_PASS' "$logs/${sample}_mode${mode}.log"
    done
done
echo "D4_A3_GATE_FUNCTIONAL_PASS scope=$tag SDF=none"
