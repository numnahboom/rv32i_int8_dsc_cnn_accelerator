#!/usr/bin/env python3
"""Root review of returned, public A3 evidence; never imports PDK views."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    archive = ROOT / 'artifacts/d4_asic_A3_functional_evidence_20261020.tar.gz'
    with tarfile.open(str(archive)) as tar:
        members = tar.getmembers()
        names = [m.name for m in members]
        assert len(names) == len(set(names))
        for m in members:
            p = PurePosixPath(m.name)
            assert m.isfile() and not p.is_absolute() and '..' not in p.parts
            assert p.parts[0] == 'build'
            assert p.suffix in ('.json', '.log')  # public evidence only
        contents = {m.name: tar.extractfile(m).read() for m in members}
    record = json.loads(contents['build/reports/d4_asic_A3_functional_acceptance_20261020.json'])
    checks = {p: digest((ROOT / p).read_bytes()) == h for p, h in record['source_sha256'].items()}
    assert all(checks.values()), checks
    functional = record['functional']
    assert functional['inferences'] == 84 and len(functional['log_sha256']) == 42
    for name, h in functional['log_sha256'].items():
        data = contents['build/reports/{}/{}'.format(functional['tag'], name)]
        assert digest(data) == h
        text = data.decode()
        assert '*F,' not in text and 'TAP_MISMATCH' not in text and '$readmem error' not in text
        rows = re.findall(r'^D4_FULLNET_PASS (.*)$', text, re.M)
        assert rows == functional['sample_mode_epoch_metrics'][name] and len(rows) == 2
        for row in rows:
            fields = dict((k, int(v)) for k, v in re.findall(r'(\w+)=(\d+)', row))
            assert (fields['tap_words'], fields['logits'], fields['macs']) == (24336, 10, 11645440)
            if fields['mode'] == 0:
                assert fields['cycles'] == 255740
    baseline_archive = ROOT / 'artifacts/d4_asic_asymmetric_evidence_20261020.tar.gz'
    with tarfile.open(str(baseline_archive)) as tar:
        path = next(m.name for m in tar.getmembers() if m.name.endswith('acceptance_20261020.json'))
        baseline = json.load(tar.extractfile(path))
    # Identify the accepted A1 functional object without depending on its label.
    previous = next(v for v in baseline.values() if isinstance(v, dict) and 'sample_mode_epoch_metrics' in v)
    assert previous['sample_mode_epoch_metrics'] == functional['sample_mode_epoch_metrics']
    markers = {'control_probe': 'D4_ERROR_RESTART_PASS',
               'reset_pipeline_probe': 'D4_RQ_MAC_RESET_PASS',
               'completion_reset_probe': 'D4_COMPLETION_RESET_PASS',
               'start_token_probe': 'D4_START_TOKEN_PROBE_PASS',
               'throughput': 'D4_PACKED_START_INTERVAL cycles=258816'}
    for probe, h in record['control_probe_sha256'].items():
        data = contents['build/reports/asic_A3_control_probes_20261020/' + probe + '.log']
        assert digest(data) == h and markers[probe].encode() in data
        assert b'D4_PACKED_FULLNET_PASS' in data and b'*F,' not in data
    units = {'weight': ('d4_weight_rom_unit_20261020', 'D4_WEIGHT_ROM_EXACT_PASS words=4096 bits=512 banks=8'),
             'residual': ('d4_residual_rom_unit_20261020', 'D4_RESIDUAL_ROM_EXACT_PASS checks=32768 ports=8 used_bits=9 latency=1')}
    for kind, (folder, marker) in units.items():
        data = contents['build/reports/' + folder + '/unit.log']
        assert digest(data) == record['unit_log_sha256'][kind] and marker.encode() in data
        assert b'*F,' not in data
    area = sum(m['LEF_width_um'] * m['LEF_height_um'] * (2 if n == 'RASP2048X16M16' else 1)
               for n, m in record['macros'].items())
    assert len(record['macros']) == 18 and record['actual_macro_instances'] == 19
    assert abs(area - record['macro_area_Liberty_LEF_total_um2']) < 1e-5
    for m in record['macros'].values():
        assert abs(m['LEF_width_um'] * m['LEF_height_um'] - m['Liberty_area_um2']) < 1e-5
    result = {'status': 'ROOT_ACCEPTED_A3_FULL_FUNCTIONAL', 'archive_sha256': digest(archive.read_bytes()),
              'files': len(members), 'source_checks': checks, 'exact_inferences': 84,
              'all_sample_mode_epoch_metrics_equal_A1': True, 'unit_and_control_logs_verified': True,
              'macro_instances': 19, 'macro_area_Liberty_LEF_um2': area,
              'activation_KiB': 80, 'full_core_PPA_accepted': False,
              'limits': ['Macro view identities and geometry recorded by server; proprietary views stay there',
                         'No ASIC power, routed timing, full-network formal or RTL test10k claim']}
    target = ROOT / 'artifacts/d4_asic_A3_root_acceptance_20261020.json'
    target.write_text(json.dumps(result, indent=2) + '\n')
    print('ROOT_A3_FUNCTIONAL_PASS files={} sources={} full_exact=84 macro_area_um2={}'.format(len(members), len(checks), area))


if __name__ == '__main__':
    main()
