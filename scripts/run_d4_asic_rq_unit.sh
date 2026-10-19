#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
out=build/reports/asic_rq_equivalence_20261019
mkdir -p "$out"
"${XRUN:-/opt/XCELIUM_2003/tools/bin/xrun}" -64bit -sv \
    -top tb_d4_asic_rq_equivalence -xmlibdirname build/xcelium_rq_equivalence \
    -l "$out/unit.log" build/asic_eval/partial/d4_fullnet_eval.sv \
    rtl/asic/d4_rq_native_multiplier_lane.sv sim/tb_d4_asic_rq_equivalence.sv \
    > "$out/console.log" 2>&1
grep '^D4_ASIC_RQ_EQUIVALENCE_PASS' "$out/unit.log"
