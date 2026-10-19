#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-27000@ic03}"
python3 scripts/prepare_d4_asic.py --rq-style native --feature-style banked --parameter-style logic-rom
D4_RUN_TAG=asic_macro_smoke_20261020 bash scripts/run_d4_asic_macro_xcelium.sh build/d4_fullnet_vectors/sample_0
if ! bash scripts/run_d4_asic_gate_unit.sh; then
    tail -24 build/reports/asic_rq_gate_equivalence_20261019/console.log
    exit 1
fi
mkdir -p build/reports/asic_rq_native_ss_20261019
D4_RQ_STYLE=native D4_ASIC_CORNER=ss /opt/synopsys/syn/O-2018.06-SP5/bin/dc_shell-xg-t \
    -64bit -f scripts/asic_rq_compare.tcl > build/reports/asic_rq_native_ss_20261019/console.log 2>&1
grep '^D4_ASIC_RQ_SYNTH_COMPLETE' build/reports/asic_rq_native_ss_20261019/console.log
D4_RUN_TAG=asic_smic_sram_xcelium_20261020 bash scripts/run_d4_asic_macro_xcelium.sh
mkdir -p build/reports/asic_fullnet_tt_20261019
/opt/synopsys/syn/O-2018.06-SP5/bin/dc_shell-xg-t -64bit -f scripts/asic_fullnet_synth.tcl \
    > build/reports/asic_fullnet_tt_20261019/console.log 2>&1
if ! grep '^D4_ASIC_FULLNET_SYNTH_COMPLETE' build/reports/asic_fullnet_tt_20261019/console.log; then
    tail -32 build/reports/asic_fullnet_tt_20261019/console.log
    exit 1
fi
echo D4_ASIC_STAGE2_EXECUTION_COMPLETE
