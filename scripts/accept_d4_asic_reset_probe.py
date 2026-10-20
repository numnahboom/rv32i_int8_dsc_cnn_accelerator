#!/usr/bin/env python3
"""Review the negative/positive unit contrast with both raw logs retained."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
archive = ROOT / 'artifacts/d4_asic_reset_probe_evidence_20261020.tar.gz'
sha = lambda b: hashlib.sha256(b).hexdigest()
with tarfile.open(str(archive)) as tar:
    members = tar.getmembers()
    assert len({m.name for m in members}) == len(members)
    for m in members:
        p = PurePosixPath(m.name)
        assert m.isfile() and not p.is_absolute() and '..' not in p.parts
        assert p.parts[:2] == ('build', 'reports') and p.suffix in ('.json', '.log', '.rpt')
    contents = {m.name: tar.extractfile(m).read() for m in members}
report = json.loads(contents['build/reports/d4_asic_reset_probe_acceptance_20261020.json'])
for path, digest in report['source_sha256'].items():
    assert sha((ROOT / path).read_bytes()) == digest
for path, digest in report['evidence_sha256'].items():
    assert sha(contents[path]) == digest
base = 'build/reports/asic_sync_reset_probe_20261020/preserve_'
assert 'SYNC_RESET_START_X index=000000000x active=0' in contents[base + '0/gate.log'].decode()
positive = contents[base + '1/gate.log'].decode()
assert re.search(r'^D4_SYNC_RESET_PROBE_PASS checks=1100 uninitialized_start=1', positive, re.M)
assert '*F,' not in positive
assert report['simulation']['forced_or_initialized_DUT_state'] is False
result = {'status': 'ROOT_ACCEPTED_RESET_POLICY_UNIT_CONTRAST',
          'archive_sha256': sha(archive.read_bytes()), 'files': len(members),
          'baseline_reset_X_reproduced': True, 'preserved_reset_exact_checks': 1100,
          'full_network_gate_accepted': False, 'physical_or_power_claim': False}
(ROOT / 'artifacts/d4_asic_reset_probe_root_acceptance_20261020.json').write_text(json.dumps(result, indent=2) + '\n')
print('ROOT_RESET_POLICY_UNIT_CONTRAST_PASS baseline_X=1 preserved_checks=1100 full_network_claim=0')
