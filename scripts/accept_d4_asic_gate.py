#!/usr/bin/env python3
"""Verify the public A3 sync-reset gate evidence archive and write acceptance JSON."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

from collect_d4_asic_gate import EXPECTED, canonical_sha256, parse_log, sha256

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'artifacts/d4_asic_gate_specify_evidence_20261020.tar.gz'
ACCEPTANCE = ROOT / 'artifacts/d4_asic_gate_specify_acceptance_20261020.json'
RAW_PREFIX = 'artifacts/d4_asic_gate_specify_20261020/raw/'
IDENTITY_PATH = 'artifacts/d4_asic_gate_specify_20261020/source_identity.json'
EVIDENCE_PATH = 'artifacts/d4_asic_gate_specify_20261020/evidence.json'
REPORT_PATH = 'docs/reports/d4_asic_gate_evidence_20261020.md'
COLLECTOR_PATH = 'scripts/collect_d4_asic_gate.py'
ACCEPTOR_PATH = 'scripts/accept_d4_asic_gate.py'
EXPECTED_MEMBERS = {
    *(RAW_PREFIX + name for name in EXPECTED), IDENTITY_PATH, EVIDENCE_PATH,
    REPORT_PATH, COLLECTOR_PATH, ACCEPTOR_PATH,
}
FORBIDDEN_SUFFIXES = {'.v', '.sv', '.svf', '.lib', '.db', '.lef', '.gds', '.oas', '.enc', '.dcp'}


def main():
    with tarfile.open(ARCHIVE, 'r:gz') as tar:
        members = tar.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or set(names) != EXPECTED_MEMBERS:
            raise ValueError('archive members do not match the exact public allowlist')
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
    if identity['private_mapped_netlist_identity']['exported'] is not False:
        raise ValueError('mapped netlist export is not allowed')
    if any(identity['run_metadata'][key] is not False for key in
           ('pdk_model_exported', 'mapped_netlist_exported', 'svf_exported')):
        raise ValueError('private design files are marked as exported')
    if identity['run_metadata']['timing_checks_option'] != '-notimingchecks' or identity['run_metadata']['sdf_annotated']:
        raise ValueError('run timing metadata mismatch')
    if (identity['run_metadata']['raw_logs_included_unmodified'] is not True or
            identity['run_metadata']['remote_absolute_paths_retained'] is not True):
        raise ValueError('raw log provenance metadata mismatch')

    evidence = json.loads(contents[EVIDENCE_PATH])
    if evidence['status'] != 'PASS_SOURCE_BOUND_EXACT_INFERENCE_EVIDENCE':
        raise ValueError('evidence status is not passing')
    if evidence['source_identity_sha256'] != identity_sha:
        raise ValueError('evidence references a different source identity')
    if (evidence['exact_inferences'] != 8 or evidence['case_count'] != 4 or
            evidence['epochs_per_case'] != 2):
        raise ValueError('exact inference count does not match the assigned contract')
    if evidence['claims']['timing_gate'] or evidence['claims']['14_sample_gate'] or evidence['claims']['sdf_annotated']:
        raise ValueError('evidence overstates timing, SDF, or sample coverage')
    run_rows = {row['file']: row for row in evidence['runs']}
    if set(run_rows) != set(EXPECTED):
        raise ValueError('evidence run list is not exact')
    for name in EXPECTED:
        content = contents[RAW_PREFIX + name]
        row = parse_log(name, content)
        if row != run_rows[name]:
            raise ValueError(f'packaged log did not reproduce summary: {name}')
        if row['sha256'] != identity['remote_raw_log_sha256'][name]:
            raise ValueError(f'packaged log hash differs from server: {name}')
    negative = evidence['negative_control']
    if (negative['status'] != 'NEGATIVE_RESULT' or negative['cases'] != 4 or
            negative['completed_exact_inferences'] != 0):
        raise ValueError('prior functional-define negative result was dropped or relabeled')

    archive_hash = sha256(ARCHIVE.read_bytes())
    result = {
        'schema_version': 1,
        'status': 'ACCEPTED_SOURCE_BOUND_EXACT_INFERENCE_PACKAGE',
        'archive': ARCHIVE.relative_to(ROOT).as_posix(),
        'archive_sha256': archive_hash,
        'archive_members': len(names),
        'source_identity_sha256': identity_sha,
        'cases': 4,
        'exact_inferences': 8,
        'tap_words_per_epoch': 24336,
        'logits_per_epoch': 10,
        'macs_per_epoch': 11645440,
        'cycles': {
            'mode0': {'epoch0': 255740, 'epoch1': 255740},
            'mode2': {'epoch0': 257890, 'epoch1': 257818},
        },
        'negative_functional_define_result_preserved': True,
        'timing_gate': False,
        '14_sample_gate': False,
        'sdf_annotated': False,
        'timing_checks_enabled': False,
        'pdk_model_exported': False,
        'mapped_netlist_exported': False,
        'svf_exported': False,
        'raw_logs_unmodified': True,
        'remote_absolute_paths_retained': True,
        'checks': [
            'exact archive member allowlist and no unsafe paths',
            'server SHA-256 matched for all four raw logs',
            'all eight two-epoch PASS records and metric ledgers parsed again',
            'source and private mapped-netlist identity hashes recorded',
            'timing, sample coverage, and negative-control boundaries enforced',
        ],
    }
    ACCEPTANCE.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(f"D4_ASIC_GATE_ACCEPT_PASS exact_inferences=8 cases=4 archive_sha256={archive_hash} "
          f"acceptance={ACCEPTANCE.relative_to(ROOT).as_posix()}")


if __name__ == '__main__':
    main()
