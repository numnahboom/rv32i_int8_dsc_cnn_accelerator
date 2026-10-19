#!/usr/bin/env python3
"""Adapt generated M1..M6 LEF aliases to the matching SMIC digital technology.

Only LAYER identifiers change; geometry, ports, GDS and timing stay untouched.
The actual generated GDS identifiers must agree with the digital stream map.
All generated/derived IP views stay under build/ on the server.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT=Path(__file__).resolve().parents[1]
DK=Path('/opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a')
stream=DK/'lef/tf/180MSE_1833/encStreamout018.map'
tech=DK/'lef/tf/180MSE_1833/scc018ug_6m_1tma1.lef'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def adapt(folder):
    folder=folder.resolve()
    if (ROOT/'build').resolve() not in folder.parents:raise RuntimeError('Derived views must stay in build')
    mapping={int(i):int(layer) for i,layer in re.findall(r'^METAL([1-6])\s+NET\s+(\d+)\s+0',stream.read_text(),re.M)}
    reports=[]
    for lef in sorted(folder.glob('*.lef')):
        if lef.name.endswith(('_antenna.lef','_digital.lef')):continue
        gds=lef.with_suffix('.gds')
        if not gds.exists():raise RuntimeError('Missing generated GDS')
        data=gds.read_bytes();offset=0;layers=collections.Counter()
        while offset<len(data):
            length,kind,dtype=struct.unpack('>HBB',data[offset:offset+4])
            if length<4:raise RuntimeError('Invalid GDS record')
            if kind==13:layers[struct.unpack('>h',data[offset+4:offset+6])[0]]+=1
            offset+=length
        text=lef.read_text()
        used=sorted({int(i) for i in re.findall(r'\bLAYER\s+M([1-6])\s*;',text)})
        for i in used:
            if i not in mapping or not layers[mapping[i]] or not re.search(r'^LAYER METAL'+str(i)+r'\s*$',tech.read_text(),re.M):
                raise RuntimeError('Metal correspondence not established: M'+str(i))
        adapted,count=re.subn(r'(\bLAYER\s+)M([1-6])(\s*;)',r'\1METAL\2\3',text)
        if count==0:raise RuntimeError('Expected compiler metal aliases')
        if re.sub(r'(\bLAYER\s+)METAL([1-6])(\s*;)',r'\1M\2\3',adapted)!=text:
            raise RuntimeError('Unexpected geometry/content change')
        target=lef.with_name(lef.stem+'_digital.lef')
        target.write_text(adapted)
        report={'source':lef.name,'adapted':target.name,'source_sha256':sha(lef),'adapted_sha256':sha(target),
                'GDS_sha256':sha(gds),'aliases':{'M'+str(i):{'digital':'METAL'+str(i),'GDS_layer':mapping[i]} for i in used},
                'replacements':count,'geometry_and_timing_changed':False,'stream_map_sha256':sha(stream)}
        reports.append(report)
    (folder/'physical_lef_adapter_manifest.json').write_text(json.dumps(reports,indent=2)+'\n')
    print('ASIC_LEF_ADAPTER_PASS folder={} views={} geometry_changes=0'.format(folder.name,len(reports)))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('folders',nargs='+',type=Path)
    for folder in p.parse_args().folders:adapt(folder)
