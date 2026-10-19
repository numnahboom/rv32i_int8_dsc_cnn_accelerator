#!/usr/bin/env python3
"""Keep the existing port-level scoreboard; remove RTL-only diagnostics."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'sim/tb_d4_fullnet.sv'
text = source.read_text()
text = text.replace('module tb_d4_fullnet;', 'module tb_d4_asic_gate;')
start = text.index('        if(dut.state==2) op_started=tick;')
end = text.index('        if(input_valid && input_ready)', start)
text = text[:start] + text[end:]
old = '$fatal(1,"TIMEOUT state=%0d op=%0d",dut.state,dut.op_index);'
assert text.count(old) == 1
text = text.replace(old, '$fatal(1,"TIMEOUT cycles=%0d",cycle_count);')
text = text.replace('    integer counts [0:40];', '    reg [31:0] reference_descriptors [0:1311];\n    integer counts [0:40];')
text = text.replace('dut.descriptors', 'reference_descriptors')
old = '        $readmemh({vectors,"/tap_offsets.mem"},offsets);'
assert text.count(old) == 1
text = text.replace(old, old + '\n        $readmemh({vectors,"/descriptors.mem"},reference_descriptors);')
assert 'dut.' not in text and 'TAP_MISMATCH' in text and 'FC_MISMATCH' in text
assert 'CYCLE_ACCOUNT' in text and 'DONE_UNSTABLE' in text and 'LOGIT_UNSTABLE' in text
out = ROOT / 'build/asic_gate_tb'
out.mkdir(parents=True, exist_ok=True)
(out / 'tb_d4_asic_gate.sv').write_text(text)
(out / 'manifest.json').write_text(json.dumps({
    'original_scoreboard_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'port_scoreboard_sha256': hashlib.sha256(text.encode()).hexdigest(),
    'changes': ['remove internal-state cycle diagnostics', 'timeout prints public cycle count',
                'read expected per-layer sizes from same frozen descriptor file instead of RTL hierarchy'],
    'checks_preserved': ['all 24336 intermediate words', '10 raw FC', 'input/output stability',
                         'cycle accounting', 'MAC ledger', 'completion backpressure', 'repeated start'],
    'SDF_annotated': False}, indent=2) + '\n')
print('D4_GATE_PORT_SCOREBOARD_PREPARED')
