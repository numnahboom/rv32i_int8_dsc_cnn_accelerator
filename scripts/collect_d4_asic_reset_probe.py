#!/usr/bin/env python3
"""Export the controlled reset failure/pass without proprietary cell models."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build/reports'
folder = REPORTS / 'asic_sync_reset_probe_20261020'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
summary = REPORTS / 'asic_sync_reset_probe_contrast.summary.log'
assert 'D4_SYNC_RESET_POLICY_CONTRAST_PASS baseline_X=1 preserved_checks=1100' in summary.read_text()
paths = [summary]
cases = {}
for policy in (0, 1):
    case = folder / ('preserve_' + str(policy))
    gate = (case / 'gate.log').read_text()
    synth = (case / 'synth.log').read_text()
    assert 'D4_SYNC_RESET_SYNTH_DONE preserve=' + str(policy) in synth
    assert 'CUMSTS' not in gate and 'ELBERR' not in gate
    if policy == 0:
        assert re.search(r'SYNC_RESET_START_X index=000000000x active=0', gate)
        assert 'D4_SYNC_RESET_PROBE_PASS' not in gate
    else:
        assert re.search(r'^D4_SYNC_RESET_PROBE_PASS checks=1100 uninitialized_start=1', gate, re.M)
        assert '*F,' not in gate
    area = re.search(r'Total cell area:\s+([\d.eE+-]+)', (case / 'area.rpt').read_text())
    assert area
    cases[str(policy)] = {'hdlin_ff_always_sync_set_reset': bool(policy),
                         'gate_outcome': 'NEGATIVE_RESET_X' if policy == 0 else 'PASS',
                         'unit_cell_area_um2': float(area.group(1)),
                         'private_mapped_netlist_sha256': sha(case / 'mapped.v')}
    paths.extend(case / p for p in ('synth.log', 'gate.log', 'area.rpt'))
sources = ['rtl/asic/d4_sync_reset_probe.sv', 'sim/tb_d4_asic_sync_reset.sv',
           'scripts/asic_sync_reset_probe.tcl', 'scripts/run_d4_asic_sync_reset_probe.sh']
model = Path('/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a/verilog/scc018ug_hd_rvt.v')
record = {'status': 'RESET_POLICY_UNIT_CONTRAST_ACCEPTED', 'cases': cases,
          'source_sha256': {p: sha(ROOT / p) for p in sources},
          'private_stdcell_model_sha256': sha(model),
          'evidence_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in paths},
          'tools': {'DC': 'O-2018.06-SP5', 'Xcelium': '20.03-s001'},
          'simulation': {'SDF': False, 'functional_cell_mode': True,
                         'forced_or_initialized_DUT_state': False, 'exact_count_checks': 1100},
          'limits': ['Small input-counter experiment only; no full-network gate acceptance',
                     'No physical area/timing/power claim; unit areas are not full-core gains']}
target = REPORTS / 'd4_asic_reset_probe_acceptance_20261020.json'
target.write_text(json.dumps(record, indent=2) + '\n')
paths.append(target)
archive = ROOT / 'build/d4_asic_reset_probe_evidence_20261020.tar.gz'
with tarfile.open(str(archive), 'w:gz') as tar:
    for p in paths:
        tar.add(str(p), arcname=p.relative_to(ROOT).as_posix())
print('D4_RESET_PROBE_EVIDENCE_PASS baseline_X=1 preserved_checks=1100 archive_sha256=' + sha(archive))
