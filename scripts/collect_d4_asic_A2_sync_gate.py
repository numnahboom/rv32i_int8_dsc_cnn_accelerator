#!/usr/bin/env python3
"""Validate and package the fixed A2 sync-reset specify-mode gate runs."""
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / 'artifacts/d4_asic_A2_sync_gate_20261020'
RAW = ARTIFACT / 'raw'
IDENTITY = ARTIFACT / 'source_identity.json'
EVIDENCE = ARTIFACT / 'evidence.json'
ARCHIVE = ROOT / 'artifacts/d4_asic_A2_sync_gate_evidence_20261020.tar.gz'
REPORT = ROOT / 'docs/reports/d4_asic_A2_sync_gate_20261020.md'
RUNNER = ROOT / 'scripts/run_d4_asic_A2_sync_gate.sh'
EXPECTED = {
    'sample_0_mode0.log': ('sample_0', 0, [255740, 255740], [0, 0]),
    'sample_0_mode2.log': ('sample_0', 2, [257890, 257818], [104, 94]),
    'sample_synthetic_checkerboard_mode0.log': (
        'sample_synthetic_checkerboard', 0, [255740, 255740], [0, 0]),
    'sample_synthetic_checkerboard_mode2.log': (
        'sample_synthetic_checkerboard', 2, [257890, 257818], [104, 94]),
}
PASS = re.compile(
    r'^D4_FULLNET_PASS mode=(\d+) epoch=(\d+) cycles=(\d+) tap_words=(\d+) '
    r'logits=(\d+) macs=(\d+) logit_stall=(\d+)$', re.M)
STARTUP_PASS = 'D4_GATE_START_PROBE_PASS cycles=34 input_beats=16 controls_known=1'
EXPECTED_NETLIST_SHA = '7a42e9c61090181cee0c8212e0cf65f83693f1bdfb1027948b108290dbd5c0bd'
EXPECTED_SCOREBOARD_SHA = '2625b464314fad7a7591b4d9226d5ab49704a4e544d1767efbc9ca1496400ca5'
EXPECTED_GENERIC_RUNNER_SHA = '1b3eb273504a5356b4075bfe320ce4dd97e7de8037a22d55f1003c133450ad09'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def canonical_sha256(value):
    return sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode())


def load_identity(path=IDENTITY):
    identity = json.loads(path.read_text(encoding='utf-8'))
    payload = dict(identity)
    recorded = payload.pop('identity_sha256', '')
    computed = canonical_sha256(payload)
    if not recorded or recorded != computed:
        raise ValueError('source identity digest mismatch')
    return identity, computed


