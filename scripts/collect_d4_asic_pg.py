#!/usr/bin/env python3
"""Export the placed/pre-CTS PG gate; no regular-route/PPA or IP-view claim."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build/reports'
folder = REPORTS / 'asic_pg_shared_grid_validate_20261020'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
console = (folder / 'console.log').read_text()
assert re.search(r'^D4_PG_GRID_CONSTRUCTION_PASS macros=19 ', console, re.M)
assert re.search(r'^D4_PRECTS_PG_VALIDATION_PASS ', console, re.M)
assert '**ERROR' not in console
assert 'No DRC violations were found' in (folder / 'pg_drc.rpt').read_text()
for net in ('VDD', 'VSS'):
    text = (folder / ('pg_connectivity_' + net + '.rpt')).read_text()
    assert re.search(r'Verification Complete\s*:\s*0 Viols\.\s*0 Wrngs\.', text)
inventory = (folder / 'pg_macro_inventory.rpt').read_text()
assert len(re.findall(r'^INSTANCE ', inventory, re.M)) == 19
assert len(re.findall(r'^PIN VDD NET VDD$', inventory, re.M)) == 19
assert len(re.findall(r'^PIN GND NET VSS$', inventory, re.M)) == 19
sources = ('asic_pg_grid.tcl', 'asic_pg_grid_validate.tcl')
for name in sources:
    assert sha(ROOT / 'scripts' / name) == sha(folder / name)
checkpoint = REPORTS / 'asic_A3_physical_20261020/placed.enc.dat'
tree = [(p.relative_to(checkpoint).as_posix(), sha(p)) for p in sorted(checkpoint.rglob('*')) if p.is_file()]
assert tree
paths = [folder / p for p in ('console.log', 'pg_drc.rpt', 'pg_macro_inventory.rpt',
         'pg_connectivity_VDD.rpt', 'pg_connectivity_VSS.rpt') + sources]
record = {'status': 'PLACED_PRECTS_PG_CONSTRUCTION_PASS',
          'macros': 19, 'audited_PG_terminals': 38, 'special_DRC': 0,
          'VDD_connectivity_errors': 0, 'VSS_connectivity_errors': 0,
          'PG_connectivity_warnings': 0,
          'source_sha256': {'scripts/' + name: sha(folder / name) for name in sources},
          'private_input': {'placed_checkpoint': checkpoint.relative_to(ROOT).as_posix(),
                            'files_hashed': len(tree),
                            'tree_sha256': hashlib.sha256(json.dumps(tree, separators=(',', ':')).encode()).hexdigest(),
                            'original_A3_mapped_v_sha256': sha(REPORTS / 'asic_A3_tt_20261020/mapped.v')},
          'evidence_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in paths},
          'regular_trial_routes_removed': True,
          'scope': 'Original A3 placed checkpoint, shared core-first/macro-second PG, native trimming',
          'limits': ['No signal routing or post-route timing/power acceptance',
                     'Not a PG acceptance transfer to the new reset-policy mapping',
                     'No IR-drop/EM or foundry signoff claim; proprietary views remain on server']}
target = REPORTS / 'd4_asic_pg_construction_acceptance_20261020.json'
target.write_text(json.dumps(record, indent=2) + '\n')
paths.append(target)
archive = ROOT / 'build/d4_asic_pg_construction_evidence_20261020.tar.gz'
with tarfile.open(str(archive), 'w:gz') as tar:
    for p in paths:
        tar.add(str(p), arcname=p.relative_to(ROOT).as_posix())
print('D4_PG_CONSTRUCTION_EVIDENCE_PASS macros=19 terminals=38 PG_DRC=0 archive_sha256=' + sha(archive))
