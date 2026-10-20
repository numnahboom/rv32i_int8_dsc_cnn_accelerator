#!/usr/bin/env bash
# Only run after staging the existing sequential driver; all files/caches unique.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
test -s build/reports/asic_A3_mapped_gate_20261020/parallel_scheduling.json
pids=()
for item in sample_0:2:s0m2 sample_synthetic_checkerboard:0:scm0 sample_synthetic_checkerboard:2:scm2;do
    IFS=: read -r sample mode case_id <<< "$item"
    D4_GATE_PREPARED=1 D4_GATE_SAMPLE=$sample D4_GATE_MODE=$mode D4_GATE_CASE_ID=$case_id \
        bash scripts/run_d4_asic_gate.sh > "build/reports/asic_A3_mapped_gate_20261020/${case_id}.summary.log" 2>&1 &
    pids+=("$!")
done
status=0
for pid in "${pids[@]}";do if ! wait "$pid";then status=1;fi;done
for case_id in s0m2 scm0 scm2;do tail -n 8 "build/reports/asic_A3_mapped_gate_20261020/${case_id}.summary.log";done
echo "D4_GATE_REMAINING_EXIT=$status original_case_requires_separate_acceptance"
exit "$status"
