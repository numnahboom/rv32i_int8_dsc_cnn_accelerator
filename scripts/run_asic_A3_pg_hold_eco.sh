#!/usr/bin/env bash
# Dedicated A3 checkpoint flow: immutable baseline and at most two bounded
# incremental ECO passes from the same frozen candidate contract.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$(pwd)
stage=${1:?usage: run_asic_A3_pg_hold_eco.sh preflight|eco1|eco2}
case "$stage" in preflight|eco1|eco2) ;; *) echo 'Invalid A3 PG/hold stage'; exit 1;; esac
base="$root/build/reports/asic_A3_sync_reset_pg_physical_20261020"
source_dir="$base/hold_repair_1"
run="$root/build/reports/asic_A3_pg_hold_eco_20261020"
out="$run/$stage"
manifest_sha=e31177a5a3be775d1fc686de00d1aec7854aa43721548715563012ef2ee0fcdf
tree_identity_sha=30a630cff7b83aeb86ecff877652561914ce074faf3c8901224a5abd7f6f2511
tree_manifest_sha=e0712d8b133619128c088a20945927028d696522c7deeb3c6892d06fc5bf4eb9
netlist_sha=fed219431fa639f3686df585e1523c71af3c121396afb3950a520863d2728fb0
spef_sha=31c47b84e2c20b5514344f56ae3461d1b29f89af3040cbda7b502cb3309db9a8

mkdir -p "$run"
if [[ "$stage" == preflight && -d "$out" ]]; then
    if [[ -e "$out/innovus.log" ]]; then
        echo 'Refuse to overwrite a preflight that reached Innovus'
        exit 1
    fi
    failed_attempt="$run/preflight_manifest_gate_failure"
    if [[ -e "$failed_attempt" ]]; then
        echo 'Refuse to replace preserved preflight gate-failure evidence'
        exit 1
    fi
    mv "$out" "$failed_attempt"
fi
mkdir "$out"
if [[ "$stage" == preflight || "$stage" == eco1 ]]; then
    input="$source_dir/routed_hold_repair.enc.dat"
    test "$(sha256sum "$source_dir/evidence_manifest.sha256" | awk '{print $1}')" = "$manifest_sha"
    test "$(sha256sum "$source_dir/checkpoint_tree_identity.sha256" | awk '{print $1}')" = "$tree_identity_sha"
    test "$(sha256sum "$source_dir/checkpoint_tree.sha256" | awk '{print $1}')" = "$tree_manifest_sha"
    test "$(sha256sum "$source_dir/routed_hold_repair.v" | awk '{print $1}')" = "$netlist_sha"
    test "$(sha256sum "$source_dir/routed_hold_repair.spef" | awk '{print $1}')" = "$spef_sha"
    expected_members=$(wc -l < "$source_dir/checkpoint_tree.sha256")
    actual_members=$(find "$input" -type f | wc -l)
    test "$expected_members" -eq "$actual_members"
    (
        cd "$base"
        sha256sum -c hold_repair_1/checkpoint_tree_identity.sha256 > "$out/checkpoint_tree_identity_check.log"
        sha256sum -c hold_repair_1/checkpoint_tree.sha256 > "$out/checkpoint_tree_member_check.log"
    )
    printf 'IDENTITY_OK manifest=%s tree_identity=%s tree_manifest=%s members=%s routed_v=%s routed_spef=%s\n' \
        "$manifest_sha" "$tree_identity_sha" "$tree_manifest_sha" "$actual_members" "$netlist_sha" "$spef_sha" \
        > "$out/input_identity.txt"
    expected_helper_sha=$(awk '$2 == "../../../scripts/asic_pg_grid.tcl" {print $1}' "$source_dir/evidence_manifest.sha256")
    test "$expected_helper_sha" = 9425a691ba10b5788beaa5859c8e99ed9b04003c3f44049af88ce7da0219b805
    frozen_helper="$base/executed_pg_grid.tcl"
    test "$(sha256sum "$frozen_helper" | awk '{print $1}')" = "$expected_helper_sha"
    helper_entries=$(awk '$2 == "../../../scripts/asic_pg_grid.tcl" {n++} END {print n+0}' "$source_dir/evidence_manifest.sha256")
    test "$helper_entries" -eq 1
    awk '$2 != "../../../scripts/asic_pg_grid.tcl" {print}' "$source_dir/evidence_manifest.sha256" \
        > "$out/evidence_manifest_172_unchanged.sha256"
    (
        cd "$base"
        sha256sum -c "$out/evidence_manifest_172_unchanged.sha256" > "$out/evidence_manifest_check.log"
    )
    test "$(wc -l < "$out/evidence_manifest_check.log")" -eq 172
    {
        printf 'MANIFEST_SHA256=%s\n' "$manifest_sha"
        printf 'TOTAL_ENTRIES=173\nUNCHANGED_ENTRIES=172\nCONTROLLED_WORKTREE_ENTRY=../../../scripts/asic_pg_grid.tcl\n'
        printf 'EXPECTED_FROZEN_HELPER_SHA256=%s\n' "$expected_helper_sha"
        sha256sum "$frozen_helper" "$root/scripts/asic_pg_grid.tcl"
        printf 'NOTE=Original full evidence manifest is immutable; the one worktree helper entry is separately proven by the frozen executed copy.\n'
    } > "$out/evidence_manifest_helper_delta.txt"
    if [[ -d "$run/preflight_manifest_gate_failure" ]]; then
        cp "$run/preflight_manifest_gate_failure/evidence_manifest_check.log" \
            "$out/prior_full_manifest_check_with_controlled_helper_delta.log"
    fi
    sha256sum "$frozen_helper" > "$out/prior_executed_pg_grid.sha256"
