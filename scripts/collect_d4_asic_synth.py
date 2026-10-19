#!/usr/bin/env python3
"""Export complete-core synthesis evidence without proprietary IP/netlists."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build/reports'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(pattern, text):
    match = re.search(pattern, text)
    if not match:
        raise RuntimeError('Missing synthesis metric ' + pattern)
    return float(match.group(1))


def main():
    result = {'scope': 'full_128bit_stream_core_standard_cell_synthesis',
              'corner': 'SMIC180 SCC018UG HD RVT TT 1.8V 25C',
              'period_ns': 10, 'clock_uncertainty_ns': 0.2,
              'input_output_max_delay_ns': 1, 'input_output_min_delay_ns': 0.1,
              'input_transition_ns': 0.1, 'output_load_pF': 0.01,
              'post_route': False, 'power_claim': False, 'candidates': {}}
    paths = []
    for name, suffix in [('A2', ''), ('A3', '_recovered')]:
        folder = REPORTS / ('asic_{}_tt_20261020'.format(name))
        area_path = folder / ('area' + suffix + '.rpt')
        area = area_path.read_text()
        timing_path = folder / ('timing_max' + suffix + '.rpt')
        timing = timing_path.read_text()
        total = number(r'Total cell area:\s+([\d.eE+-]+)', area)
        macro = number(r'Macro/Black Box area:\s+([\d.eE+-]+)', area)
        combinational = number(r'Combinational area:\s+([\d.eE+-]+)', area)
        registers = number(r'Noncombinational area:\s+([\d.eE+-]+)', area)
        if abs(total - macro - combinational - registers) > 1e-4:
            raise RuntimeError('Incomplete full area accounting')
        candidate = {'total_cell_area_um2': total, 'macro_area_um2': macro,
                     'combinational_area_um2': combinational, 'noncombinational_area_um2': registers,
                     'cells': int(number(r'Number of cells:\s+(\d+)', area)),
                     'reported_rounded_setup_slack_ns': number(r'slack\s+\([^)]*\)\s+([\d.eE+-]+)', timing),
                     'memory_instances': 11 if name == 'A2' else 19,
                     'mapped_checkpoint_available': name == 'A3'}
        if name == 'A3':
            recovery = folder / 'report_recovery.log'
            text = recovery.read_text()
            if not re.search(r'^D4_A3_SAVED_MAPPING_REPORT_PASS ', text, re.M) or re.search(r'^Error:', text, re.M):
                raise RuntimeError('A3 report recovery did not pass')
            candidate['exact_setup_slack_ns'] = json.loads((folder / 'result.json').read_text())['worst_setup_slack_ns']
            candidate['mapped_private_identity_sha256'] = {p: sha(folder / p) for p in ('mapped.v', 'mapped.ddc', 'default.svf')}
            paths.extend([folder / 'check_timing_recovered.rpt', folder / 'constraints_recovered.rpt',
                          folder / 'check_recovered.rpt', folder / 'result.json', recovery])
        else:
            diagnostic = (folder / 'check_timing.rpt').read_text()
            if "unknown option '-verbose'" not in diagnostic:
                raise RuntimeError('A2 diagnostic failure differs from accepted boundary')
            candidate['limit'] = 'Mapping numerical reports retained; diagnostic failed before checkpoint save'
            paths.append(folder / 'check_timing.rpt')
        paths.extend([area_path, timing_path, folder / 'macro_areas.tsv'])
        core = ROOT / ('build/asic_eval/native_asymmetric_logic_rom_mask_weights' + ('_mask_residual' if name == 'A3' else '') + '/d4_fullnet_eval.sv')
        candidate['generated_core_sha256'] = sha(core)
        result['candidates'][name] = candidate
    result['A3_total_area_increase_fraction_vs_A2'] = result['candidates']['A3']['total_cell_area_um2'] / result['candidates']['A2']['total_cell_area_um2'] - 1
    result['note'] = 'Same network, clock/IO/library conditions; only residual implementation changes. Not routed or energy superiority.'
    result['source_sha256'] = {p: sha(ROOT / p) for p in ('scripts/prepare_d4_asic.py', 'scripts/asic_A3_report_saved.tcl',
        'rtl/asic/d4_rq_native_multiplier_lane.sv', 'rtl/asic/d4_feature_banks_asymmetric.sv',
        'rtl/asic/d4_smic180_sram.sv', 'rtl/asic/d4_weight_rom_banks.sv', 'rtl/asic/d4_residual_rom_banks.sv')}
    result['evidence_sha256'] = {p.relative_to(ROOT).as_posix(): sha(p) for p in paths}
    target = REPORTS / 'd4_asic_fullcore_synth_acceptance_20261020.json'
    target.write_text(json.dumps(result, indent=2) + '\n')
    paths.append(target)
    archive = ROOT / 'build/d4_asic_fullcore_synth_evidence_20261020.tar.gz'
    with tarfile.open(str(archive), 'w:gz') as tar:
        for p in sorted(set(paths)):
            tar.add(str(p), arcname=p.relative_to(ROOT).as_posix())
    print('D4_FULLCORE_SYNTH_EVIDENCE_PASS A3area_um2={} vsA2={:+.4%} archive_sha256={}'.format(
        result['candidates']['A3']['total_cell_area_um2'], result['A3_total_area_increase_fraction_vs_A2'], sha(archive)))


if __name__ == '__main__':
    main()