def verify_identity(identity):
    mapping = identity['mapping']
    gate = identity['gate']
    hashes = identity['source_hashes']
    if (identity['status'] != 'A2_SYNC_RESET_SPECIFY_RUN_IDENTITY' or
            mapping['candidate'] != 'A2' or
            mapping['mapped_netlist_sha256'] != EXPECTED_NETLIST_SHA or
            mapping['reset_policy'] != 'hdlin_ff_always_sync_set_reset=1' or
            mapping['SRAMs'] != 3 or mapping['programmed_ROMs'] != 8 or
            mapping['post_route'] is not False or mapping['power_claim'] is not False or
            mapping['mapping_sources_check_passed'] is not True):
        raise ValueError('fixed A2 mapping identity or claims mismatch')
    if (gate['cell_mode'] != 'specify' or gate['functional_define'] is not False or
            gate['timing_checks_option'] != '-notimingchecks' or
            gate['sdf_annotated'] is not False or
            gate['memory_diagnostics_enabled'] is not True or
            gate['pdk_model_exported'] is not False or
            gate['mapped_netlist_exported'] is not False or
            gate['svf_exported'] is not False or
            gate['case_concurrency_limit'] > 2 or
            gate['raw_logs_included_unmodified'] is not True):
        raise ValueError('gate execution policy or export boundary mismatch')
    if identity['scoreboard_sha256'] != EXPECTED_SCOREBOARD_SHA or \
            identity['scoreboard_sha256_expected'] != EXPECTED_SCOREBOARD_SHA:
        raise ValueError('executed scoreboard hash mismatch')
    if identity['generic_runner_sha256'] != EXPECTED_GENERIC_RUNNER_SHA:
        raise ValueError('generic gate runner hash mismatch')
    if identity['runner_sha256'] != sha256(RUNNER.read_bytes()):
        raise ValueError('packaged A2 runner differs from executed runner')
    if hashes.get('build/asic_gate_tb/tb_d4_asic_gate.sv') != EXPECTED_SCOREBOARD_SHA:
        raise ValueError('source hash map does not bind the required scoreboard')
    mapped_path = mapping['mapped_netlist']
    if hashes.get(mapped_path) != EXPECTED_NETLIST_SHA:
        raise ValueError('source hash map does not bind the fixed A2 netlist')
    reset_path = mapping['mapped_netlist'].rsplit('/', 1)[0] + '/reset_policy.txt'
    if not re.fullmatch(r'[0-9a-f]{64}', hashes.get(reset_path, '')):
        raise ValueError('source hash map does not bind the reset policy file')
    manifest_path = mapping['mapped_netlist'].rsplit('/', 1)[0] + '/executed_sources.sha256'
    if hashes.get(manifest_path) != mapping['mapping_source_manifest_sha256']:
        raise ValueError('source hash map does not bind the synthesis input manifest')
    expected_cases = [
        {'sample': sample, 'mode': mode, 'epochs': 2}
        for sample in ('sample_0', 'sample_synthetic_checkerboard')
        for mode in (0, 2)
    ]
    if gate['case_plan'] != expected_cases:
        raise ValueError('case plan differs from the fixed four-case matrix')


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
        raise ValueError(f'{name}: vector identity is absent from invocation')
    records = [tuple(int(value) for value in match.groups()) for match in PASS.finditer(text)]
    expected = [
        (mode, epoch, expected_cycles[epoch], 24336, 10, 11645440, expected_stalls[epoch])
        for epoch in range(2)
    ]
    if records != expected:
        raise ValueError(f'{name}: exact PASS records differ: {records!r}')
    if re.search(r'(?i)(D4_FULLNET_FAIL|GATE_UNKNOWN_CONTROL|GATE_START_UNKNOWN|\bFATAL\b|\*E,)', text):
        raise ValueError(f'{name}: fatal, unknown-control, or failure marker found')
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


def parse_startup(content, name='startup_probe.log'):
    text = content.decode('utf-8', errors='replace')
    if text.count(STARTUP_PASS) != 1:
        raise ValueError('startup probe did not contain exactly one expected PASS')
    if re.search(r'(?i)(GATE_START_UNKNOWN|GATE_START_TIMEOUT|\bFATAL\b|\*E,)', text):
        raise ValueError('startup probe contains a failure marker')
    return {'file': name, 'sha256': sha256(content), 'bytes': len(content),
            'result': STARTUP_PASS}


def verify_startup(path=RAW / 'startup_probe.log'):
    return parse_startup(path.read_bytes(), path.name)


def exact_logs(directory=RAW):
    present = {path.name for path in directory.iterdir() if path.is_file()}
    expected = set(EXPECTED) | {'startup_probe.log'}
    if present != expected:
        raise ValueError(f'raw log directory must contain exactly five selected logs; found {sorted(present)}')
    identity, _ = load_identity()
    if set(identity['remote_raw_log_sha256']) != set(EXPECTED):
        raise ValueError('remote raw-log hash set differs from the four full-network cases')
    rows = []
    for name in sorted(EXPECTED):
        content = (directory / name).read_bytes()
        row = parse_log(name, content)
        if row['sha256'] != identity['remote_raw_log_sha256'][name]:
            raise ValueError(f'{name}: local raw log differs from server hash')
        rows.append(row)
    return rows