else
    input="$run/eco1/routed_A3.enc.dat"
    test -d "$input"
    (
        cd "$run/eco1"
        sha256sum -c checkpoint_tree_identity.sha256 > "$out/eco1_checkpoint_identity_check.log"
        sha256sum -c checkpoint_tree.sha256 > "$out/checkpoint_tree_member_check.log"
        sha256sum -c final_artifact_hashes.sha256 > "$out/eco1_final_artifact_check.log"
    )
    tree_manifest_sha=$(sha256sum "$run/eco1/checkpoint_tree.sha256" | awk '{print $1}')
    printf 'IDENTITY_OK prior_candidate_tree_manifest=%s members=%s\n' \
        "$tree_manifest_sha" "$(wc -l < "$run/eco1/checkpoint_tree.sha256")" > "$out/input_identity.txt"
    cp "$run/eco1/input_identity.txt" "$out/original_input_identity.txt"
    cp "$run/eco1/executed_inputs.sha256" "$out/eco1_executed_inputs.sha256"
    if grep -qx 'A3_ECO_ACCEPTED' "$run/eco1/status.txt"; then
        echo 'D4_A3_ECO2_REFUSE_ALREADY_ACCEPTED'
        exit 1
    fi
fi
test -d "$input"
find -L "$input" -type f -print0 | sort -z | xargs -0 sha256sum > "$out/input_checkpoint_resolved_files.sha256"
{
    printf 'LINK_PATH\tLINK_TEXT\tRESOLVED_TARGET\tTARGET_SHA256\n'
    while IFS= read -r -d '' link; do
        link_path=${link#"$input"/}
        link_text=$(readlink "$link")
        resolved=$(readlink -f "$link" || true)
        if [[ -n "$resolved" && -f "$resolved" ]]; then
            target_sha=$(sha256sum "$resolved" | awk '{print $1}')
        else
            target_sha=UNRESOLVED_OR_NONFILE
        fi
        printf '%s\t%s\t%s\t%s\n' "$link_path" "$link_text" "$resolved" "$target_sha"
    done < <(find "$input" -type l -print0 | sort -z)
} > "$out/input_checkpoint_symlink_resolution.tsv"
test "$(($(wc -l < "$out/input_checkpoint_symlink_resolution.tsv") - 1))" -eq "$(find "$input" -type l | wc -l)"
find -L "$input" -type f \( -name '*.sdc' -o -name '*.tcl' \) -print0 | sort -z | \
    xargs -0 -r sha256sum > "$out/constraint_dependency_hashes.sha256"
{
    printf 'SOURCE\tLINE\tCONSTRAINT_COMMAND\n'
    while IFS= read -r -d '' source_file; do
        if ! grep -nE '(^|[[:space:]])(create_clock|create_generated_clock|set_input_delay|set_output_delay|set_input_transition|set_load|set_clock_uncertainty|set_false_path|set_multicycle_path|set_clock_groups|set_disable_timing|set_max_delay|set_min_delay|set_case_analysis|set_timing_derate)([[:space:]]|$)' "$source_file"; then
            printf '%s\t-\tNO_MATCHING_TIMING_COMMAND\n' "$source_file"
        else
            grep -nE '(^|[[:space:]])(create_clock|create_generated_clock|set_input_delay|set_output_delay|set_input_transition|set_load|set_clock_uncertainty|set_false_path|set_multicycle_path|set_clock_groups|set_disable_timing|set_max_delay|set_min_delay|set_case_analysis|set_timing_derate)([[:space:]]|$)' "$source_file" | \
                sed "s#^#$source_file\t#"
        fi
    done < <(find -L "$input" -type f \( -name '*.sdc' -o -name '*.tcl' \) -print0 | sort -z)
} > "$out/constraint_command_audit.tsv"
if [[ "$stage" == eco1 || "$stage" == eco2 ]]; then
    for evidence in pg_inventory_geometry_state_all_loaded_lefs.tsv body_pin_rail_library_evidence.txt pg_inventory_pre.tsv; do
        test -f "$run/preflight/$evidence"
        cp "$run/preflight/$evidence" "$out/$evidence"
    done
    cp "$run/preflight/prior_native_pg_terminal_warning_audit.json" "$out/prior_native_pg_terminal_warning_audit.json"
    cp "$source_dir/connectivity.rpt" "$out/prior_connectivity_all.rpt"
    cp "$source_dir/connectivity_VDD.rpt" "$out/prior_connectivity_VDD.rpt"
    cp "$source_dir/connectivity_VSS.rpt" "$out/prior_connectivity_VSS.rpt"
fi
cp scripts/asic_A3_pg_hold_eco.tcl "$out/executed_asic_A3_pg_hold_eco.tcl"
cp scripts/asic_pg_grid.tcl "$out/executed_asic_pg_grid.tcl"
sha256sum scripts/asic_A3_pg_hold_eco.tcl scripts/asic_pg_grid.tcl scripts/run_asic_A3_pg_hold_eco.sh \
    "$source_dir/evidence_manifest.sha256" "$source_dir/checkpoint_tree_identity.sha256" \
    "$source_dir/checkpoint_tree.sha256" "$source_dir/routed_hold_repair.v" \
    "$source_dir/routed_hold_repair.spef" > "$out/executed_inputs.sha256"
printf '{"candidate":"A3","stage":"%s","period_ns":10.0,"process_nm":180,"setup_views":["CORE_ss","CORE_tt"],"hold_view":"CORE_ff","cppr":"both","early_late_derates":[0.95,1.05],"nice":10,"max_local_workers":16,"eco_policy":"BUFHDV0 local input_data-to-image-mux branch chains plus one BUFHDV0 on each currently failing result_vector macro DIN; eco2 adds only still-needed local repeaters","source":"%s"}\n' \
    "$stage" "$input" > "$out/run_contract.json"

if [[ "$stage" == preflight ]]; then
    cp "$base/physical_terminal_audit.py" "$out/prior_native_pg_terminal_audit.py"
    cp "$base/native_pg_terminal_warning_audit.json" "$out/prior_native_pg_terminal_warning_audit.json"
    cp "$source_dir/optimizer/hold_vio_data.rpt.csv" "$out/prior_optimizer_hold_vio_data.csv"
    awk '/holdSlackFixingThreshold|Starting Core Fixing|Executing transform:|\|   0\||List of usable buffers|Total number of usable buffers|List of unusable buffers|Total number of unusable buffers|All delay cells are dont_use/ {print}' \
        "$base/hold_repair_1.console.log" > "$out/prior_optimizer_diagnostic_excerpt.txt"
    {
        for corner in ss tt ff; do
            case "$corner" in
                ss) librel=libs/mmmc/scc018ug_hd_rvt_ss_v1p62_125c_basic.lib ;;
                tt) librel=libs/mmmc/scc018ug_hd_rvt_tt_v1p8_25c_basic.lib ;;
                ff) librel=libs/mmmc/scc018ug_hd_rvt_ff_v1p98_0c_basic.lib ;;
            esac
            lib=$(readlink -f "$input/$librel")
            printf 'CORNER=%s LINK=%s RESOLVED=%s\n' "$corner" "$input/$librel" "$lib"
            sha256sum "$lib"
            grep -n -E 'voltage_map\((VNW|VDD|VSS|VPW),' "$lib"
            awk '/cell\(BUFHDV0\)/ {seen=1} seen && /pg_pin\((VDD|VNW|VPW|VSS)\)|voltage_name|pg_type|related_bias_pin/ {print} seen && /pin\(I\)/ {exit}' "$lib"
        done
        for rel in libs/lef/scc018ug_hd_rvt.lef libs/lef/scc018ug_6m_1tma1.lef \
            libs/mmmc/RC_ss/qrcTechFile_RCgen libs/mmmc/RC_tt/qrcTechFile_RCgen libs/mmmc/RC_ff/qrcTechFile_RCgen; do
            resolved=$(readlink -f "$input/$rel")
            printf 'COLLATERAL_LINK=%s RESOLVED=%s\n' "$input/$rel" "$resolved"
            sha256sum "$resolved"
        done
        lef=$(readlink -f "$input/libs/lef/scc018ug_hd_rvt.lef")
        awk '/^MACRO BUFHDV0$/ {seen=1} seen && (/^  PIN (VDD|VNW|VPW|VSS)$/ || /USE (POWER|GROUND)/) {print} seen && /^END BUFHDV0$/ {exit}' "$lef"
    } > "$out/body_pin_rail_library_evidence.txt"
