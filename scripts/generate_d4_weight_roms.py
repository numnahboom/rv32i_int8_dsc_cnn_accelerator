#!/usr/bin/env python3
"""Build eight real fixed-weight 4096x64 ROMs on the lab server.

The compiler and generated IP views stay on the server. Input bit programs are
derived exactly from frozen weights, with the original unused padding zeroed.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "build/d4_fullnet_vectors/sample_0/weights.mem"
if hashlib.sha256(source.read_bytes()).hexdigest() != "60640760f829238cfcf059cc93e211ba42fc8377704e33d584becb86bb3f7710":
    raise RuntimeError("Frozen weights changed")
words = [int(x,16) for x in source.read_text().split()]
if len(words)>4096 or any(x>=1<<512 for x in words):
    raise RuntimeError("Unexpected weight ROM shape")
valid_words=len(words)
words += [0]*(4096-len(words))
env=dict(os.environ)
env['VERISILICON_MC_DIR']='/opt/pdk/smic0.18um/MC/RHEL5_x86_64'
manifest={"source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),
          "valid_words":valid_words,"physical_words":4096,"word_bits":512,"banks":[]}
for bank in range(8):
    cell="D4WROM{}".format(bank)
    out=ROOT/"build/asic_macros/weights"/cell
    out.mkdir(parents=True,exist_ok=True)
    data="".join("{:064b}\n".format((w>>(64*bank))&((1<<64)-1)) for w in words).encode('ascii')
    code=out/'weights.bits'
    code.write_bytes(data)
    command=[env['VERISILICON_MC_DIR']+'/MC','-lib','smic_drom.18','-block',cell,
             '-outdir',str(out),'-wordsnumber','4096','-bitsnumber','64','-muxwidth','16',
             '-codefile',str(code)]
    with (out/'compiler.console.log').open('w') as log:
        completed=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
    model=out/(cell+'.v')
    if not model.exists():
        raise RuntimeError((out/'compiler.console.log').read_text()[-2000:])
    text=model.read_text()
    old='"'+cell+'.dat"'
    if text.count(old)!=1 or not (out/(cell+'.dat')).exists():
        raise RuntimeError('Unexpected ROM simulation data dependency')
    simulation_model=out/(cell+'_sim.v')
    simulation_model.write_text(text.replace(old,'"'+str(out/(cell+'.dat'))+'"'))
    for name,value in [('Word_Width',64),('Word_Depth',4096),('Addr_Depth',12)]:
        if not re.search(r'parameter\s+'+name+r'\s*=\s*'+str(value)+r'\s*;',text):
            raise RuntimeError('ROM shape mismatch: '+cell)
    for suffix in ['.lef','.gds','_typical.lib','_worst.lib','_best.lib']:
        if not (out/(cell+suffix)).exists():
            raise RuntimeError('Missing physical ROM view: '+cell+suffix)
    manifest['banks'].append({'bank':bank,'cell':cell,'program_sha256':hashlib.sha256(data).hexdigest(),
                              'model_sha256':hashlib.sha256(model.read_bytes()).hexdigest(),
                              'compiler_exit_not_acceptance':completed.returncode})
    print('D4_WEIGHT_ROM_GENERATED bank={} cell={}'.format(bank,cell),flush=True)
target=ROOT/'build/asic_macros/weights/manifest.json'
target.write_text(json.dumps(manifest,indent=2)+'\n')
print('D4_WEIGHT_ROMS_GENERATION_PASS banks=8 words=4096 bits=512')
