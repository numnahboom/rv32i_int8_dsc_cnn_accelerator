#!/usr/bin/env python3
"""Root acceptance of the PG component gate, explicitly excluding PPA."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
archive = ROOT / 'artifacts/d4_asic_pg_construction_evidence_20261020.tar.gz'
sha = lambda b: hashlib.sha256(b).hexdigest()
with tarfile.open(str(archive)) as tar:
    members = tar.getmembers()
    assert len({m.name for m in members}) == len(members)
    for m in members:
        p = PurePosixPath(m.name)
        assert m.isfile() and not p.is_absolute() and '..' not in p.parts
        assert p.parts[:2] == ('build', 'reports') and p.suffix in ('.json', '.log', '.rpt', '.tcl')
    contents = {m.name: tar.extractfile(m).read() for m in members}
report = json.loads(contents['build/reports/d4_asic_pg_construction_acceptance_20261020.json'])
for path, digest in report['evidence_sha256'].items():
    assert sha(contents[path]) == digest
for path, digest in report['source_sha256'].items():
    assert sha((ROOT / path).read_bytes()) == digest
folder = 'build/reports/asic_pg_shared_grid_validate_20261020/'
assert 'No DRC violations were found' in contents[folder + 'pg_drc.rpt'].decode()
for net in ('VDD', 'VSS'):
    assert re.search(r'Verification Complete\s*:\s*0 Viols\.\s*0 Wrngs\.', contents[folder + 'pg_connectivity_' + net + '.rpt'].decode())
inventory = contents[folder + 'pg_macro_inventory.rpt'].decode()
assert len(re.findall(r'^INSTANCE ', inventory, re.M)) == 19
assert len(re.findall(r'^PIN (?:VDD NET VDD|GND NET VSS)$', inventory, re.M)) == 38
mapping = json.loads((ROOT / 'artifacts/d4_asic_synth_root_acceptance_20261020.json').read_text())
assert report['private_input']['original_A3_mapped_v_sha256'] == mapping['metrics']['candidates']['A3']['mapped_private_identity_sha256']['mapped.v']
assert report['regular_trial_routes_removed'] is True
result = {'status': 'ROOT_ACCEPTED_PRECTS_PLACED_PG_COMPONENT',
          'archive_sha256': sha(archive.read_bytes()), 'files': len(members),
          'macro_instances': 19, 'PG_terminals_checked': 38, 'special_DRC': 0,
          'VDD_VSS_connectivity_errors_and_warnings': 0,
          'full_routed_core_or_new_mapping_accepted': False, 'power_or_frequency_claim': False}
(ROOT / 'artifacts/d4_asic_pg_construction_root_acceptance_20261020.json').write_text(json.dumps(result, indent=2) + '\n')
print('ROOT_PG_COMPONENT_PASS macros=19 terminals=38 PG_DRC=0 connectivity=0 routed_core_claim=0')
