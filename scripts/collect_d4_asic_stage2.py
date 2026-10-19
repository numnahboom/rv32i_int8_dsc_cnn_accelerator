#!/usr/bin/env python3
"""Accept completed ASIC functional/macro gates, separate from running P&R."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile

from collect_d4_asic import ROOT, REPORTS, collect_functional, collect_rq


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


baseline = collect_functional("asic_native_xcelium_20261019")
banked = collect_functional("asic_native_banked_xcelium_20261019")
real_macro = collect_functional("asic_smic_sram_xcelium_20261020")
for candidate in (banked, real_macro):
    if candidate["sample_mode_epoch_metrics"] != baseline["sample_mode_epoch_metrics"]:
        raise RuntimeError("Full-network cycle/ledger behavior changed")
gate_log = REPORTS / "asic_rq_gate_equivalence_20261019/unit.log"
gate_text = gate_log.read_text()
if "D4_ASIC_RQ_EQUIVALENCE_PASS checks=17498 resets=21" not in gate_text or "*F," in gate_text:
    raise RuntimeError("Mapped arithmetic verification failed")
macro_dir = ROOT / "build/asic_macros/act_2048x128"
model = macro_dir / "RASP2048X16M16.v"
text = model.read_text()
for name, value in (("Word_Width", 128), ("Word_Depth", 2048), ("Addr_Depth", 11)):
    if not re.search(r"parameter\s+" + name + r"\s*=\s*" + str(value) + r"\s*;", text):
        raise RuntimeError("Actual SRAM shape mismatch")
datasheet = macro_dir / "RASP2048X16M16.ds"
match = re.search(r"Die Area\s*=\s*([\d.]+)", datasheet.read_text())
if not match:
    raise RuntimeError("Missing actual SRAM area")
area = float(match.group(1))
library_log = (macro_dir / "library_compile.log").read_text()
if "D4_ASIC_SRAM_LIBRARIES_COMPILED" not in library_log or "Error:" in library_log:
    raise RuntimeError("SRAM timing library compilation failed")
views = [model, datasheet, macro_dir / "RASP2048X16M16.lef"]
for corner in ("typical", "worst", "best"):
    for suffix in ("lib", "db"):
        path = macro_dir / ("RASP2048X16M16_{}.{}".format(corner, suffix))
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("Missing real macro view")
        views.append(path)
sources = ["rtl/cnn/d4_fullnet_top.sv", "rtl/asic/d4_feature_banks.sv",
           "rtl/asic/d4_rq_native_multiplier_lane.sv", "rtl/asic/d4_smic180_sram.sv",
           "sim/d4_asic_sram_monitor.sv", "sim/tb_d4_fullnet.sv",
           "sim/tb_d4_asic_rq_equivalence.sv", "scripts/prepare_d4_asic.py",
           "build/asic_eval/native_banked_logic_rom/d4_fullnet_eval.sv"]
result = {"status": "ACCEPTED_COMPLETE_NETWORK_ASIC_MACRO_FUNCTIONAL_STAGE",
          "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip(),
          "source_sha256": {name: digest(ROOT / name) for name in sources},
          "functional": real_macro, "fullnet_metrics_equal_native_and_banked": True,
          "mapped_RQ_unit_checks": 17498, "mapped_RQ_unit_resets": 21,
          "mapped_unit_log_sha256": digest(gate_log), "native_SS_RQ": collect_rq("native", "ss"),
          "SRAM": {"macros": 3, "words_each": 2048, "bits_each": 128,
                   "single_macro_datasheet_area_um2": area, "total_macro_area_um2": 3*area,
                   "actual_view_sha256": {p.name: digest(p) for p in views},
                   "cell_name_is_default_not_shape": "RASP2048X16M16",
                   "CEN": "active low", "WE": "active high", "OE": "active high"},
          "limits": ["Full-core synthesis/physical implementation accepted separately",
                     "128-bit raw-FC core boundary; no host/pad/clock-tree cost",
                     "Macro functional simulation, no SDF/electrical signoff",
                     "Power metadata warnings; no ASIC total power or energy claim",
                     "Historical 91.46% software accuracy, no new test10k run"]}
target = REPORTS / "d4_asic_stage2_acceptance_20261020.json"
target.write_text(json.dumps(result, indent=2) + "\n")
# Only our numeric reports and validation logs; no PDK or macro views/netlists.
payload = [target, REPORTS / "d4_asic_stage1_acceptance_20261019.json", gate_log,
           ROOT / "build/asic_eval/native_banked_logic_rom/manifest.json"]
for tag in ("asic_rq_partial_tt_20261019", "asic_rq_native_tt_20261019", "asic_rq_native_ss_20261019"):
    payload.extend((REPORTS / tag).glob("*.rpt"))
    payload.append(REPORTS / tag / "collected_result.json")
payload.extend((REPORTS / "asic_smic_sram_xcelium_20261020").glob("sample_*_mode[012].log"))
archive = ROOT / "build/d4_asic_completed_stage2_evidence.tar.gz"
with tarfile.open(str(archive), "w:gz") as tar:
    for path in sorted(set(payload)):
        tar.add(str(path), arcname=path.relative_to(ROOT).as_posix())
print("D4_ASIC_STAGE2_ACCEPTANCE_PASS exact_inferences=84 gate_checks=17498 real_SRAMs=3 archive_sha256=" + digest(archive))
