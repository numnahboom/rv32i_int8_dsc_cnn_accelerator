#!/usr/bin/env python3
"""Collect auditable numeric ASIC-stage results without exporting PDK views."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "build/reports"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect_rq(style, corner):
    directory = REPORTS / ("asic_rq_{}_{}_20261019".format(style, corner))
    area = (directory / "area.rpt").read_text()
    timing = (directory / "timing_max.rpt").read_text()
    console = (directory / "console.log").read_text()
    if "D4_ASIC_RQ_SYNTH_COMPLETE style=" + style not in console or "Error:" in console:
        raise RuntimeError("Synthesis missing completion or contains errors: " + str(directory))
    def number(pattern, text):
        match = re.search(pattern, text)
        if not match:
            raise RuntimeError("Missing metric: " + pattern)
        return float(match.group(1))
    cells = number(r"Number of cells:\s+(\d+)", area)
    result = {"style": style, "corner": corner,
              "cell_area_um2": number(r"Total cell area:\s+([\d.eE+-]+)", area),
              "cells": int(cells),
              "reported_setup_slack_ns": number(r"slack\s+\([^)]*\)\s+([\d.eE+-]+)", timing),
              "period_ns": 8.0, "clock_uncertainty_ns": 0.2,
              "input_output_max_delay_ns": 0.5, "output_load_pF": 0.01,
              "scope": "isolated_RQ_lane_standard_cell_synthesis",
              "power_claim": False, "post_route": False,
              "evidence_sha256": {p.name: sha(p) for p in directory.glob("*.rpt")},
              "mapped_netlist_sha256": sha(directory / "mapped.v"),
              "collector_note": "Area read from actual report; initial Tcl design-area attribute was unavailable"}
    (directory / "collected_result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def collect_functional(tag):
    directory = REPORTS / tag
    logs = sorted(directory.glob("sample_*_mode[012].log"))
    if len(logs) != 42:
        raise RuntimeError("Expected 42 simulation logs: " + tag)
    metrics = {}
    for log in logs:
        text = log.read_text()
        if "*F," in text or "TAP_MISMATCH" in text or "$readmem error" in text:
            raise RuntimeError("Failed simulation: " + str(log))
        rows = re.findall(r"^D4_FULLNET_PASS (.*)$", text, flags=re.MULTILINE)
        if len(rows) != 2:
            raise RuntimeError("Expected exactly two exact inference markers")
        for row in rows:
            fields = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", row)}
            if fields["tap_words"] != 24336 or fields["logits"] != 10 or fields["macs"] != 11645440:
                raise RuntimeError("Incomplete full-network ledger")
        metrics[log.name] = rows
    return {"tag": tag, "inferences": 84, "sample_mode_epoch_metrics": metrics,
            "log_sha256": {p.name: sha(p) for p in logs}}


if __name__ == "__main__":
    rq = [collect_rq(style, "tt") for style in ("partial", "native")]
    functional = [collect_functional("asic_{}_xcelium_20261019".format(style))
                  for style in ("partial", "native")]
    if functional[0]["sample_mode_epoch_metrics"] != functional[1]["sample_mode_epoch_metrics"]:
        raise RuntimeError("Candidate changes full-network metrics")
    unit = REPORTS / "asic_rq_equivalence_20261019/unit.log"
    if "D4_ASIC_RQ_EQUIVALENCE_PASS checks=17498 resets=21" not in unit.read_text():
        raise RuntimeError("Missing accepted full-width arithmetic unit result")
    result = {"status": "ACCEPTED_ARITHMETIC_AND_RTL_PORTABILITY_STAGE",
              "rq": rq, "native_area_reduction_fraction": 1-rq[1]["cell_area_um2"]/rq[0]["cell_area_um2"],
              "fullnet": functional, "unit_log_sha256": sha(unit),
              "limits": ["No complete ASIC chip PPA", "Behavioral initialized parameter memories",
                         "128-bit core input boundary, not FPGA 32-bit wrapper or host end-to-end",
                         "No post-route timing or activity power claim"]}
    target = REPORTS / "d4_asic_stage1_acceptance_20261019.json"
    target.write_text(json.dumps(result, indent=2) + "\n")
    print("D4_ASIC_STAGE1_PASS exact_inferences=168 unit_checks=17498 native_lane_area_reduction={:.4%}".format(result["native_area_reduction_fraction"]))
