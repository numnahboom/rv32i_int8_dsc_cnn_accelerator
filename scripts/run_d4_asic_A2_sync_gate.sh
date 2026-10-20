#!/usr/bin/env bash
# Exact-inference gate for the fixed A2 sync-reset mapping. Run on lab-ljw.
set -euo pipefail
if [[ -n "${D4_PROJECT_ROOT:-}" ]]; then
    root=$D4_PROJECT_ROOT
else
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi
cd "$root"
runner_path=$(readlink -f "${BASH_SOURCE[0]}")

mapping_tag=asic_A2_sync_reset_tt_20261020
gate_tag=asic_A2_sync_gate_20261020
mapping="$root/build/reports/$mapping_tag"
logs="$root/build/reports/$gate_tag"
private_job="$root/build/reports/asic_A2_sync_gate_job_20261020"
netlist="$mapping/mapped.v"
scoreboard="$root/build/asic_gate_tb/tb_d4_asic_gate.sv"
expected_netlist_sha=7a42e9c61090181cee0c8212e0cf65f83693f1bdfb1027948b108290dbd5c0bd
expected_scoreboard_sha=2625b464314fad7a7591b4d9226d5ab49704a4e544d1767efbc9ca1496400ca5
expected_generic_runner_sha=1b3eb273504a5356b4075bfe320ce4dd97e7de8037a22d55f1003c133450ad09

mkdir -p "$logs" "$private_job"
test -s "$netlist"
test "$(sha256sum "$netlist" | cut -d' ' -f1)" = "$expected_netlist_sha"
test "$(sha256sum "$scoreboard" | cut -d' ' -f1)" = "$expected_scoreboard_sha"
test "$(sha256sum "$root/scripts/run_d4_asic_gate.sh" | cut -d' ' -f1)" = "$expected_generic_runner_sha"
grep -qx 'hdlin_ff_always_sync_set_reset=1' "$mapping/reset_policy.txt"
sha256sum --check "$mapping/executed_sources.sha256" > "$private_job/mapping_sources_check.log"

source_args=(
    "$netlist"
    "$mapping/reset_policy.txt"
    "$mapping/result.json"
    "$mapping/executed_sources.sha256"
    "$runner_path"
    "$root/scripts/run_d4_asic_gate.sh"
    "$root/sim/tb_d4_asic_gate_start.sv"
    "$root/sim/d4_asic_gate_memory_watch.sv"
    "$scoreboard"
    /opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v
    "$root/build/asic_macros/act_2048x128/RASP2048X16M16.v"
    "$root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8.v"
)
for bank in {0..7}; do
    source_args+=("$root/build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_sim.v")
    source_args+=("$root/build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_sim.v")
done
for sample in sample_0 sample_synthetic_checkerboard; do
    while IFS= read -r -d '' file; do source_args+=("$file"); done \
        < <(find "$root/build/d4_fullnet_vectors/$sample" -maxdepth 1 -type f -print0 | sort -z)
done
sha256sum "${source_args[@]}" > "$private_job/execution_sources.sha256"

python3 - "$root" "$private_job" "$gate_tag" "$mapping_tag" "$runner_path" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, job, gate_tag, mapping_tag, runner = map(Path, sys.argv[1:])
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
mapping = root / 'build/reports' / mapping_tag
result = json.loads((mapping / 'result.json').read_text())
sources = {}
for line in (job / 'execution_sources.sha256').read_text().splitlines():
    sha, path = line.split('  ', 1)
    p = Path(path)
    try:
        key = p.relative_to(root).as_posix()
    except ValueError:
        key = str(p)
    sources[key] = sha
