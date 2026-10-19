#!/usr/bin/env python3
"""Read layer identifiers from our generated macro, without exporting geometry."""
import collections
from pathlib import Path
import struct

root=Path(__file__).resolve().parents[1]
data=(root/'build/asic_macros/act_2048x128/RASP2048X16M16.gds').read_bytes()
offset=0
layers=collections.Counter()
while offset<len(data):
    length,kind,dtype=struct.unpack('>HBB',data[offset:offset+4])
    if length<4:raise RuntimeError('Invalid GDS record')
    if kind==13:
        layers[struct.unpack('>h',data[offset+4:offset+6])[0]]+=1
    offset+=length
print('SRAM_GDS_LAYER_COUNTS',sorted(layers.items()))
