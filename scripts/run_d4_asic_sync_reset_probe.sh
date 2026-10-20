#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$(pwd)
std=/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v
for preserve in 0 1;do
    out="$root/build/reports/asic_sync_reset_probe_20261020/preserve_$preserve"
    mkdir -p "$out";cd "$out"
    if [[ "${D4_RESET_PROBE_SYNTH:-1}" != 0 ]];then
        SNPSLMD_LICENSE_FILE=27000@ic03 D4_PRESERVE_SYNC_RESET=$preserve timeout 300 \
            /opt/synopsys/syn/O-2018.06-SP5/bin/dc_shell-xg-t -64bit \
            -f "$root/scripts/asic_sync_reset_probe.tcl" < /dev/null > synth.log 2>&1
    fi
    test -s mapped.v
    grep '^D4_SYNC_RESET_SYNTH_DONE' synth.log
    if timeout 180 /opt/XCELIUM_2003/tools/bin/xrun -64bit -sv +define+functional -notimingchecks -timescale 1ns/1ps \
        -top tb_d4_asic_sync_reset mapped.v "$std" "$root/sim/tb_d4_asic_sync_reset.sv" \
        > gate.log 2>&1;then
        grep '^D4_SYNC_RESET_PROBE_PASS' gate.log
    else
        echo "D4_SYNC_RESET_GATE_FAIL preserve=$preserve"
        tail -n 8 gate.log
    fi
done
# This is a controlled negative/positive experiment, not two expected passes.
grep -q 'SYNC_RESET_START_X' "$root/build/reports/asic_sync_reset_probe_20261020/preserve_0/gate.log"
grep -q '^D4_SYNC_RESET_PROBE_PASS checks=1100 uninitialized_start=1' "$root/build/reports/asic_sync_reset_probe_20261020/preserve_1/gate.log"
echo 'D4_SYNC_RESET_POLICY_CONTRAST_PASS baseline_X=1 preserved_checks=1100'
