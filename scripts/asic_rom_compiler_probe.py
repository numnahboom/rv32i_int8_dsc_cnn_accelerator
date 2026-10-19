#!/usr/bin/env python3
"""Server-only compiler capability probe; synthetic pattern, not D4 PPA."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "build/asic_macros/rom_format_probe"
out.mkdir(parents=True,exist_ok=True)
code = out / "code.bits"
# Compiler reports 2048 code bits for a 256x8 ROM; use explicit binary words.
code.write_text("".join("{:08b}\n".format(x) for x in range(256)))
env = dict(os.environ)
env["VERISILICON_MC_DIR"] = "/opt/pdk/smic0.18um/MC/RHEL5_x86_64"
command = [env["VERISILICON_MC_DIR"]+"/MC", "-lib", "smic_drom.18", "-block", "D4ROM_PROBE8",
           "-outdir", str(out), "-wordsnumber", "256", "-bitsnumber", "8", "-muxwidth", "8",
           "-codefile", str(code)]
with (out / "compiler.console.log").open("w") as log:
    result = subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
print(json.dumps({"reported_exit":result.returncode,"synthetic_probe":True,
                  "generated_files":[p.name for p in sorted(out.glob("*"))]},sort_keys=True))
print("\n".join((out / "compiler.console.log").read_text().splitlines()[-12:]))
model = out / "D4ROM_PROBE8.v"
if model.exists():
    text=model.read_text()
    old='"D4ROM_PROBE8.dat"'
    if text.count(old)!=1 or not (out/'D4ROM_PROBE8.dat').exists():
        raise RuntimeError('Unexpected ROM simulation data dependency')
    (out/'D4ROM_PROBE8_sim.v').write_text(text.replace(old,'"'+str(out/'D4ROM_PROBE8.dat')+'"'))
    # Interface only. Never copy the generated model into the repository.
    lines = model.read_text().splitlines()
    for i,line in enumerate(lines):
        if line.lstrip().startswith("module "):
            print("\n".join(lines[i:i+16]))
            break
