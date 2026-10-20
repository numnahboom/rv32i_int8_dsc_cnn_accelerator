#!/usr/bin/env python3
"""Bind returned formal proof to accepted generated RTL and private mapping."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
archive = ROOT / 'artifacts/d4_asic_formal_evidence_20261020.tar.gz'
sha = lambda b: hashlib.sha256(b).hexdigest()
with tarfile.open(str(archive)) as tar:
    members = tar.getmembers()
    assert len({m.name for m in members}) == len(members)
    for m in members:
        p = PurePosixPath(m.name)
        assert m.isfile() and not p.is_absolute() and '..' not in p.parts
        assert p.parts[:2] == ('build', 'reports') and p.suffix in ('.json', '.log', '.rpt')
    contents = {m.name: tar.extractfile(m).read() for m in members}
report = json.loads(contents['build/reports/d4_asic_formal_acceptance_20261020.json'])
for path, digest in report['evidence_sha256'].items():
    assert sha(contents[path]) == digest
mapping = json.loads((ROOT / 'artifacts/d4_asic_synth_root_acceptance_20261020.json').read_text())['metrics']['candidates']['A3']
for path, digest in report['input_sha256'].items():
    if path.startswith('build/reports/asic_A3_tt_20261020/'):
        assert mapping['mapped_private_identity_sha256'][PurePosixPath(path).name] == digest
    else:
        assert sha((ROOT / path).read_bytes()) == digest
console = contents['build/reports/asic_A3_formal_20261020/console.log'].decode()
assert 'Verification SUCCEEDED' in console and '13740 Passing compare points' in console
assert re.search(r'Passing \(equivalent\)\s+652\s+0\s+0\s+0\s+252\s+12836\s+0\s+13740', console)
assert report['failing_compare_points'] == 0
assert 'No unmatched points.' in contents['build/reports/asic_A3_formal_20261020/unmatched.rpt'].decode()
# The original raw archive retains this material guidance error; the previous
# concise warning list omitted it. It is not a failed logic compare point.
svf_parse_error = bool(re.search(r'^Error:.*svf.*\(Line: 43\).*Parse error\.', console, re.M))
assert svf_parse_error
result = {'status': 'ROOT_ACCEPTED_A3_RTL_TO_MAPPED_LOGIC_PROOF_WITH_MEMORY_BOUNDARIES',
          'archive_sha256': sha(archive.read_bytes()), 'files': len(members),
          'binds_exact_accepted_mapping_and_regenerated_RTL': True,
          'passing_points': 13740, 'failing_points': 0, 'all_functional_outputs': 252,
          'all_memory_input_pins': 652, 'primary_and_macro_output_bits_matched': 1102,
          'memory_contents_proved_by_formal': False,
          'setup_warnings_and_boundary_preserved': report['warnings_retained'],
          'additional_raw_log_findings': ['SVF source-checksum guidance parse error at line43; full guidance handling not established'],
          'SVF_guidance_parse_error_retained': svf_parse_error,
          'proof_without_SVF_independently_run': False,
          'physical_timing_or_power_claim': False}
(ROOT / 'artifacts/d4_asic_formal_root_acceptance_20261020.json').write_text(json.dumps(result, indent=2) + '\n')
print('ROOT_A3_FORMAL_PASS points=13740 outputs=252 memoryInputs=652 same_mapping=true')
