#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
logs=build/reports/asic_rq_gate_equivalence_20261019
mkdir -p "$logs"
cells=/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v
"${XRUN:-/opt/XCELIUM_2003/tools/bin/xrun}" -64bit -sv \
    -top tb_d4_asic_rq_equivalence -xmlibdirname build/xcelium_rq_gate_equivalence \
    -l "$logs/unit.log" "$cells" \
    build/reports/asic_rq_partial_tt_20261019/mapped.v \
    build/reports/asic_rq_native_tt_20261019/mapped.v \
    sim/tb_d4_asic_rq_equivalence.sv > "$logs/console.log" 2>&1
grep '^D4_ASIC_RQ_EQUIVALENCE_PASS' "$logs/unit.log"