def build_evidence():
    identity, identity_sha = load_identity()
    verify_identity(identity)
    rows = exact_logs()
    startup = verify_startup()
    return {
        'schema_version': 1,
        'status': 'PASS_SOURCE_BOUND_A2_EXACT_INFERENCE_EVIDENCE',
        'scope': 'A2 fixed sync-reset mapped specify-mode full-network inference checks',
        'source_identity_sha256': identity_sha,
        'startup_probe': startup,
        'case_count': len(rows),
        'epochs_per_case': 2,
        'exact_inferences': sum(len(row['epochs']) for row in rows),
        'runs': rows,
        'common_metrics': {'tap_words_per_epoch': 24336, 'logits_per_epoch': 10,
                           'macs_per_epoch': 11645440},
        'mapping_summary': identity['mapping'],
        'run_conditions': identity['gate'],
        'claims': {
            'exact_inference_gate': True,
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
        },
        'limits': [
            'Four selected sample/mode cases only, with two epochs per case; this is not the original 84-run RTL baseline.',
            'Real standard-cell and SRAM/ROM models were used in specify mode, but -notimingchecks disables timing checks.',
            'No SDF, routed timing, power, 14-sample coverage, or board result is established.',
            'The A2 mapped-area and timing summary is pre-route synthesis data, not physical acceptance.',
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


def build_report(evidence):
    identity, identity_sha = load_identity()
    lines = [
        '# D4 A2 sync-reset mapped-gate evidence',
        '',
        'The fixed A2 TT 10 ns mapping preserves `hdlin_ff_always_sync_set_reset=1`, matching the A3 sync-reset policy. The real mapped netlist passed a bounded startup probe and four specify-mode full-network cases with the frozen port-level scoreboard. The selected matrix is the same sample/mode matrix used for the A3 backend comparison.',
        '',
        f"Source identity SHA-256: `{identity_sha}`  ",
        f"Mapped netlist SHA-256: `{identity['mapping']['mapped_netlist_sha256']}`  ",
        f"Mapped area including macros: {identity['mapping']['cell_area_including_macros_um2']:,.6f} µm² (pre-route synthesis)",
        '',
        '| Sample | Mode | Epoch 0 cycles | Epoch 1 cycles | Stalls (epoch 0 / 1) |',
        '|---|---:|---:|---:|---:|',
    ]
    for row in evidence['runs']:
        ep0, ep1 = row['epochs']
        lines.append(
            f"| `{row['sample']}` | {row['mode']} | {ep0['cycles']:,} | {ep1['cycles']:,} | "
            f"{ep0['logit_stall']} / {ep1['logit_stall']} |"
        )
    lines += [
        '',
        'Each epoch checked 24,336 intermediate words, 10 logits, and 11,645,440 MACs. Both mode-0 epochs completed at 255,740 cycles. Mode 2 completed at 257,890 and 257,818 cycles, with 104 and 94 logit stalls. The startup probe passed at cycle 34 after 16 accepted input beats with known controls.',
        '',
        'The simulation used Cadence Xcelium 20.03-s001, the real standard-cell model default specify propagation behavior, and real SRAM/ROM simulation models. It used `-notimingchecks`, no SDF, no `+define+functional`, and the passive memory diagnostic. This is an exact-inference gate only: it establishes no timing-check, STA, routed, power, 14-sample, or board result. The A2 mapped area is pre-route synthesis data. The historical 84-run actual-model RTL baseline remains a separate evidence layer.',
        '',
        'The public archive contains five original raw logs (the startup probe and four full-network cases), source identity and run evidence, this report, and the A2 runner/collector/acceptor. It excludes the PDK model, mapped netlist, and SVF. Raw case logs were checked byte-for-byte against hashes computed on the lab host.',
        '',
        f"See [`artifacts/d4_asic_A2_sync_gate_acceptance_20261020.json`](../../artifacts/d4_asic_A2_sync_gate_acceptance_20261020.json) for the machine-checked package result.",
        '',
    ]
    return '\n'.join(lines)


def main():
    evidence = build_evidence()
    EVIDENCE.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    REPORT.write_text(build_report(evidence), encoding='utf-8')
    package_paths = [
        *[RAW / name for name in sorted(EXPECTED)], RAW / 'startup_probe.log',
        IDENTITY, EVIDENCE, REPORT, RUNNER,
        ROOT / 'scripts/collect_d4_asic_A2_sync_gate.py',
        ROOT / 'scripts/accept_d4_asic_A2_sync_gate.py',
    ]
    write_reproducible_tar(package_paths)
    archive_hash = sha256(ARCHIVE.read_bytes())
    print(f"D4_ASIC_A2_SYNC_GATE_COLLECT_PASS exact_inferences={evidence['exact_inferences']} "
          f"cases={evidence['case_count']} source_identity={evidence['source_identity_sha256']} "
          f"archive_sha256={archive_hash} archive={ARCHIVE.relative_to(ROOT).as_posix()}")


if __name__ == '__main__':
    main()
