#!/usr/bin/env python3
"""Validate and package the existing A3 sync-reset specify-mode exact runs."""
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / 'artifacts/d4_asic_gate_specify_20261020'
RAW = ARTIFACT / 'raw'
IDENTITY = ARTIFACT / 'source_identity.json'
EVIDENCE = ARTIFACT / 'evidence.json'
ARCHIVE = ROOT / 'artifacts/d4_asic_gate_specify_evidence_20261020.tar.gz'
REPORT = ROOT / 'docs/reports/d4_asic_gate_evidence_20261020.md'
EXPECTED = {
    'sample_0_mode0.log': ('sample_0', 0, [255740, 255740], [0, 0]),
    'sample_0_mode2.log': ('sample_0', 2, [257890, 257818], [104, 94]),
    'sample_synthetic_checkerboard_mode0.log': ('sample_synthetic_checkerboard', 0,
                                                [255740, 255740], [0, 0]),
    'sample_synthetic_checkerboard_mode2.log': ('sample_synthetic_checkerboard', 2,
                                                [257890, 257818], [104, 94]),
}
PASS = re.compile(
    r'^D4_FULLNET_PASS mode=(\d+) epoch=(\d+) cycles=(\d+) tap_words=(\d+) '
    r'logits=(\d+) macs=(\d+) logit_stall=(\d+)$', re.M)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def canonical_sha256(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode())


def load_identity(path=IDENTITY):
    identity = json.loads(path.read_text(encoding='utf-8'))
    payload = dict(identity)
    recorded = payload.pop('identity_sha256', '')
    computed = canonical_sha256(payload)
    if recorded and recorded != computed:
        raise ValueError('source identity digest mismatch')
    if not recorded:
        identity['identity_sha256'] = computed
        path.write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    return identity, computed


def parse_log(name, content):
    if name not in EXPECTED:
        raise ValueError(f'unexpected evidence log: {name}')
    sample, mode, expected_cycles, expected_stalls = EXPECTED[name]
    text = content.decode('utf-8', errors='replace')
    lines = text.splitlines()
    stripped_lines = {line.strip() for line in lines}
    if '+epochs=2' not in stripped_lines or f'+mode={mode}' not in stripped_lines:
        raise ValueError(f'{name}: invocation options do not match case')
    if not any(f'd4_fullnet_vectors/{sample}' in line for line in lines[:20]):
        raise ValueError(f'{name}: sample identity not present in invocation')
    records = [tuple(int(v) for v in match.groups()) for match in PASS.finditer(text)]
    expected = [
        (mode, epoch, expected_cycles[epoch], 24336, 10, 11645440, expected_stalls[epoch])
        for epoch in range(2)
    ]
    if records != expected:
        raise ValueError(f'{name}: exact PASS records differ: {records!r}')
    if re.search(r'(?i)(D4_FULLNET_FAIL|\bFATAL\b|\*E,)', text):
        raise ValueError(f'{name}: failure marker found')
    return {
        'file': name,
        'sample': sample,
        'mode': mode,
        'epochs': [
            {'epoch': row[1], 'cycles': row[2], 'tap_words': row[3],
             'logits': row[4], 'macs': row[5], 'logit_stall': row[6]}
            for row in records
        ],
        'sha256': sha256(content),
        'bytes': len(content),
    }


def exact_logs(directory=RAW):
    present = {p.name for p in directory.iterdir() if p.is_file()}
    expected = set(EXPECTED)
    if present != expected:
        raise ValueError(f'raw log directory must contain exactly four selected logs; found {sorted(present)}')
    rows = []
    identity, _ = load_identity()
    remote_hashes = identity['remote_raw_log_sha256']
    if set(remote_hashes) != expected:
        raise ValueError('remote raw log hash set does not match selected cases')
    for name in sorted(EXPECTED):
        content = (directory / name).read_bytes()
        row = parse_log(name, content)
        if row['sha256'] != remote_hashes[name]:
            raise ValueError(f'{name}: transferred file hash differs from remote hash')
        rows.append(row)
    return rows


def build_evidence():
    identity, identity_sha = load_identity()
    rows = exact_logs()
    return {
        'schema_version': 1,
        'status': 'PASS_SOURCE_BOUND_EXACT_INFERENCE_EVIDENCE',
        'scope': 'A3 sync-reset mapped specify-mode inference checks',
        'source_identity_sha256': identity_sha,
        'case_count': len(rows),
        'epochs_per_case': 2,
        'exact_inferences': sum(len(row['epochs']) for row in rows),
        'runs': rows,
        'common_metrics': {'tap_words_per_epoch': 24336, 'logits_per_epoch': 10,
                           'macs_per_epoch': 11645440},
        'run_conditions': identity['run_metadata'],
        'negative_control': identity['prior_functional_define_negative_result'],
        'claims': {'timing_gate': False, '14_sample_gate': False, 'power_claim': False,
                   'sdf_annotated': False, 'timing_checks_enabled': False,
                   'pdk_model_exported': False, 'mapped_netlist_exported': False,
                   'svf_exported': False},
        'limits': [
            'Four cases only: sample_0 and synthetic checkerboard, modes 0 and 2, two epochs each.',
            'Specify propagation was exercised, but -notimingchecks disables timing checks; this is not a timing gate or STA result.',
            'No SDF, routed timing, power, 14-sample coverage, or board result is established.',
            'The earlier +define+functional four-case failure remains a separate NEGATIVE_RESULT.',
        ],
    }


def write_reproducible_tar(paths):
    with ARCHIVE.open('wb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w') as tar:
                for path in sorted(paths, key=lambda p: p.relative_to(ROOT).as_posix()):
                    if path.is_symlink() or not path.is_file():
                        raise ValueError(f'package entry must be a regular file: {path}')
                    arcname = path.relative_to(ROOT).as_posix()
                    info = tarfile.TarInfo(arcname)
                    data = path.read_bytes()
                    info.size = len(data)
                    info.mode = 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    info.mtime = 0
                    tar.addfile(info, io.BytesIO(data))


def main():
    evidence = build_evidence()
    EVIDENCE.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    package_paths = [
        *[RAW / name for name in sorted(EXPECTED)], IDENTITY, EVIDENCE,
        ROOT / 'scripts/collect_d4_asic_gate.py', ROOT / 'scripts/accept_d4_asic_gate.py', REPORT,
    ]
    write_reproducible_tar(package_paths)
    archive_hash = sha256(ARCHIVE.read_bytes())
    print(f"D4_ASIC_GATE_COLLECT_PASS exact_inferences={evidence['exact_inferences']} "
          f"cases={evidence['case_count']} source_identity={evidence['source_identity_sha256']} "
          f"archive_sha256={archive_hash} archive={ARCHIVE.relative_to(ROOT).as_posix()}")


if __name__ == '__main__':
    main()
