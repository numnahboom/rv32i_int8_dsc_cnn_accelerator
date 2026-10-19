#!/usr/bin/env python3
"""Accept A3's complete functional/program/macro identity gates, not P&R."""
import hashlib
import json
from pathlib import Path
import re
import tarfile
from collect_d4_asic import ROOT,REPORTS,collect_functional

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def must_pass(path,marker):
    text=path.read_text()
    if marker not in text or '*F,' in text or '$readmem error' in text:raise RuntimeError('Failed gate '+str(path))
    return sha(path)
ref=collect_functional('asic_smic_asymmetric_xcelium_20261020')
full=collect_functional('asic_all_macro_xcelium_20261020')
if ref['sample_mode_epoch_metrics']!=full['sample_mode_epoch_metrics']:raise RuntimeError('A3 changed full metrics')
unit={
 'weight':must_pass(REPORTS/'d4_weight_rom_unit_20261020/unit.log','D4_WEIGHT_ROM_EXACT_PASS words=4096 bits=512 banks=8'),
 'residual':must_pass(REPORTS/'d4_residual_rom_unit_20261020/unit.log','D4_RESIDUAL_ROM_EXACT_PASS checks=32768 ports=8 used_bits=9 latency=1')}
probes={}
expected={'control_probe':'D4_ERROR_RESTART_PASS','reset_pipeline_probe':'D4_RQ_MAC_RESET_PASS',
          'completion_reset_probe':'D4_COMPLETION_RESET_PASS','start_token_probe':'D4_START_TOKEN_PROBE_PASS',
          'throughput':'D4_PACKED_START_INTERVAL cycles=258816'}
for probe,marker in expected.items():
    path=REPORTS/'asic_A3_control_probes_20261020'/(probe+'.log')
    probes[probe]=must_pass(path,marker)
    if 'D4_PACKED_FULLNET_PASS' not in path.read_text():raise RuntimeError('Probe lacks exact restart')
sources=['rtl/cnn/d4_fullnet_top.sv','rtl/asic/d4_rq_native_multiplier_lane.sv',
 'rtl/asic/d4_feature_banks_asymmetric.sv','rtl/asic/d4_smic180_sram.sv',
 'rtl/asic/d4_weight_rom_banks.sv','rtl/asic/d4_residual_rom_banks.sv',
 'sim/d4_asic_sram_monitor.sv','sim/d4_asic_asymmetric_monitor.sv',
 'build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv']
macro_dirs=[ROOT/'build/asic_macros/act_2048x128',ROOT/'build/asic_macros/act_1024x128']
macro_dirs += [ROOT/'build/asic_macros'/kind/('{}{}'.format(prefix,b)) for kind,prefix in [('weights','D4WROM'),('residual','D4RROM')] for b in range(8)]
macros={}
for folder in macro_dirs:
    cell='RASP2048X16M16' if folder.name=='act_2048x128' else ('D4_ACT_1024X128_M8' if folder.name=='act_1024x128' else folder.name)
    files=[folder/(cell+s) for s in ['.v','.gds','.lef','_digital.lef','_typical.lib','_typical.db','_worst.lib','_worst.db','_best.lib','_best.db']]
    for path in files:
        if not path.exists() or path.stat().st_size==0:raise RuntimeError('Missing actual macro view '+str(path))
    lef=(folder/(cell+'.lef')).read_text()
    w,h=map(float,re.search(r'\bSIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;',lef).groups())
    library=(folder/(cell+'_typical.lib')).read_text()
    lib_area=max(float(x) for x in re.findall(r'^\s*area\s*:\s*([\d.]+)',library,re.M))
    if abs(w*h-lib_area)>1.0:raise RuntimeError('LEF/Liberty area disagreement')
    aliases=json.loads((folder/'physical_lef_adapter_manifest.json').read_text())
    if any(a['geometry_and_timing_changed'] for a in aliases):raise RuntimeError('Physical adapter changed geometry')
    macros[cell]={'LEF_width_um':w,'LEF_height_um':h,'Liberty_area_um2':lib_area,
                 'view_sha256':{p.name:sha(p) for p in files}}
total=sum(d['Liberty_area_um2']*(2 if name=='RASP2048X16M16' else 1) for name,d in macros.items())
result={'candidate':'A3','status':'ACCEPTED_COMPLETE_NETWORK_AND_REAL_MACRO_FUNCTIONAL_STAGE',
 'functional':full,'all_metrics_equal_A1':True,'unit_log_sha256':unit,'control_probe_sha256':probes,
 'source_sha256':{s:sha(ROOT/s) for s in sources},'macros':macros,'actual_macro_instances':19,
 'macro_area_Liberty_LEF_total_um2':total,'activation_bytes':81920,'physical_weight_ROM_bytes':262144,
 'physical_residual_ROM_bytes':65536,'network_params':204090,'semantic_MAC':11645440,'ops':23290880,
 'precision':'unchanged INT8/INT32, residual signed9 lossless','full_core_PPA_accepted':False,
 'limits':['Legacy clock-shell probes are protocol compatibility only, not ASIC clock/pad evidence',
           'No full ASIC power/energy claim','Synthesis and post-route acceptance are separate gates']}
target=REPORTS/'d4_asic_A3_functional_acceptance_20261020.json';target.write_text(json.dumps(result,indent=2)+'\n')
paths=[target,ROOT/'build/asic_macros/weights/manifest.json',ROOT/'build/asic_macros/residual/manifest.json',
       ROOT/'build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/manifest.json']
paths.extend((REPORTS/full['tag']).glob('sample_*_mode[012].log'))
paths.extend((REPORTS/'asic_A3_control_probes_20261020').glob('*.log'))
paths.extend([REPORTS/'d4_weight_rom_unit_20261020/unit.log',REPORTS/'d4_residual_rom_unit_20261020/unit.log'])
archive=ROOT/'build/d4_asic_A3_functional_evidence_20261020.tar.gz'
with tarfile.open(str(archive),'w:gz') as t:
    for p in sorted(set(paths)):t.add(str(p),arcname=p.relative_to(ROOT).as_posix())
print('D4_A3_FUNCTIONAL_ACCEPTANCE_PASS exact=84 macro_instances=19 macro_area_um2={} archive_sha256={}'.format(total,sha(archive)))
