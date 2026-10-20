#!/usr/bin/env python3
"""Verify the public A2 sync-reset gate evidence archive."""
import hashlib
import json
from pathlib import PurePosixPath
import tarfile

from collect_d4_asic_A2_sync_gate import (
    EXPECTED, IDENTITY, EVIDENCE, ARCHIVE, REPORT, canonical_sha256, parse_log,
    parse_startup, sha256, verify_identity,
)

ROOT_PREFIX = 'artifacts/d4_asic_A2_sync_gate_20261020/'
RAW_PREFIX = ROOT_PREFIX + 'raw/'
IDENTITY_PATH = ROOT_PREFIX + 'source_identity.json'
EVIDENCE_PATH = ROOT_PREFIX + 'evidence.json'
REPORT_PATH = 'docs/reports/d4_asic_A2_sync_gate_20261020.md'
RUNNER_PATH = 'scripts/run_d4_asic_A2_sync_gate.sh'
COLLECTOR_PATH = 'scripts/collect_d4_asic_A2_sync_gate.py'
ACCEPTOR_PATH = 'scripts/accept_d4_asic_A2_sync_gate.py'
EXPECTED_MEMBERS = {
    *(RAW_PREFIX + name for name in EXPECTED),
    RAW_PREFIX + 'startup_probe.log', IDENTITY_PATH, EVIDENCE_PATH,
    REPORT_PATH, RUNNER_PATH, COLLECTOR_PATH, ACCEPTOR_PATH,
}
FORBIDDEN_SUFFIXES = {'.v', '.sv', '.svf', '.lib', '.db', '.lef', '.gds', '.oas', '.enc', '.dcp'}


def main():
    with tarfile.open(ARCHIVE, 'r:gz') as tar:
        members = tar.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or set(names) != EXPECTED_MEMBERS:
            raise ValueError('archive members differ from the exact public allowlist')
        contents = {}
        for member in members:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or '..' in path.parts or
                    path.suffix.lower() in FORBIDDEN_SUFFIXES):
                raise ValueError(f'unsafe or private archive member: {member.name}')
            contents[member.name] = tar.extractfile(member).read()

    identity = json.loads(contents[IDENTITY_PATH])
    identity_payload = dict(identity)
    recorded_identity_sha = identity_payload.pop('identity_sha256', '')
    identity_sha = canonical_sha256(identity_payload)
    if recorded_identity_sha != identity_sha:
        raise ValueError('source identity hash mismatch')
    verify_identity(identity)

    evidence = json.loads(contents[EVIDENCE_PATH])
    if (evidence['status'] != 'PASS_SOURCE_BOUND_A2_EXACT_INFERENCE_EVIDENCE' or
            evidence['source_identity_sha256'] != identity_sha):
        raise ValueError('evidence status or source identity mismatch')
    if (evidence['case_count'] != 4 or evidence['epochs_per_case'] != 2 or
            evidence['exact_inferences'] != 8):
        raise ValueError('exact inference count does not match the assigned gate')
    claims = evidence['claims']
    if (claims['same_sync_reset_policy_as_A3'] is not True or
            claims['timing_gate'] is not False or claims['post_route'] is not False or
            claims['power_claim'] is not False or claims['14_sample_gate'] is not False or
            claims['sdf_annotated'] is not False or claims['timing_checks_enabled'] is not False):
        raise ValueError('evidence claims exceed the assigned scope')

    startup = parse_startup(contents[RAW_PREFIX + 'startup_probe.log'])
    if startup != evidence['startup_probe']:
        raise ValueError('packaged startup probe does not reproduce evidence')
    rows = {row['file']: row for row in evidence['runs']}
    if set(rows) != set(EXPECTED):
        raise ValueError('evidence run list differs from the exact four-case matrix')
    for name in EXPECTED:
        content = contents[RAW_PREFIX + name]
        row = parse_log(name, content)
        if row != rows[name]:
            raise ValueError(f'packaged raw log does not reproduce evidence: {name}')
        if row['sha256'] != identity['remote_raw_log_sha256'][name]:
            raise ValueError(f'packaged log differs from the server hash: {name}')

    workspace = ARCHIVE.parents[1]
    if contents[IDENTITY_PATH] != IDENTITY.read_bytes():
        raise ValueError('packaged source identity differs from workspace artifact')
    if contents[EVIDENCE_PATH] != EVIDENCE.read_bytes():
        raise ValueError('packaged evidence differs from workspace artifact')
    if contents[REPORT_PATH] != REPORT.read_bytes():
        raise ValueError('packaged report differs from workspace artifact')
    if sha256(contents[RUNNER_PATH]) != identity['runner_sha256']:
        raise ValueError('packaged A2 runner differs from source identity')
    if sha256(contents[COLLECTOR_PATH]) != sha256((workspace / 'scripts/collect_d4_asic_A2_sync_gate.py').read_bytes()):
        raise ValueError('packaged collector differs from workspace source')
    if sha256(contents[ACCEPTOR_PATH]) != sha256((workspace / 'scripts/accept_d4_asic_A2_sync_gate.py').read_bytes()):
        raise ValueError('packaged acceptor differs from workspace source')

    archive_sha = sha256(ARCHIVE.read_bytes())
    result = {
        'schema_version': 1,
        'status': 'ACCEPTED_SOURCE_BOUND_A2_EXACT_INFERENCE_PACKAGE',
        'archive': ARCHIVE.relative_to(ARCHIVE.parents[1]).as_posix(),
        'archive_sha256': archive_sha,
        'archive_members': len(names),
        'source_identity_sha256': identity_sha,
        'mapped_netlist_sha256': identity['mapping']['mapped_netlist_sha256'],
        'reset_policy': identity['mapping']['reset_policy'],
        'cases': 4,
        'exact_inferences': 8,
        'tap_words_per_epoch': 24336,
        'logits_per_epoch': 10,
        'macs_per_epoch': 11645440,
        'startup_probe_sha256': startup['sha256'],
        'cycles': {
            'mode0': {'epoch0': 255740, 'epoch1': 255740},
            'mode2': {'epoch0': 257890, 'epoch1': 257818},
        },
        'same_sync_reset_policy_as_A3': True,
        'timing_gate': False,
        'post_route': False,
        'power_claim': False,
        '14_sample_gate': False,
        'sdf_annotated': False,
        'timing_checks_enabled': False,
        'pdk_model_exported': False,
        'mapped_netlist_exported': False,
        'svf_exported': False,
        'raw_logs_unmodified': True,
        'checks': [
            'exact archive allowlist, regular files, safe paths, and no private design suffixes',
            'source identity and fixed A2 map/reset policy hashes verified',
            'all four raw case logs matched lab-host SHA-256 and exact epoch metrics',
            'startup probe raw log matched expected cycle, beat, and known-control result',
            'timing, post-route, power, sample-coverage, and export claim limits enforced',
        ],
    }
    acceptance = ARCHIVE.parents[1] / 'artifacts/d4_asic_A2_sync_gate_acceptance_20261020.json'
    acceptance.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f"D4_ASIC_A2_SYNC_GATE_ACCEPT_PASS exact_inferences=8 cases=4 "
          f"archive_sha256={archive_sha} acceptance={acceptance.relative_to(ARCHIVE.parents[1]).as_posix()}")


if __name__ == '__main__':
    main()
