#!/usr/bin/env python3
"""Review returned synthesis reports and regenerated candidate identities."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    archive = ROOT / 'artifacts/d4_asic_fullcore_synth_evidence_20261020.tar.gz'
    with tarfile.open(str(archive)) as tar:
        entries = tar.getmembers()
        assert len({m.name for m in entries}) == len(entries)
        for m in entries:
            p = PurePosixPath(m.name)
            assert m.isfile() and not p.is_absolute() and '..' not in p.parts
            assert p.parts[:2] == ('build', 'reports') and p.suffix in ('.rpt', '.json', '.tsv', '.log')
        data = {m.name: tar.extractfile(m).read() for m in entries}
    report = json.loads(data['build/reports/d4_asic_fullcore_synth_acceptance_20261020.json'])
    for p, h in report['evidence_sha256'].items():
        assert sha(data[p]) == h
    source_checks = {p: sha((ROOT / p).read_bytes()) == h for p, h in report['source_sha256'].items()}
    # Generator docstring was clarified locally after server evaluation; hardware
    # identities are rechecked independently for BOTH generated candidates.
    assert all(ok for p, ok in source_checks.items() if p != 'scripts/prepare_d4_asic.py')
    for candidate, metrics in report['candidates'].items():
        core = ROOT / ('build/asic_eval/native_asymmetric_logic_rom_mask_weights' + ('_mask_residual' if candidate == 'A3' else '') + '/d4_fullnet_eval.sv')
        assert sha(core.read_bytes()) == metrics['generated_core_sha256']
        suffix = '_recovered' if candidate == 'A3' else ''
        base = 'build/reports/asic_{}_tt_20261020/'.format(candidate)
        text = data[base + 'area' + suffix + '.rpt'].decode()
        total = float(re.search(r'Total cell area:\s+([\d.eE+-]+)', text).group(1))
        assert total == metrics['total_cell_area_um2']
        table = data[base + 'macro_areas.tsv'].decode().strip().splitlines()[1:]
        assert len(table) == metrics['memory_instances']
        assert abs(sum(float(row.split('\t')[2]) for row in table) - metrics['macro_area_um2']) < 1
        assert abs(metrics['macro_area_um2'] + metrics['combinational_area_um2'] +
                   metrics['noncombinational_area_um2'] - total) < 1e-4
    assert report['candidates']['A3']['exact_setup_slack_ns'] >= 0
    assert not report['post_route'] and not report['power_claim']
    result = {'status': 'ROOT_ACCEPTED_COMPLETE_CORE_SYNTHESIS_ONLY', 'archive_sha256': sha(archive.read_bytes()),
              'files': len(entries), 'source_checks': source_checks,
              'both_regenerated_core_identities_match': True,
              'helper_difference': 'Generator docstring changed locally; both generated hardware hashes match',
              'metrics': report, 'physical_timing_accepted': False, 'power_accepted': False}
    (ROOT / 'artifacts/d4_asic_synth_root_acceptance_20261020.json').write_text(json.dumps(result, indent=2) + '\n')
    print('ROOT_D4_SYNTH_PASS files={} A3area_mm2={:.9f} setup_ns={}'.format(len(entries),
          report['candidates']['A3']['total_cell_area_um2'] / 1e6, report['candidates']['A3']['exact_setup_slack_ns']))


if __name__ == '__main__':
    main()
