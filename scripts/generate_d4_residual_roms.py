#!/usr/bin/env python3
"""Generate eight exact one-port residual ROMs, preserving eight read ports."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'build/d4_fullnet_vectors/sample_0/residual_lut.mem'
if hashlib.sha256(source.read_bytes()).hexdigest()!='76529566941244aace804bb8eaaef340c26577cfbe85a43442f0f1c1bca04c3b':
    raise RuntimeError('Frozen residual table changed')
raw=[int(x,16) for x in source.read_text().split()]
signed=[x if x<1<<31 else x-(1<<32) for x in raw]
if not all(-256<=x<=255 for x in signed):raise RuntimeError('Lossless signed9 bound failed')
valid=len(signed);words=[x&511 for x in signed]+[0]*(4096-len(signed))
program=''.join('{:016b}\n'.format(x) for x in words).encode('ascii')
env=dict(os.environ);env['VERISILICON_MC_DIR']='/opt/pdk/smic0.18um/MC/RHEL5_x86_64'
manifest={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'valid_words':valid,
          'word_bits_used':9,'physical_word_bits':16,'physical_words':4096,'ports':8,'banks':[]}
for bank in range(8):
    cell='D4RROM'+str(bank);out=ROOT/'build/asic_macros/residual'/cell;out.mkdir(parents=True,exist_ok=True)
    code=out/'residual.bits';code.write_bytes(program)
    command=[env['VERISILICON_MC_DIR']+'/MC','-lib','smic_drom.18','-block',cell,'-outdir',str(out),
             '-wordsnumber','4096','-bitsnumber','16','-muxwidth','16','-codefile',str(code)]
    with (out/'compiler.console.log').open('w') as log:
        result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
    model=out/(cell+'.v')
    if not model.exists():raise RuntimeError((out/'compiler.console.log').read_text()[-2000:])
    text=model.read_text()
    for name,value in [('Word_Width',16),('Word_Depth',4096),('Addr_Depth',12)]:
        if not re.search(r'parameter\s+'+name+r'\s*=\s*'+str(value)+r'\s*;',text):raise RuntimeError('ROM shape')
    token='"'+cell+'.dat"'
    if text.count(token)!=1 or not (out/(cell+'.dat')).exists():raise RuntimeError('ROM data dependency')
    (out/(cell+'_sim.v')).write_text(text.replace(token,'"'+str(out/(cell+'.dat'))+'"'))
    for suffix in ['.lef','.gds','_typical.lib','_worst.lib','_best.lib']:
        if not (out/(cell+suffix)).exists():raise RuntimeError('Missing residual ROM physical view')
    manifest['banks'].append({'cell':cell,'model_sha256':hashlib.sha256(model.read_bytes()).hexdigest(),
                              'program_sha256':hashlib.sha256(program).hexdigest(),'compiler_exit':result.returncode})
    print('D4_RESIDUAL_ROM_GENERATED bank='+str(bank),flush=True)
(ROOT/'build/asic_macros/residual/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('D4_RESIDUAL_ROMS_GENERATION_PASS ports=8 used_bits=9 physical_bits=16 precision_loss=0')
