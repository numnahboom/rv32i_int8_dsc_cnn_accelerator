#!/usr/bin/env python3
"""Retain proof results, setup warnings and exact private-input identities."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build/reports'
folder = REPORTS / 'asic_A3_formal_20261020'
console = (folder / 'console.log').read_text()
assert 'Verification SUCCEEDED' in console
assert re.search(r'^D4_A3_RTL_TO_MAPPED_FORMAL_PASS ', console, re.M)
assert re.search(r'0\(0\) Unmatched reference\(implementation\) compare points', console)
assert re.search(r'0\(0\) Unmatched reference\(implementation\) primary inputs', console)
assert '13740 Passing compare points' in console
assert re.search(r'Passing \(equivalent\)\s+652\s+0\s+0\s+0\s+252\s+12836\s+0\s+13740', console)
assert re.search(r'Failing \(not equivalent\)\s+0\s+0\s+0\s+0\s+0\s+0\s+0\s+0', console)
netlist = (REPORTS / 'asic_A3_tt_20261020/mapped.v').read_text()
body = re.search(r'module d4_residual_rom_banks\b.*?endmodule', netlist, re.S).group(0)
assert 'PULLHD0 U1 ( .Z(n2) )' in body
for b in (0, 2, 4, 6):
    lo = b * 12
    pattern = r'\.A\(\{address\[' + str(lo+11) + ':' + str(lo+9) + r'\], n2,\s*address\[' + str(lo+7) + ':' + str(lo) + r'\]\}\)'
    assert re.search(pattern, body), 'Effective residual bit8 must be tied low'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
identity = ['build/reports/asic_A3_tt_20261020/' + p for p in ('mapped.v', 'mapped.ddc', 'default.svf')]
identity += ['build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv',
             'rtl/asic/d4_rq_native_multiplier_lane.sv', 'rtl/asic/d4_feature_banks_asymmetric.sv',
             'rtl/asic/d4_smic180_sram.sv', 'rtl/asic/d4_weight_rom_banks.sv', 'rtl/asic/d4_residual_rom_banks.sv']
paths = [folder / p for p in ('console.log', 'formality.log', 'black_boxes.rpt', 'unmatched.rpt')]
result = {'status': 'ACCEPTED_RTL_TO_MAPPED_LOGIC_PROOF_WITH_MEMORY_BOUNDARIES',
          'passing_compare_points': 13740, 'failing_compare_points': 0,
          'matched_functional_output_bits': 252, 'matched_memory_input_bits': 652,
          'matched_DFF_bits': 12836, 'unmatched_compare_points': [0, 0],
          'unmatched_primary_inputs_or_blackbox_outputs': [0, 0], 'unread_reference_points': 515,
          'input_sha256': {p: sha(ROOT / p) for p in identity},
          'executed_script_git': '1bd5a61:scripts/asic_A3_formal.tcl',
          'evidence_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in paths},
          'boundary': {'memory_instances': 19, 'macro_contents_proven_by_this_formal_run': False,
                       'macro_contents_and_protocol_evidence': 'd4_asic_A3_functional_acceptance_20261020.json'},
          'warnings_retained': ['Synopsys auto_setup and synthesis undriven handling',
             '3 array-index interpretation warnings: logit_queue and two bank_q selects',
             '20 implementation undriven nets: 16 unused lane out_valid outputs and 4 unused wrapper address bits'],
          'undriven_address_audit': 'Four effective residual macro A[8] pins are driven by PULLHD0; wrapper address bit8 unused',
          'independent_boundary_count': 'SRAM input pins 428 + weight ROM112 + residual ROM112 =652; all252 functional output bits proved',
          'limits': ['Logic proof is conditional on identical technology memory boundaries and documented RTL interpretation',
                     'No timing, macro internal implementation, physical reset electrical or complete system proof']}
target = REPORTS / 'd4_asic_formal_acceptance_20261020.json'
target.write_text(json.dumps(result, indent=2) + '\n')
paths.append(target)
archive = ROOT / 'build/d4_asic_formal_evidence_20261020.tar.gz'
with tarfile.open(str(archive), 'w:gz') as tar:
    for p in paths:
        tar.add(str(p), arcname=p.relative_to(ROOT).as_posix())
print('D4_A3_FORMAL_EVIDENCE_PASS compared=13740 failed=0 BBinputs=652 functionalOutputs=252 archive_sha256=' + sha(archive))
