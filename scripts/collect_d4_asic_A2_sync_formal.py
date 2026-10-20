#!/usr/bin/env python3
"""Collect and package the bounded A2 sync-reset Formality evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

try:
    from .accept_d4_asic_A2_sync_formal import build_match_review
except ImportError:
    from accept_d4_asic_A2_sync_formal import build_match_review

ROOT = Path(__file__).resolve().parents[1]
RUN_TAG = "asic_A2_sync_reset_formal_20261020"
DEFAULT_REMOTE_ROOT = "/home/ljw/projects/rv32i_int8_dsc_cnn_accelerator"
DEFAULT_EVIDENCE = ROOT / "artifacts/d4_asic_A2_sync_formal_20261020"
ALLOWED_LOG_NAMES = {
    "console.log", "formality.log", "fm_shell_command.log", "run_summary.json",
    "unmatched.rpt", "black_boxes.rpt", "dont_verify.rpt", "constants.rpt",
    "failing.rpt", "unverified_points.rpt", "aborted_points.rpt",
}
ALLOWED_SUFFIXES = {".json", ".log", ".rpt", ".py", ".tcl", ".md", ".txt"}
PHASES = {"export", "match", "verify"}


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def remote_inventory(host, remote_root):
    remote_cmd = "cd {} && find build/reports/{} -maxdepth 2 -type f -printf '%P\\n' | sort".format(
        shlex.quote(remote_root), RUN_TAG
    )
    completed = subprocess.run(["ssh", host, remote_cmd], check=True, capture_output=True, text=True)
    files = []
    for line in completed.stdout.splitlines():
        relative = PurePosixPath(line)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unexpected remote report path: {}".format(line))
        if len(relative.parts) == 1 and relative.name in {
            "manifest_native_context_md5.json",
            "manifest_native_context_md5_postreview.json",
        }:
            # These fixed inputs are copied explicitly below under clearer names.
            continue
        if len(relative.parts) != 2:
            raise ValueError("Unexpected remote report path: {}".format(line))
        phase, name = relative.parts
        if phase not in PHASES or name not in ALLOWED_LOG_NAMES:
            raise ValueError("Remote report is outside the collection allowlist: {}".format(line))
        files.append(line)
    required = {
        "export/console.log", "export/run_summary.json",
        "match/console.log", "match/run_summary.json", "match/unmatched.rpt", "match/black_boxes.rpt",
        "verify/console.log", "verify/run_summary.json", "verify/unmatched.rpt", "verify/black_boxes.rpt",
        "verify/dont_verify.rpt", "verify/constants.rpt",
    }
    missing = sorted(required - set(files))
    if missing:
        raise ValueError("Remote A2 evidence is incomplete; missing: {}".format(", ".join(missing)))
    return sorted(files)


def copy_remote_files(host, remote_root, relative_files, stage):
    for relative in relative_files:
        destination = stage / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        remote_path = PurePosixPath(remote_root) / "build/reports" / RUN_TAG / PurePosixPath(relative)
        subprocess.run(["scp", "-O", "{}:{}".format(host, remote_path), str(destination)], check=True)
    report_root = PurePosixPath(remote_root) / "build/reports" / RUN_TAG
    at_match = report_root / "manifest_native_context_md5.json"
    postreview = report_root / "manifest_native_context_md5_postreview.json"
    subprocess.run(["scp", "-O", "{}:{}".format(host, at_match), str(stage / "manifest_native_context_md5_at_match.json")], check=True)
    subprocess.run(["scp", "-O", "{}:{}".format(host, postreview), str(stage / "manifest_native_context_md5_postreview.json")], check=True)


def copy_contract_scripts(stage):
    names = (
        "asic_A2_formal.tcl",
        "prepare_d4_A2_svf_compat.py",
        "run_d4_asic_A2_sync_formal.py",
        "collect_d4_asic_A2_sync_formal.py",
        "accept_d4_asic_A2_sync_formal.py",
        "run_d4_asic_A2_sync_formal_at_match.py",
    )
    for name in names:
        source = ROOT / "scripts" / name
        if not source.is_file():
            raise FileNotFoundError("Missing A2 evidence script: {}".format(source))
        shutil.copy2(source, stage / name)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_derived(stage):
    match_manifest = read_json(stage / "manifest_native_context_md5_at_match.json")
    proof_manifest = read_json(stage / "manifest_native_context_md5_postreview.json")
    export = read_json(stage / "export/run_summary.json")
    match = read_json(stage / "match/run_summary.json")
    verify = read_json(stage / "verify/run_summary.json")
    checks = verify.get("proof_checks", {})
    match_review = build_match_review(stage, match, match_manifest)
    (stage / "match_postreview.json").write_text(json.dumps(match_review, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    point_summary = {
        "verification_succeeded": checks.get("verification_succeeded"),
        "matched_compare_points": checks.get("matched_compare_points"),
        "passing_compare_points": checks.get("passing_compare_points"),
        "zero_failing_summary": checks.get("zero_failing_summary"),
        "no_unmatched_points": checks.get("no_unmatched_points"),
        "output_interface": checks.get("output_interface"),
        "no_dont_verify_points": checks.get("no_dont_verify_points"),
    }
    (stage / "point_summary.json").write_text(json.dumps(point_summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (stage / "memory_summary.json").write_text(json.dumps(checks.get("memory_boundaries", {}), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    contract = {
        "candidate": proof_manifest["candidate"],
        "fixed_candidate": proof_manifest["fixed_candidate"],
        "compatibility_mode": proof_manifest["compatibility_mode"],
        "native_export_result": export.get("result"),
        "match_preflight_at_run_result": match.get("result"),
        "match_preflight_postreview_result": match_review.get("review_result"),
        "full_proof_result": verify.get("result"),
        "proof_contract": proof_manifest["proof_contract"],
        "package_exclusions": ["native SVF and helper context", "mapped netlist", "RTL source payloads", "technology/IP library payloads"],
    }
    (stage / "run_contract.json").write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    matched = checks.get("matched_compare_points")
    passing = checks.get("passing_compare_points")
    native_error_count = verify.get("native_error_count")
    memory = checks.get("memory_boundaries", {})
    output = checks.get("output_interface", {})
    report = [
        "# A2 sync-reset RTL-to-mapped Formality result",
        "",
        "Status: **{}**".format(verify.get("result", "UNKNOWN")),
        "",
        "The proof targets `{}` with mapped SHA256 `{}` and reset policy `{}`; reported area is {} um2.".format(
            proof_manifest["fixed_candidate"]["synth_tag"], proof_manifest["fixed_candidate"]["mapped_sha256"],
            proof_manifest["fixed_candidate"]["reset_policy"], proof_manifest["fixed_candidate"]["cell_area_including_macros_um2"],
        ),
        "",
        "Formality final summary: {} matched, {} passing, zero-failing={}, no-unmatched={}.".format(
            matched, passing, checks.get("zero_failing_summary"), checks.get("no_unmatched_points"),
        ),
        "The independently parsed RTL and mapped top interfaces contain {} matching output bits; the declared requirement is 252.".format(
            output.get("rtl_output_bits"),
        ),
        "The reference and implementation each retain {} black-box instances (3 SRAM and 8 weight ROM); native proof log Error lines: {}.".format(
            memory.get("reference_instances"), native_error_count,
        ),
        "",
        "The one match-only preflight completed with {} named points, zero native Error lines, and no unmatched points. The original wrapper misclassified its black-box report because it read the cell-type column as the design name; `match_postreview.json` preserves the original run summary and records the corrected report parse.".format(
            match_review.get("at_run_matched_compare_points"),
        ),
        "",
        "The native-context adapter changed only the `guide_info -file` numeric metadata field, retained the source path and verified source MD5, and confirmed the operative SVF guidance hash is unchanged. Native `d1` helpers remain in place at the remote export location; the package records their file count and inventory SHA256 without copying their contents.",
        "",
        "Evidence includes the export/parser and match-only preflight logs, full proof logs/reports, fixed-input hash manifest, run summaries, contract scripts, and local checksum validation. No SVF, helper payload, netlist, RTL, or library contents are included.",
        "",
        "Validate the package from the repository root with `python scripts/accept_d4_asic_A2_sync_formal.py --evidence-dir artifacts/d4_asic_A2_sync_formal_20261020 --archive artifacts/d4_asic_A2_sync_formal_20261020.zip`.",
    ]
    (stage / "README.md").write_text("\n".join(report) + "\n", encoding="utf-8")


def make_checksums(stage):
    rows = []
    for path in sorted(item for item in stage.rglob("*") if item.is_file() and item.name != "SHA256SUMS.txt"):
        if path.suffix.lower() not in ALLOWED_SUFFIXES:
            raise ValueError("Disallowed evidence type: {}".format(path.name))
        rows.append("{}  {}".format(sha256(path), path.relative_to(stage).as_posix()))
    (stage / "SHA256SUMS.txt").write_text("\n".join(rows) + "\n", encoding="ascii")


def make_zip(stage, archive):
    with zipfile.ZipFile(str(archive), "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(item for item in stage.rglob("*") if item.is_file()):
            name = path.relative_to(stage).as_posix()
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 20, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="lab-ljw")
    parser.add_argument("--remote-root", default=DEFAULT_REMOTE_ROOT)
    parser.add_argument("--evidence-dir", type=Path, default=DEFAULT_EVIDENCE)
    args = parser.parse_args(argv)
    evidence = args.evidence_dir.resolve()
    archive = evidence.with_suffix(".zip")
    sidecar = Path(str(archive) + ".sha256")
    if evidence.exists() or archive.exists() or sidecar.exists():
        parser.error("Refusing to overwrite existing A2 evidence, archive, or checksum sidecar")
    evidence.parent.mkdir(parents=True, exist_ok=True)
    relative_files = remote_inventory(args.host, args.remote_root)
    with tempfile.TemporaryDirectory(prefix="d4_asic_A2_sync_formal_", dir=str(evidence.parent)) as temporary:
        stage = Path(temporary)
        copy_remote_files(args.host, args.remote_root, relative_files, stage)
        copy_contract_scripts(stage)
        write_derived(stage)
        make_checksums(stage)
        subprocess.run([
            sys.executable, str(ROOT / "scripts/accept_d4_asic_A2_sync_formal.py"),
            "--evidence-dir", str(stage), "--workspace-root", str(ROOT),
        ], check=True)
        stage.rename(evidence)
    make_zip(evidence, archive)
    archive_hash = sha256(archive)
    sidecar.write_text("{}  {}\n".format(archive_hash, archive.name), encoding="ascii")
    subprocess.run([
        sys.executable, str(ROOT / "scripts/accept_d4_asic_A2_sync_formal.py"),
        "--evidence-dir", str(evidence), "--archive", str(archive), "--workspace-root", str(ROOT),
    ], check=True)
    print("D4_A2_SYNC_FORMAL_EVIDENCE={}".format(evidence))
    print("D4_A2_SYNC_FORMAL_ARCHIVE={}".format(archive))
    print("D4_A2_SYNC_FORMAL_ARCHIVE_SHA256={}".format(archive_hash))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("D4_A2_SYNC_FORMAL_COLLECT_FAIL={}".format(exc), file=sys.stderr)
        raise SystemExit(2)