fi

cd "$out"
export D4_A3_ROOT="$root" D4_A3_STAGE="$stage" D4_A3_STAGE_DIR="$out" D4_A3_INPUT_CHECKPOINT="$input"
uptime > system_load_pre.txt
free -h > system_memory_pre.txt
{ ps -C innovus -o pid=,ni=,rss=,comm=,args= || true; } > running_innovus_pre.txt
if [[ -s running_innovus_pre.txt ]]; then
    echo 'D4_A3_REFUSE_CONCURRENT_INNOVUS_PROCESS'
    exit 1
fi
{
    printf 'TIME\tPID\tPPID\tNI\tRSS_KB\tCOMMAND\n'
    ps -ww -o pid=,ppid=,ni=,rss=,comm=,args= -p "$$" -p "$PPID"
} > task_resource_owner_pre.txt
printf 'TIME\tPID\tPPID\tNI\tRSS_KB\tCOMMAND\n' > task_resource_timeline.tsv
nice -n 10 timeout 10800 /opt/cadence/innovus/191/tools/bin/innovus -no_gui \
    -files "$out/executed_asic_A3_pg_hold_eco.tcl" -log innovus.log \
    < /dev/null > console.log 2>&1 &
wrapper_pid=$!
sleep 2
while kill -0 "$wrapper_pid" 2>/dev/null; do
    sample_time=$(date -Is)
    ps -ww -eo pid=,ppid=,ni=,rss=,comm=,args= | \
        awk -v stamp="$sample_time" -v needle="$out/executed_asic_A3_pg_hold_eco.tcl" \
            'index($0,needle) {print stamp "\t" $0}' >> task_resource_timeline.tsv
    sleep 30