identity = {
    'schema_version': 1,
    'status': 'A2_SYNC_RESET_SPECIFY_RUN_IDENTITY',
    'remote_host_alias': 'lab-ljw',
    'remote_project': str(root),
    'mapping': {
        'candidate': result['candidate'],
        'tag': str(mapping_tag),
        'mapped_netlist': 'build/reports/' + str(mapping_tag) + '/mapped.v',
        'mapped_netlist_bytes': (mapping / 'mapped.v').stat().st_size,
        'mapped_netlist_sha256': digest(mapping / 'mapped.v'),
        'reset_policy': (mapping / 'reset_policy.txt').read_text().strip(),
        'corner': result['corner'],
        'period_ns': result['period_ns'],
        'cell_area_including_macros_um2': result['cell_area_including_macros_um2'],
        'SRAMs': result['SRAMs'],
        'programmed_ROMs': result['programmed_ROMs'],
        'post_route': result['post_route'],
        'power_claim': result['power_claim'],
        'mapping_source_manifest_sha256': digest(mapping / 'executed_sources.sha256'),
        'mapping_sources_check_passed': True,
    },
    'gate': {
        'tag': str(gate_tag),
        'simulator': 'Cadence Xcelium 20.03-s001',
        'cell_mode': 'specify',
        'standard_cell_behavior': 'real standard-cell model with default specify propagation arcs',
        'memory_behavior': 'real SRAM and ROM simulation models',
        'timing_checks_option': '-notimingchecks',
        'sdf_annotated': False,
        'functional_define': False,
        'memory_diagnostics_enabled': True,
        'startup_probe': 'D4_GATE_START_PROBE_PASS cycles=34 input_beats=16 controls_known=1',
        'case_plan': [
            {'sample': sample, 'mode': mode, 'epochs': 2}
            for sample in ('sample_0', 'sample_synthetic_checkerboard')
            for mode in (0, 2)
        ],
        'case_concurrency_limit': 2,
        'raw_logs_included_unmodified': True,
        'pdk_model_exported': False,
        'mapped_netlist_exported': False,
        'svf_exported': False,
    },
    'source_hashes': sources,
    'execution_source_manifest_sha256': digest(job / 'execution_sources.sha256'),
    'runner_sha256': digest(runner),
    'generic_runner_sha256': digest(root / 'scripts/run_d4_asic_gate.sh'),
    'scoreboard_sha256': digest(root / 'build/asic_gate_tb/tb_d4_asic_gate.sv'),
    'scoreboard_sha256_expected': '2625b464314fad7a7591b4d9226d5ab49704a4e544d1767efbc9ca1496400ca5',
    'remote_raw_log_sha256': {},
}
canonical = json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()
identity['identity_sha256'] = hashlib.sha256(canonical).hexdigest()
(job / 'source_identity.json').write_text(json.dumps(identity, indent=2) + '\n')
PY

run_one() {
    local sample=$1 mode=$2 case_id="${1}_m${2}"
    D4_SYNTH_TAG="$mapping_tag" D4_GATE_TAG="$gate_tag" \
        D4_GATE_CASE_ID="$case_id" D4_GATE_PREPARED=1 \
        D4_GATE_CELL_MODE=specify D4_GATE_MEMORY_DIAG=1 \
        D4_GATE_SAMPLE="$sample" D4_GATE_MODE="$mode" \
        bash scripts/run_d4_asic_gate.sh \
        > "$logs/${sample}_mode${mode}_${case_id}.summary.log" 2>&1
}

# Re-run the bounded startup smoke with a unique xrun library before exact cases.
D4_SYNTH_TAG="$mapping_tag" D4_GATE_TAG="$gate_tag" \
    D4_GATE_CASE_ID=a2_startup D4_GATE_START_PROBE=1 D4_GATE_PREPARED=1 \
    D4_GATE_CELL_MODE=specify D4_GATE_MEMORY_DIAG=1 \
    bash scripts/run_d4_asic_gate.sh > "$private_job/startup.summary.log" 2>&1
grep -q '^D4_GATE_START_PROBE_PASS cycles=34 input_beats=16 controls_known=1$' \
    "$logs/start_probe.log"

# At most two independent xrun case libraries are active at any time.
for mode in 0 2; do
    pids=()
    for sample in sample_0 sample_synthetic_checkerboard; do
        run_one "$sample" "$mode" &
        pids+=("$!")
    done
    failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    if [[ $failed != 0 ]]; then
        echo "D4_A2_SYNC_GATE_CASE_FAIL mode=$mode"
        exit 1
    fi
done

python3 - "$root" "$private_job" "$logs" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, job, logs = map(Path, sys.argv[1:])
identity_path = job / 'source_identity.json'
identity = json.loads(identity_path.read_text())
raw = {}
for sample in ('sample_0', 'sample_synthetic_checkerboard'):
    for mode in (0, 2):
        name = f'{sample}_mode{mode}.log'
        path = logs / name
        if not path.is_file():
            raise SystemExit(f'missing raw gate log: {path}')
        raw[name] = hashlib.sha256(path.read_bytes()).hexdigest()
identity['remote_raw_log_sha256'] = raw
identity.pop('identity_sha256', None)
identity['identity_sha256'] = hashlib.sha256(
    json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()
).hexdigest()
identity_path.write_text(json.dumps(identity, indent=2) + '\n')
print('D4_A2_SYNC_GATE_RUN_PASS cases=4 exact_inferences=8 max_parallel=2')
print(f'D4_A2_SYNC_GATE_IDENTITY_SHA256={identity["identity_sha256"]}')
PY
