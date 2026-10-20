#!/usr/bin/env python3
"""Collect the fixed A3 Formality evidence allowlist and create a local archive.

Only reports, JSON metadata, and the compatibility/checker scripts are copied.
The collector never copies SVF, mapped netlists, PDK/IP, or native helper files.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REMOTE_ROOT = "/home/ljw/projects/rv32i_int8_dsc_cnn_accelerator"
DEFAULT_EVIDENCE = ROOT / "artifacts/d4_asic_formal_compat_20261020"
RUN_REL = "build/reports/asic_A3_sync_reset_formal_md5_native_verify_20261020"
MANIFEST_REL = "build/reports/asic_svf_compat_parser_20261020"
REMOTE_ALLOWLIST = (
    f"{RUN_REL}/console.log",
    f"{RUN_REL}/formality.log",
    f"{RUN_REL}/fm_shell_command.log",
    f"{RUN_REL}/unmatched.rpt",
    f"{RUN_REL}/black_boxes.rpt",
    f"{RUN_REL}/dont_verify.rpt",
    f"{RUN_REL}/constants.rpt",
    f"{RUN_REL}/run_summary.json",
    f"{RUN_REL}/final_acceptance_review_all_native_logs.json",
    f"{MANIFEST_REL}/manifest_native_context_md5.json",
    f"{MANIFEST_REL}/manifest_native_context_md5_postreview_full_log_scan.json",
)
ALLOWED_SUFFIXES = {".json", ".log", ".rpt", ".py", ".md", ".txt"}
GUIDANCE_ROW_RE = re.compile(r"^\s*([a-z_]+)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")
MATCHED_RE = re.compile(r"\b(\d+) Compare points matched by name\b")
PASSING_RE = re.compile(r"\b(\d+) Passing compare points\b")
ZERO_FAIL_RE = re.compile(r"^Failing \(not equivalent\)(?:\s+0){8}\s*$", re.MULTILINE)
ERROR_RE = re.compile(r"^\s*Error\s*:", re.IGNORECASE)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_guidance(text):
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if "Guidance Summary" in line]
    if not starts:
        raise ValueError("No Guidance Summary in completed native console")
    rows = {}
    for line in lines[starts[-1] + 1:]:
        match = GUIDANCE_ROW_RE.match(line)
        if match:
            name, accepted, rejected, unsupported, unprocessed, total = match.groups()
            rows[name] = {
                "accepted": int(accepted), "rejected": int(rejected),
                "unsupported": int(unsupported), "unprocessed": int(unprocessed),
                "total": int(total),
            }
        elif rows and (not line.strip() or line.startswith("Note:")):
            break
    if not rows:
        raise ValueError("Guidance Summary has no parsed rows")
    return rows


def final_report(text, unmatched_text):
    matched = [int(value) for value in MATCHED_RE.findall(text)]
    passing = [int(value) for value in PASSING_RE.findall(text)]
    return {
        "verification_succeeded": re.search(r"^Verification SUCCEEDED\s*$", text, re.MULTILINE) is not None,
        "matched_compare_points": matched[-1] if matched else None,
        "passing_compare_points": passing[-1] if passing else None,
        "zero_failing_summary_row": ZERO_FAIL_RE.search(text) is not None,
        "no_unmatched_points_reported": "No unmatched points." in unmatched_text,
        "standalone_zero_unverified_counter_printed": re.search(r"\b0 Unverified compare points\b", text) is not None,
        "completion_basis": "Formality final success, 13758 matched/passing, zero-failing row, and no unmatched report; no separate completed-run zero-unverified counter was printed.",
    }


def create_derived_reports(stage):
    review_path = stage / "final_acceptance_review_all_native_logs.json"
    manifest_path = stage / "manifest_native_context_md5_postreview_full_log_scan.json"
    console_path = stage / "console.log"
    unmatched_path = stage / "unmatched.rpt"
    review = json.loads(review_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    console = console_path.read_text(encoding="utf-8", errors="replace")
    guidance = parse_guidance(console)
    points = final_report(console, unmatched_path.read_text(encoding="utf-8", errors="replace"))
    (stage / "guidance_summary.json").write_text(
        json.dumps({"source": "console.log Guidance Summary", "rows": guidance}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (stage / "point_summary.json").write_text(
        json.dumps({"source": "native final console and unmatched.rpt", "counts": points}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    boundary = {
        "description": "Historical negative or incomplete runs retained as boundary evidence; not substituted for the metadata-only native-context proof.",
        "prior_runs": review.get("prior_run_evidence", {}),
        "prior_124_unverified_point_identities": review.get("prior_124_unverified_point_identities"),
    }
    (stage / "prior_boundary_evidence.json").write_text(
        json.dumps(boundary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    contract = {
        "run_contract": manifest["run_contract"],
        "fixed_candidate": manifest["fixed_candidate"],
        "source_binding": review["source_binding"],
        "metadata_only_transform": review["metadata_only_transform"],
        "native_sidefile_context": review["native_sidefile_context"],
        "at_run_manifest_sha256": review["at_run_manifest_sha256"],
        "postreview_manifest_sha256": review["review_manifest_sha256"],
    }
    (stage / "run_contract.json").write_text(
        json.dumps(contract, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report = [
        "# A3 Formality metadata compatibility evidence",
        "",
        "The native-context metadata-only SVF run completed successfully for the fixed A3 sync-reset mapped candidate.",
        "The evidence covers RTL-to-mapped logic equivalence with identical reference and implementation memory boundaries.",
        "Memory macro contents remain a separate gate-level validation boundary.",
        "",
        "- Final status: Verification SUCCEEDED; 13,758 compare points matched and passed; zero failing and unmatched points.",
        "- Native log scan: console.log, formality.log, and fm_shell_command.log; no native Error lines.",
        "- Key accepted guidance: architecture 22/22, boundary 21/21, datapath 87/88 (one rejected, matching baseline), multiplier 81/81.",
        "- Memory boundaries: 19 instances on each side, identical expected macro designs.",
        "- Same source: source MD5 in SVF metadata matches the recorded actual source MD5; the workspace acceptance script rehashes the local source file.",
        "- Metadata transformation: only guide_info -file metadata was reduced to a path+MD5 pair; the recorded operative guidance SHA256 is unchanged.",
        "- Native sidefile context: d1/ helper inventory hash and 169-file count are recorded; helper files themselves are not included.",
        "- Completion limit: Formality did not print a separate completed-run zero-unverified counter; acceptance uses its final success status, all 13,758 passing points, zero-failing summary, and no-unmatched report.",
        "- Historical boundary evidence: no-SVF failure, isolated CRCpair 124-unverified stall, and original triple-metadata parse error are preserved as hashes/counts/paths in prior_boundary_evidence.json.",
        "- The original run_summary.json keeps its negative wrapper classification unchanged and is hash-bound by the post-review record.",
        "",
        "The allowlist archive contains logs, reports, JSON metadata, and the two compatibility scripts plus collector/checker code. It contains no SVF, netlist, PDK/IP, or native helper payloads.",
        "",
        "Run from the repository root: `python scripts/accept_d4_asic_formal_compat.py --evidence-dir artifacts/d4_asic_formal_compat_20261020 --archive artifacts/d4_asic_formal_compat_20261020.zip`.",
    ]
    (stage / "README.md").write_text("\n".join(report) + "\n", encoding="utf-8")


def make_checksums(stage):
    lines = []
    files = sorted(path for path in stage.rglob("*") if path.is_file() and path.name != "SHA256SUMS.txt")
    for path in files:
        if path.suffix.lower() not in ALLOWED_SUFFIXES:
            raise ValueError(f"Disallowed evidence file type: {path.name}")
        lines.append("{}  {}".format(sha256(path), path.relative_to(stage).as_posix()))
    (stage / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def make_deterministic_zip(stage, archive):
    with zipfile.ZipFile(str(archive), "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(p for p in stage.rglob("*") if p.is_file()):
            relative = path.relative_to(stage).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(2026, 10, 20, 0, 0, 0))
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
        parser.error("Refusing to overwrite an existing evidence directory, archive, or checksum sidecar")
    evidence.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="d4_asic_formal_compat_", dir=str(evidence.parent)) as temporary:
        stage = Path(temporary)
        remote_sources = ["{}:{}".format(args.host, PurePosixPath(args.remote_root) / rel) for rel in REMOTE_ALLOWLIST]
        subprocess.run(["scp", "-O"] + remote_sources + [str(stage) + os.sep], check=True)
        for name in ("prepare_d4_svf_compat_probe.py", "run_d4_formal_metadata_compat.py"):
            shutil.copy2(ROOT / "scripts" / name, stage / name)
        shutil.copy2(Path(__file__).resolve(), stage / "collect_d4_asic_formal_compat.py")
        shutil.copy2(ROOT / "scripts/accept_d4_asic_formal_compat.py", stage / "accept_d4_asic_formal_compat.py")
        create_derived_reports(stage)
        make_checksums(stage)
        subprocess.run([
            sys.executable, str(ROOT / "scripts/accept_d4_asic_formal_compat.py"),
            "--evidence-dir", str(stage), "--workspace-root", str(ROOT),
        ], check=True)
        stage.rename(evidence)

    make_deterministic_zip(evidence, archive)
    archive_hash = sha256(archive)
    sidecar.write_text("{}  {}\n".format(archive_hash, archive.name), encoding="ascii")
    subprocess.run([
        sys.executable, str(ROOT / "scripts/accept_d4_asic_formal_compat.py"),
        "--evidence-dir", str(evidence), "--archive", str(archive),
        "--workspace-root", str(ROOT),
    ], check=True)
    print("D4_ASIC_FORMAL_COMPAT_ARCHIVE={}".format(archive))
    print("D4_ASIC_FORMAL_COMPAT_ARCHIVE_SHA256={}".format(archive_hash))
    print("D4_ASIC_FORMAL_COMPAT_EVIDENCE_DIR={}".format(evidence))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("D4_ASIC_FORMAL_COMPAT_COLLECT_FAIL={}".format(exc), file=sys.stderr)
        raise SystemExit(2)