done
if wait "$wrapper_pid"; then run_rc=0; else run_rc=$?; fi
uptime > system_load_post.txt
free -h > system_memory_post.txt
printf 'INNOVUS_EXIT_CODE=%s\n' "$run_rc" > task_execution_status.txt
if [[ "$run_rc" -ne 0 ]]; then
    echo "D4_A3_NATIVE_TOOL_EXIT=$run_rc"
    exit "$run_rc"
fi
if grep -q '\*\*ERROR' console.log; then
    echo "D4_A3_NATIVE_TOOL_ERROR stage=$stage"
    exit 1
fi
if [[ "$stage" == preflight ]]; then
    grep '^D4_A3_PG_HOLD_PREFLIGHT_COMPLETE' console.log
    echo "D4_A3_REPORT_ONLY_PREFLIGHT_COMPLETE stage=$stage"
else
    test -d "$out/routed_A3.enc.dat"
    test -f "$out/routed_A3.v"
    test -f "$out/routed_A3.spef"
    (
        cd "$out"
        find -L routed_A3.enc.dat -type f -print0 | sort -z | xargs -0 sha256sum > checkpoint_tree.sha256
        sha256sum checkpoint_tree.sha256 > checkpoint_tree_identity.sha256
        {
            printf 'LINK_PATH\tLINK_TEXT\tRESOLVED_TARGET\tTARGET_SHA256\n'
            while IFS= read -r -d '' link; do
                link_path=${link#routed_A3.enc.dat/}
                link_text=$(readlink "$link")
                resolved=$(readlink -f "$link" || true)
                if [[ -n "$resolved" && -f "$resolved" ]]; then
                    target_sha=$(sha256sum "$resolved" | awk '{print $1}')
                else
                    target_sha=UNRESOLVED_OR_NONFILE
                fi
                printf '%s\t%s\t%s\t%s\n' "$link_path" "$link_text" "$resolved" "$target_sha"
            done < <(find routed_A3.enc.dat -type l -print0 | sort -z)
        } > checkpoint_symlink_resolution.tsv
        {
            find . -maxdepth 1 -type f ! -name 'report_artifact_hashes.sha256' ! -name 'final_artifact_hashes.sha256' -print0 | sort -z | xargs -0 sha256sum
            find time_setup time_hold -type f -print0 | sort -z | xargs -0 sha256sum
        } > report_artifact_hashes.sha256
        sha256sum routed_A3.v routed_A3.spef checkpoint_tree.sha256 checkpoint_tree_identity.sha256 \
            checkpoint_symlink_resolution.tsv input_checkpoint_resolved_files.sha256 \
            input_checkpoint_symlink_resolution.tsv input_identity.txt run_contract.json \
            system_load_pre.txt system_memory_pre.txt task_resource_owner_pre.txt task_resource_timeline.tsv \
            executed_asic_A3_pg_hold_eco.tcl executed_asic_pg_grid.tcl executed_inputs.sha256 \
            constraint_dependency_hashes.sha256 constraint_command_audit.tsv eco_insertion_plan.tsv \
            hold_target_inventory.tsv timing_summary.tsv pg_terminal_inventory_final.tsv status.txt \
            pg_inventory_geometry_state_all_loaded_lefs.tsv body_pin_rail_library_evidence.txt report_artifact_hashes.sha256 \
            > final_artifact_hashes.sha256
    )
    grep '^D4_A3_HOLD_TARGET_SCAN' console.log
    grep '^D4_A3_LOCAL_REPEATER_INSERTION_COMPLETE' console.log
    grep '^D4_A3_ECO_STAGE_COMPLETE' console.log
    printf 'D4_A3_INCREMENTAL_ECO_STAGE_COMPLETE stage=%s status=%s\n' \
        "$stage" "$(cat "$out/status.txt")"
fi
