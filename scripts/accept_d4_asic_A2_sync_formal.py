#!/usr/bin/env python3
"""Validate the A2 sync-reset Formality evidence folder and archive."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile

try:
    from .prepare_d4_A2_svf_compat import EXPECTED_INPUTS, FULLNET_SOURCE, MAPPED_SHA256, RESET_POLICY, SYNTH_TAG
except ImportError:
    from prepare_d4_A2_svf_compat import EXPECTED_INPUTS, FULLNET_SOURCE, MAPPED_SHA256, RESET_POLICY, SYNTH_TAG


EXPECTED_OUTPUTS = {
    "start_ready": 1, "input_ready": 1, "logit_valid": 1, "logit_index": 4,
    "logit_acc": 32, "done_valid": 1, "busy": 1, "error": 1,
    "cycle_count": 32, "semantic_mac_count": 32, "trace_valid": 1,
    "trace_op": 6, "trace_index": 11, "trace_data": 128,
}
EXPECTED_MEMORY_DESIGNS = {
    "D4_ACT_1024X128_M8": 1, "RASP2048X16M16": 2,
    **{"D4WROM{}".format(index): 1 for index in range(8)},
}
ALLOWED_SUFFIXES = {".json", ".log", ".rpt", ".py", ".tcl", ".md", ".txt"}
REMOTE_LOG_NAMES = {
    "console.log", "formality.log", "fm_shell_command.log", "run_summary.json",
    "unmatched.rpt", "black_boxes.rpt", "dont_verify.rpt", "constants.rpt",
    "failing.rpt", "unverified_points.rpt", "aborted_points.rpt",
}
REQUIRED_FILES = {
    "export/console.log", "export/run_summary.json",
    "match/console.log", "match/run_summary.json", "match/unmatched.rpt", "match/black_boxes.rpt",
    "verify/console.log", "verify/run_summary.json", "verify/unmatched.rpt", "verify/black_boxes.rpt",
    "verify/dont_verify.rpt", "verify/constants.rpt",
    "manifest_native_context_md5_at_match.json", "manifest_native_context_md5_postreview.json",
    "match_postreview.json", "point_summary.json", "memory_summary.json", "run_contract.json",
    "README.md", "SHA256SUMS.txt",
    "asic_A2_formal.tcl", "prepare_d4_A2_svf_compat.py", "run_d4_asic_A2_sync_formal.py",
    "run_d4_asic_A2_sync_formal_at_match.py",
    "collect_d4_asic_A2_sync_formal.py", "accept_d4_asic_A2_sync_formal.py",
}
ERROR_RE = re.compile(r"^\s*Error\s*:", re.IGNORECASE)
MATCHED_RE = re.compile(r"\b(\d+) Compare points matched by name\b")
PASSING_RE = re.compile(r"\b(\d+) Passing compare points\b")
ZERO_FAIL_RE = re.compile(r"^Failing \(not equivalent\)(?:\s+0){8}\s*$", re.MULTILINE)
BLACKBOX_RE = re.compile(
    r"####\s+DESIGN LIBRARY - ([ri]):/[^\s]+\s+.*?"
    r"Type\s+Design Name\s+[-\s]+\s*(\w+)\s+(\w+)\s+.*?"
    r"Instances\s*:\s*(\d+)\s+of\s+(\d+)", re.DOTALL
)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_json(path, failures):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception as exc:
        failures.append("Cannot parse {}: {}".format(path, exc))
        return {}


def fail_if(condition, message, failures):
    if not condition:
        failures.append(message)


def verify_checksums(evidence, failures):
    records = {}
    path = evidence / "SHA256SUMS.txt"
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.match(r"^([0-9a-f]{64})  ([^\s]+)$", line)
        if not match:
            failures.append("Malformed checksum line: {}".format(line))
            continue
        digest, name = match.groups()
        safe = PurePosixPath(name)
        if safe.is_absolute() or ".." in safe.parts or name in records:
            failures.append("Unsafe or duplicate checksum path: {}".format(name))
            continue
        records[name] = digest
    actual = {
        item.relative_to(evidence).as_posix(): item
        for item in evidence.rglob("*") if item.is_file() and item.name != "SHA256SUMS.txt"
    }
    fail_if(set(records) == set(actual), "SHA256SUMS file set differs from evidence directory", failures)
    for name, path in actual.items():
        fail_if(not path.is_symlink(), "Evidence file is a symlink: {}".format(name), failures)
        fail_if(path.suffix.lower() in ALLOWED_SUFFIXES, "Disallowed evidence artifact: {}".format(name), failures)
        fail_if(records.get(name) == sha256(path), "Checksum mismatch: {}".format(name), failures)
    return actual


def verify_archive(evidence, archive, failures):
    if archive is None:
        return None
    if not archive.is_file():
        failures.append("Archive does not exist: {}".format(archive))
        return None
    digest = sha256(archive)
    sidecar = Path(str(archive) + ".sha256")
    if not sidecar.is_file():
        failures.append("Archive SHA256 sidecar is missing")
    else:
        fields = sidecar.read_text(encoding="ascii").strip().split()
        if not fields or fields[0] != digest:
            failures.append("Archive SHA256 sidecar does not match")
    disk = {
        item.relative_to(evidence).as_posix(): item.read_bytes()
        for item in evidence.rglob("*") if item.is_file()
    }
    try:
        with zipfile.ZipFile(str(archive), "r") as bundle:
            names = bundle.namelist()
            fail_if(len(names) == len(set(names)), "Archive has duplicate members", failures)
            fail_if(set(names) == set(disk), "Archive member list differs from evidence folder", failures)
            for name in names:
                safe = PurePosixPath(name)
                if safe.is_absolute() or ".." in safe.parts:
                    failures.append("Unsafe archive member: {}".format(name))
                    continue
                if Path(name).suffix.lower() not in ALLOWED_SUFFIXES:
                    failures.append("Disallowed archive member type: {}".format(name))
                if name in disk and bundle.read(name) != disk[name]:
                    failures.append("Archive content differs from evidence file: {}".format(name))
    except (OSError, zipfile.BadZipFile) as exc:
        failures.append("Cannot read evidence archive: {}".format(exc))
    return digest


def parse_memory_report(path):
    found = {"r": {}, "i": {}}
    if not path.is_file():
        return False, {"error": "missing {}".format(path.name)}
    for match in BLACKBOX_RE.finditer(path.read_text(encoding="utf-8", errors="replace")):
        side, _cell_type, design, count, declared = match.groups()
        count, declared = int(count), int(declared)
        if count != declared or design in found[side]:
            return False, {"error": "duplicate/inconsistent black-box row {}/{}".format(side, design)}
        found[side][design] = count
    okay = found["r"] == EXPECTED_MEMORY_DESIGNS and found["i"] == EXPECTED_MEMORY_DESIGNS
    return okay, {
        "reference_designs": found["r"],
        "implementation_designs": found["i"],
        "reference_instances": sum(found["r"].values()),
        "implementation_instances": sum(found["i"].values()),
        "expected_identical_11_memory_instances": okay,
    }


def verify_memory_report(path, failures):
    okay, summary = parse_memory_report(path)
    fail_if(okay, "Reference and implementation do not have identical 11-memory boundaries", failures)
    return summary


def scan_native_errors(report_dir, names):
    errors = []
    for name in names:
        path = report_dir / name
        if not path.is_file():
            errors.append({"log": name, "line_number": 0, "text": "missing native log"})
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if ERROR_RE.match(line):
                errors.append({"log": name, "line_number": number, "text": line.strip()})
    return errors


def build_match_review(evidence, match_summary, at_match_manifest):
    evidence = Path(evidence)
    report_dir = evidence / "match"
    console = (report_dir / "console.log").read_text(encoding="utf-8", errors="replace")
    names = match_summary.get("native_error_logs_scanned", [])
    errors = scan_native_errors(report_dir, names)
    matched = [int(value) for value in MATCHED_RE.findall(console)]
    unmatched_text = (report_dir / "unmatched.rpt").read_text(encoding="utf-8", errors="replace")
    memory_ok, memory = parse_memory_report(report_dir / "black_boxes.rpt")
    output = match_summary.get("proof_checks", {}).get("output_interface", {})
    marker = "D4_A2_FORMAL_MATCH_ONLY_COMPLETE=1" in console
    no_unmatched = "No unmatched points." in unmatched_text
    failed_at_run = sorted(
        name for name, value in match_summary.get("acceptance_checks", {}).items()
        if value is False
    )
    manifest_hash = hashlib.sha256((evidence / "manifest_native_context_md5_at_match.json").read_bytes()).hexdigest()
    summary_hash = hashlib.sha256((report_dir / "run_summary.json").read_bytes()).hexdigest()
    checks = {
        "process_exit_zero": match_summary.get("exit_code") == 0,
        "not_timed_out": match_summary.get("timed_out") is False,
        "match_summary_bound_to_at_run_manifest": match_summary.get("manifest_sha256") == manifest_hash,
        "manifest_identifies_fixed_A2_mapping": at_match_manifest.get("fixed_candidate", {}).get("mapped_sha256") == MAPPED_SHA256,
        "match_only_marker": marker,
        "no_native_error_lines": not errors,
        "no_unmatched_points": no_unmatched,
        "positive_dynamic_matched_point_count": bool(matched) and matched[-1] == match_summary.get("proof_checks", {}).get("matched_compare_points") and matched[-1] > 0,
        "11_identical_memory_instances": memory_ok,
        "252_output_bits_identical": output.get("all_252_expected_output_bits") is True
            and output.get("rtl_output_bits") == 252
            and output.get("rtl_ports") == EXPECTED_OUTPUTS
            and output.get("mapped_ports") == EXPECTED_OUTPUTS,
        "at_run_wrapper_failed_only_its_memory_parser": failed_at_run == ["11_identical_memory_instances"],
        "at_run_memory_parser_diagnostic_is_the_type_column": "inconsistent or duplicate black-box row: i/e"
            in match_summary.get("proof_checks", {}).get("memory_boundaries", {}).get("error", ""),
    }
    reviewer_path = evidence / "collect_d4_asic_A2_sync_formal.py"
    reviewer_hash = sha256(reviewer_path) if reviewer_path.is_file() else None
    return {
        "schema_version": 1,
        "review_result": "MATCH_READY" if all(checks.values()) and matched else "MATCH_REVIEW_FAILED",
        "at_run_result": match_summary.get("result"),
        "at_run_summary_sha256": summary_hash,
        "at_run_manifest_sha256": manifest_hash,
        "at_run_matched_compare_points": matched[-1] if matched else None,
        "native_error_lines": errors,
        "memory_boundaries": memory,
        "output_interface": output,
        "checks": checks,
        "reviewer_script": "collect_d4_asic_A2_sync_formal.py",
        "reviewer_script_sha256": reviewer_hash,
        "review_note": "The original match run completed correctly. Its wrapper parsed the black-box type token as the design name; this review reads the separate type and design columns and preserves the original run summary unchanged.",
    }


def verify_native_logs(report_dir, summary, failures):
    records = []
    names = summary.get("native_error_logs_scanned", [])
    for name in names:
        path = report_dir / name
        if not path.is_file():
            failures.append("Native log listed by runner is missing: {}/{}".format(report_dir.name, name))
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if ERROR_RE.match(line):
                records.append({"log": name, "line_number": line_number, "text": line.strip()})
    fail_if(records == summary.get("native_error_lines"), "Native Error lines differ from runner summary in {}".format(report_dir.name), failures)
    fail_if(len(records) == summary.get("native_error_count"), "Native Error count differs from runner summary in {}".format(report_dir.name), failures)
    return records


def verify_manifest(manifest, failures):
    fail_if(manifest.get("schema_version") == 1, "Unexpected A2 manifest schema", failures)
    fail_if(manifest.get("fixed_candidate", {}).get("synth_tag") == SYNTH_TAG, "Manifest has the wrong A2 synthesis tag", failures)
    fixed = manifest.get("fixed_candidate", {})
    fail_if(fixed.get("mapped_sha256") == MAPPED_SHA256, "Manifest mapped SHA256 differs from the fixed candidate", failures)
    fail_if(fixed.get("reset_policy") == RESET_POLICY.strip(), "Manifest reset policy differs", failures)
    fail_if(fixed.get("expected_rtl_output_bits") == 252, "Manifest output-bit requirement differs", failures)
    expected_rows = {key: digest for key, digest in EXPECTED_INPUTS.items()}
    recorded_rows = {row.get("key"): row.get("sha256") for row in manifest.get("inputs", [])}
    fail_if(recorded_rows == expected_rows, "Manifest input hash map differs from the fixed A2 candidate", failures)
    native = manifest.get("native_export", {})
    adapted = manifest.get("adapted_svf", {})
    source_rows = native.get("guide_info_records", [])
    fail_if(len(source_rows) == 1, "Manifest does not contain exactly one guide_info source", failures)
    if len(source_rows) == 1:
        row = source_rows[0]
        fail_if(row.get("actual_source_md5") == row.get("source_md5"), "SVF source MD5 does not match actual source MD5", failures)
        fail_if(row.get("actual_source_sha256") == EXPECTED_INPUTS.get(FULLNET_SOURCE), "Manifest SVF source SHA256 differs from the fixed source", failures)
    fail_if(adapted.get("only_file_info_metadata_changed") is True, "Manifest does not assert a metadata-only adaptation", failures)
    fail_if(native.get("operative_guidance_sha256") == adapted.get("operative_guidance_sha256"), "Operative SVF guidance hash changed", failures)
    sidefiles = native.get("native_sidefile_context", {})
    fail_if(sidefiles.get("file_count", 0) > 0 and re.fullmatch(r"[0-9a-f]{64}", sidefiles.get("inventory_sha256", "")) is not None,
            "Native helper inventory is missing", failures)
    return manifest


def verify_run(evidence, phase, summary, manifest_hash, runner_path, failures):
    directory = evidence / phase
    console_path = directory / "console.log"
    fail_if(console_path.is_file(), "Missing {} console.log".format(phase), failures)
    if not console_path.is_file():
        return {}
    console = console_path.read_text(encoding="utf-8", errors="replace")
    fail_if(summary.get("phase") == phase, "{} run summary phase mismatch".format(phase), failures)
    fail_if(summary.get("console_sha256") == sha256(console_path), "{} console hash differs from run summary".format(phase), failures)
    fail_if(summary.get("exit_code") == 0 and summary.get("timed_out") is False,
            "{} process did not complete with exit zero".format(phase), failures)
    fail_if(summary.get("runner_sha256") == sha256(runner_path), "{} summary runner hash mismatch".format(phase), failures)
    fail_if(summary.get("formal_tcl_sha256") == sha256(evidence / "asic_A2_formal.tcl"), "{} summary Tcl hash mismatch".format(phase), failures)
    fail_if(summary.get("adapter_sha256") == sha256(evidence / "prepare_d4_A2_svf_compat.py"), "{} summary adapter hash mismatch".format(phase), failures)
    if phase != "export":
        fail_if(summary.get("manifest_sha256") == manifest_hash, "{} summary does not bind the A2 manifest".format(phase), failures)
    native_errors = verify_native_logs(directory, summary, failures)
    if phase == "export":
        fail_if(summary.get("result") == "NATIVE_EXPORT_READY", "Native export preflight did not complete", failures)
        fail_if("D4_A2_SVF_EXPORT_ONLY_COMPLETE=1" in console, "Export-only marker missing", failures)
        return {}
    fail_if(not native_errors, "{} contains native Error lines".format(phase), failures)
    checks = summary.get("proof_checks", {})
    matched_values = [int(value) for value in MATCHED_RE.findall(console)]
    passing_values = [int(value) for value in PASSING_RE.findall(console)]
    if phase == "match":
        fail_if(summary.get("result") == "MATCH_DIAGNOSTIC_FAILED_OR_INCOMPLETE",
                "At-run match summary classification changed after capture", failures)
        fail_if("D4_A2_FORMAL_MATCH_ONLY_COMPLETE=1" in console, "A2 match-only marker missing", failures)
        fail_if("No unmatched points." in (directory / "unmatched.rpt").read_text(encoding="utf-8", errors="replace"),
                "Match report has unmatched points", failures)
        fail_if(bool(matched_values) and matched_values[-1] == checks.get("matched_compare_points"),
                "At-run matched point total differs from its console", failures)
        return checks
    else:
        fail_if(summary.get("result") == "EQUIVALENCE_PASS", "A2 RTL-to-mapped proof did not pass", failures)
        fail_if("D4_A2_RTL_TO_MAPPED_FORMAL_PASS scope=logic_with_identical_11_memory_boundaries_and_252_output_bits" in console,
                "A2 RTL-to-mapped success marker missing", failures)
        fail_if(re.search(r"^Verification SUCCEEDED\s*$", console, re.MULTILINE) is not None,
                "Native Formality final status is not Verification SUCCEEDED", failures)
        fail_if(bool(matched_values) and bool(passing_values) and matched_values[-1] == passing_values[-1] and matched_values[-1] > 0,
                "Final matched and passing compare-point counts do not agree", failures)
        fail_if(ZERO_FAIL_RE.search(console) is not None, "Native final zero-failing summary is missing", failures)
        fail_if("No unmatched points." in (directory / "unmatched.rpt").read_text(encoding="utf-8", errors="replace"),
                "Final unmatched report does not state no unmatched points", failures)
        fail_if("Don't verify points:   None" in (directory / "dont_verify.rpt").read_text(encoding="utf-8", errors="replace")
                or "Don't verify points: None" in (directory / "dont_verify.rpt").read_text(encoding="utf-8", errors="replace"),
                "Final dont_verify report is not empty", failures)
        memory = verify_memory_report(directory / "black_boxes.rpt", failures)
        fail_if(checks.get("verification_succeeded") is True, "Runner proof check lacks native success", failures)
        fail_if(checks.get("matched_compare_points") == matched_values[-1] if matched_values else False,
                "Runner's dynamic matched point count differs from native output", failures)
        fail_if(checks.get("passing_compare_points") == passing_values[-1] if passing_values else False,
                "Runner's dynamic passing point count differs from native output", failures)
        output = checks.get("output_interface", {})
        fail_if(output.get("rtl_ports") == EXPECTED_OUTPUTS and output.get("mapped_ports") == EXPECTED_OUTPUTS,
                "RTL and mapped top output declarations differ from the 252-bit A2 interface", failures)
        fail_if(output.get("rtl_output_bits") == 252 and output.get("interfaces_identical") is True
                and output.get("all_252_expected_output_bits") is True,
                "The 252 A2 top-level output bits are not all represented identically", failures)
        fail_if(memory.get("reference_instances") == 11 and memory.get("implementation_instances") == 11,
                "Memory report does not contain 11 instances on each side", failures)
    return checks


def validate(evidence, workspace_root, archive):
    failures = []
    evidence = evidence.resolve(strict=True)
    actual = verify_checksums(evidence, failures)
    actual_names = set(actual)
    if (evidence / "SHA256SUMS.txt").is_file():
        actual_names.add("SHA256SUMS.txt")
    missing_required = sorted(REQUIRED_FILES - actual_names)
    fail_if(not missing_required, "Required A2 bundle files are missing: {}".format(", ".join(missing_required)), failures)
    allowed = set(REQUIRED_FILES)
    for path_name in actual_names - REQUIRED_FILES:
        path = PurePosixPath(path_name)
        allowed_log = len(path.parts) == 2 and path.parts[0] in {"export", "match", "verify"} and path.parts[1] in REMOTE_LOG_NAMES
        if not allowed_log:
            failures.append("Unexpected or excluded package file: {}".format(path_name))
    fail_if(actual_names <= (REQUIRED_FILES | {
        "{}/{}".format(phase, name)
        for phase in ("export", "match", "verify") for name in REMOTE_LOG_NAMES
    }), "Evidence directory contains unallowlisted files", failures)

    match_manifest = parse_json(evidence / "manifest_native_context_md5_at_match.json", failures)
    proof_manifest = parse_json(evidence / "manifest_native_context_md5_postreview.json", failures)
    export = parse_json(evidence / "export/run_summary.json", failures)
    match = parse_json(evidence / "match/run_summary.json", failures)
    verify = parse_json(evidence / "verify/run_summary.json", failures)
    verify_manifest(match_manifest, failures)
    verify_manifest(proof_manifest, failures)
    stable_match = {key: value for key, value in match_manifest.items() if key != "scripts"}
    stable_proof = {key: value for key, value in proof_manifest.items() if key != "scripts"}
    fail_if(stable_match == stable_proof, "Preflight and proof manifests differ on frozen A2 inputs or SVF content", failures)
    match_manifest_hash = sha256(evidence / "manifest_native_context_md5_at_match.json")
    proof_manifest_hash = sha256(evidence / "manifest_native_context_md5_postreview.json")
    match_runner_path = evidence / "run_d4_asic_A2_sync_formal_at_match.py"
    proof_runner_path = evidence / "run_d4_asic_A2_sync_formal.py"
    verify_run(evidence, "export", export, None, match_runner_path, failures)
    verify_run(evidence, "match", match, match_manifest_hash, match_runner_path, failures)
    proof_checks = verify_run(evidence, "verify", verify, proof_manifest_hash, proof_runner_path, failures)

    match_script_records = {Path(row.get("path", "")).name: row.get("sha256") for row in match_manifest.get("scripts", [])}
    proof_script_records = {Path(row.get("path", "")).name: row.get("sha256") for row in proof_manifest.get("scripts", [])}
    for records, runner, label in (
        (match_script_records, match_runner_path, "at-match"),
        (proof_script_records, proof_runner_path, "postreview"),
    ):
        for name, path in (
            ("asic_A2_formal.tcl", evidence / "asic_A2_formal.tcl"),
            ("prepare_d4_A2_svf_compat.py", evidence / "prepare_d4_A2_svf_compat.py"),
            ("run_d4_asic_A2_sync_formal.py", runner),
        ):
            fail_if(records.get(name) == sha256(path), "{} manifest does not bind {}".format(label, name), failures)

    expected_match_review = build_match_review(evidence, match, match_manifest)
    saved_match_review = parse_json(evidence / "match_postreview.json", failures)
    fail_if(saved_match_review == expected_match_review, "Saved match post-review differs from raw match evidence", failures)
    fail_if(expected_match_review.get("review_result") == "MATCH_READY", "Corrected offline A2 match review did not pass", failures)

    point_summary = parse_json(evidence / "point_summary.json", failures)
    fail_if(point_summary.get("matched_compare_points") == proof_checks.get("matched_compare_points"),
            "Derived point summary differs from final native result", failures)
    fail_if(point_summary.get("passing_compare_points") == proof_checks.get("passing_compare_points"),
            "Derived passing count differs from final native result", failures)
    memory_summary = parse_json(evidence / "memory_summary.json", failures)
    fail_if(memory_summary == proof_checks.get("memory_boundaries"), "Derived memory summary differs from proof run summary", failures)
    contract = parse_json(evidence / "run_contract.json", failures)
    fail_if(contract.get("full_proof_result") == verify.get("result"), "Derived run contract does not bind proof status", failures)
    readme = (evidence / "README.md").read_text(encoding="utf-8", errors="replace") if (evidence / "README.md").is_file() else ""
    fail_if("Status: **EQUIVALENCE_PASS**" in readme, "Short report does not report the accepted final status", failures)
    archive_hash = verify_archive(evidence, archive, failures)
    return failures, archive_hash


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, default=Path("artifacts/d4_asic_A2_sync_formal_20261020"))
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--workspace-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    try:
        failures, archive_hash = validate(args.evidence_dir, args.workspace_root, args.archive)
    except Exception as exc:
        print("D4_A2_SYNC_FORMAL_ACCEPT_FAIL={}".format(exc), file=sys.stderr)
        return 2
    if failures:
        print("D4_A2_SYNC_FORMAL_ACCEPT_FAIL_COUNT={}".format(len(failures)), file=sys.stderr)
        for failure in failures[:20]:
            print("FAIL: {}".format(failure), file=sys.stderr)
        return 2
    summary = json.loads((args.evidence_dir / "verify/run_summary.json").read_text(encoding="utf-8"))
    checks = summary["proof_checks"]
    print("D4_A2_SYNC_FORMAL_ACCEPT=PASS")
    print("D4_A2_SYNC_FORMAL_MATCHED_POINTS={}".format(checks["matched_compare_points"]))
    print("D4_A2_SYNC_FORMAL_OUTPUT_BITS={}".format(checks["output_interface"]["rtl_output_bits"]))
    print("D4_A2_SYNC_FORMAL_MEMORY_INSTANCES=11")
    if archive_hash:
        print("D4_A2_SYNC_FORMAL_ARCHIVE_SHA256={}".format(archive_hash))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
