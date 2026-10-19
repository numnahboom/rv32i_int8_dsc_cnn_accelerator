#!/usr/bin/env python3
"""Accept the one-candidate asymmetric SRAM experiment without full PPA claims."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

from collect_d4_asic import ROOT, REPORTS, collect_functional


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


a0 = collect_functional("asic_smic_sram_xcelium_20261020")
a1 = collect_functional("asic_smic_asymmetric_xcelium_20261020")
if a0["sample_mode_epoch_metrics"] != a1["sample_mode_epoch_metrics"]:
    raise RuntimeError("A1 changed cycles or network ledger")
baseline = ROOT / "build/asic_eval/native_banked_logic_rom/d4_fullnet_eval.sv"
candidate = ROOT / "build/asic_eval/native_asymmetric_logic_rom/d4_fullnet_eval.sv"
if baseline.read_text().replace("d4_feature_banks feature_banks(", "d4_feature_banks_asymmetric feature_banks(") != candidate.read_text():
    raise RuntimeError("Core delta exceeds selected memory boundary")
deep = ROOT / "build/asic_macros/act_2048x128/RASP2048X16M16.ds"
small_dir = ROOT / "build/asic_macros/act_1024x128"
small = small_dir / "D4_ACT_1024X128_M8.ds"
model = small_dir / "D4_ACT_1024X128_M8.v"
for parameter, value in (("Word_Width", 128), ("Word_Depth", 1024), ("Addr_Depth", 10)):
    if not re.search(r"parameter\s+" + parameter + r"\s*=\s*" + str(value) + r"\s*;", model.read_text()):
        raise RuntimeError("Incorrect small macro shape")
if not re.search(r"module\s+D4_ACT_1024X128_M8\s*\(", model.read_text()):
    raise RuntimeError("Macro name mismatch")
def area(path):
    return float(re.search(r"Die Area\s*=\s*([\d.]+)", path.read_text()).group(1))
before = 3*area(deep)
after = 2*area(deep)+area(small)
compile_text = (small_dir / "library_compile.log").read_text()
if "D4_ASIC_SRAM_LIBRARIES_COMPILED" not in compile_text or "Error:" in compile_text:
    raise RuntimeError("Small SRAM library compilation failed")
sources = ["rtl/asic/d4_feature_banks_asymmetric.sv", "sim/d4_asic_asymmetric_monitor.sv",
           "sim/d4_asic_sram_monitor.sv", "scripts/prepare_d4_asic.py",
           "build/asic_eval/native_asymmetric_logic_rom/d4_fullnet_eval.sv"]
views = [model,small,small_dir / "D4_ACT_1024X128_M8.lef"]
for corner in ("typical", "worst", "best"):
    for extension in ("lib", "db"):
        p = small_dir / ("D4_ACT_1024X128_M8_{}.{}".format(corner, extension))
        if not p.is_file() or p.stat().st_size == 0:
            raise RuntimeError("Missing small SRAM view")
        views.append(p)
result = {"candidate": "A1", "status": "ACCEPTED_FULL_NETWORK_ASYMMETRIC_MEMORY_FUNCTIONAL_AND_MACRO_AREA",
          "functional": a1, "all_metrics_equal_A0": True,
          "core_delta": "feature-bank implementation module only",
          "source_sha256": {p:sha(ROOT/p) for p in sources},
          "macro_view_sha256": {p.name:sha(p) for p in views},
          "activation_bytes_before": 98304, "activation_bytes_after": 81920,
          "SRAM_area_before_um2": before, "SRAM_area_after_um2": after,
          "SRAM_area_reduction_fraction": 1-after/before,
          "bounds": "all writes and all meaningful reads fit 1024; discarded halo reads may alias",
          "full_core_area_or_energy_claim": False, "post_route": False}
target = REPORTS / "d4_asic_asymmetric_acceptance_20261020.json"
target.write_text(json.dumps(result,indent=2)+"\n")
paths = [target,ROOT / "build/asic_eval/native_asymmetric_logic_rom/manifest.json",
         REPORTS / "asic_memory_contract_20261020.json"]
paths.extend((REPORTS / a1["tag"]).glob("sample_*_mode[012].log"))
archive = ROOT / "build/d4_asic_asymmetric_evidence_20261020.tar.gz"
with tarfile.open(str(archive),"w:gz") as t:
    for p in sorted(set(paths)):
        t.add(str(p),arcname=p.relative_to(ROOT).as_posix())
print("D4_ASIC_A1_ACCEPTANCE_PASS exact_inferences=84 capacity_KiB=80 SRAM_area_reduction={:.4%} archive_sha256={}".format(1-after/before,sha(archive)))
