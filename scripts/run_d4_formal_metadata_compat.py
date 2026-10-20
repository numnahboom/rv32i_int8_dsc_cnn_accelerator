#!/usr/bin/env python3
"""Run a fixed A3 Formality metadata-compatibility match or proof phase.

The runner validates the source MD5, fixed mapped-netlist SHA256, adapted SVF,
operative-guidance hash, and native sidefile inventory before every launch.
Match-only mode stops immediately after ``match``; verify mode uses the normal
Formality default ``verify`` strategy with no assumptions or waivers.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

try:
    from .prepare_d4_svf_compat_probe import (
        FIXED_MAPPED_SHA256,
        FIXED_SYNTH_TAG,
        ROOT,
        file_hash,
        validate_manifest,
    )
except ImportError:  # direct ``python scripts/run_...py`` invocation
    from prepare_d4_svf_compat_probe import (
        FIXED_MAPPED_SHA256,
        FIXED_SYNTH_TAG,
        ROOT,
        file_hash,
        validate_manifest,
    )


DEFAULT_MANIFEST = ROOT / "build/reports/asic_svf_compat_parser_20261020/manifest_native_context_md5.json"
DEFAULT_FM_SHELL = Path("/opt/synopsys/fm/O-2018.06-SP1/bin/fm_shell")
DEFAULT_TCL = ROOT / "scripts/asic_A3_formal.tcl"
DEFAULT_LICENSE = "27000@ic03"
KEY_GUIDANCE_BASELINE = {
    "architecture_netlist": (22, 0, 22),
    "boundary_netlist": (21, 0, 21),
    "datapath": (87, 1, 88),
    "multiplier": (81, 0, 81),
}
GUIDANCE_ROW_RE = re.compile(r"^\s*([a-z_]+)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")
ERROR_LINE_RE = re.compile(r"^\s*Error\s*:", re.IGNORECASE)
ZERO_FAIL_ROW_RE = re.compile(
    r"^Failing \(not equivalent\)(?:\s+0){8}\s*$", re.MULTILINE
)
BLACKBOX_SECTION_RE = re.compile(
    r"####\s+DESIGN LIBRARY - ([ri]):/[^\s]+\s+.*?"
    r"Type\s+Design Name\s+[-\s]+\s*(\w+)\s+(\w+)\s+.*?"
    r"Instances\s*:\s*(\d+)\s+of\s+(\d+)",
    re.DOTALL,
)
EXPECTED_MEMORY_DESIGNS = {
    "D4_ACT_1024X128_M8": 1,
    "RASP2048X16M16": 2,
    **{f"D4RROM{i}": 1 for i in range(8)},
    **{f"D4WROM{i}": 1 for i in range(8)},
}


def parse_guidance(log):
    lines = log.splitlines()
    starts = [i for i, line in enumerate(lines) if "Guidance Summary" in line]
    if not starts:
        return {}
    result = {}
    for line in lines[starts[-1] + 1:]:
        match = GUIDANCE_ROW_RE.match(line)
        if match:
            name, accepted, rejected, unsupported, unprocessed, total = match.groups()
            result[name] = {
                "accepted": int(accepted), "rejected": int(rejected),
                "unsupported": int(unsupported), "unprocessed": int(unprocessed),
                "total": int(total),
            }
        elif result and (not line.strip() or line.startswith("Note:")):
            break
    return result


def native_error_log_names(report_dir):
    names = ["console.log"]
    for name in ("formality.log", "fm_shell_command.log"):
        if (report_dir / name).is_file():
            names.append(name)
    return names


def native_error_records(report_dir, console_text):
    records = []
    sources = [("console.log", console_text)]
    for name in native_error_log_names(report_dir)[1:]:
        path = report_dir / name
        sources.append((name, path.read_text(encoding="utf-8", errors="replace")))
    for name, text in sources:
        for line_number, line in enumerate(text.splitlines(), 1):
            if ERROR_LINE_RE.match(line):
                records.append({"log": name, "line_number": line_number, "text": line.strip()})
    return records


def key_guidance_check(summary):
    issues = []
    for name, expected in KEY_GUIDANCE_BASELINE.items():
        row = summary.get(name)
        actual = None if row is None else (row["accepted"], row["rejected"], row["total"])
        if actual != expected:
            issues.append(f"{name}: expected accepted/rejected/total={expected}, got {actual}")
    return not issues, issues


def memory_blackbox_check(path):
    if not path.is_file():
        return False, {"error": f"missing report: {path}"}
    text = path.read_text(encoding="utf-8", errors="replace")
    found = {"r": {}, "i": {}}
    totals = {"r": 0, "i": 0}
    for match in BLACKBOX_SECTION_RE.finditer(text):
        side, _library, design, instances, declared = match.groups()
        count = int(instances)
        if count != int(declared) or design in found[side]:
            return False, {"error": f"inconsistent/duplicate black-box row: {side}/{design}"}
        found[side][design] = count
        totals[side] += count
    expected = EXPECTED_MEMORY_DESIGNS
    ok = found["r"] == expected and found["i"] == expected and totals == {"r": 19, "i": 19}
    return ok, {
        "unique_designs_per_side": {side: len(found[side]) for side in ("r", "i")},
        "instances_per_side": totals,
        "reference_designs": found["r"],
        "implementation_designs": found["i"],
        "identical_expected_memory_boundaries": ok,
    }


def safe_report_dir(path):
    target = path.resolve()
    reports = (ROOT / "build/reports").resolve()
    try:
        target.relative_to(reports)
    except ValueError as exc:
        raise ValueError(f"Run report directory must be under {reports}") from exc
    if target.exists():
        raise FileExistsError(f"Refusing to reuse report directory: {target}")
    return target


def proof_log_checks(log_text, report_dir):
    errors = native_error_records(report_dir, log_text)
    guidance = parse_guidance(log_text)
    guidance_ok, guidance_issues = key_guidance_check(guidance)
    formal_success = re.search(r"^Verification SUCCEEDED\s*$", log_text, re.MULTILINE) is not None
    matched = re.search(r"\b13758 Compare points matched by name\b", log_text) is not None
    passing = re.search(r"\b13758 Passing compare points\b", log_text) is not None
    zero_failing = ZERO_FAIL_ROW_RE.search(log_text) is not None
    unmatched_path = report_dir / "unmatched.rpt"
    unmatched_text = unmatched_path.read_text(encoding="utf-8", errors="replace") if unmatched_path.is_file() else ""
    no_unmatched = bool(unmatched_text) and "No unmatched points." in unmatched_text
    memory_ok, memory_summary = memory_blackbox_check(report_dir / "black_boxes.rpt")
    complete_proof = formal_success and matched and passing and zero_failing
    return {
        "native_errors": errors,
        "native_error_log_files_scanned": native_error_log_names(report_dir),
        "guidance": guidance,
        "guidance_ok": guidance_ok,
        "guidance_issues": guidance_issues,
        "formal_success": formal_success,
        "matched_13758": matched,
        "passing_13758": passing,
        "zero_failing": zero_failing,
        "complete_proof_from_formality_final_summary": complete_proof,
        "no_unmatched": no_unmatched,
        "memory_ok": memory_ok,
        "memory_summary": memory_summary,
        "accepted": (not errors and guidance_ok and complete_proof and no_unmatched and memory_ok),
    }


def terminate_with_interrupt(proc, grace_seconds):
    try:
        os.killpg(proc.pid, signal.SIGINT)
    except ProcessLookupError:
        return "already-exited"
    try:
        proc.wait(timeout=grace_seconds)
        return "SIGINT"
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return "SIGINT_then_exit"
        try:
            proc.wait(timeout=30)
            return "SIGINT_then_SIGTERM"
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            return "SIGINT_then_SIGTERM_then_SIGKILL"


def run(args):
    manifest_path = args.manifest.resolve(strict=True)
    manifest = validate_manifest(manifest_path)
    if manifest["fixed_candidate"]["synth_tag"] != FIXED_SYNTH_TAG:
        raise ValueError("Run manifest does not identify the fixed A3 sync-reset source")
    if manifest["fixed_candidate"]["mapped_sha256"] != FIXED_MAPPED_SHA256:
        raise ValueError("Run manifest mapped hash differs from the fixed candidate")

    report_dir = safe_report_dir(args.report_dir)
    report_dir.mkdir(parents=True, exist_ok=False)
    log_path = report_dir / "console.log"
    summary_path = report_dir / "run_summary.json"
    if not args.fm_shell.is_file():
        raise FileNotFoundError(f"Formality executable not found: {args.fm_shell}")
    if not args.tcl.is_file():
        raise FileNotFoundError(f"A3 formal Tcl not found: {args.tcl}")

    license_value = args.license_server or os.environ.get("SNPSLMD_LICENSE_FILE")
    if not license_value:
        raise ValueError("Set --license-server or SNPSLMD_LICENSE_FILE")
    adapted_svf = Path(manifest["adapted_svf"]["path"]).resolve(strict=True)
    env = os.environ.copy()
    env["SNPSLMD_LICENSE_FILE"] = license_value
    env["D4_SYNTH_TAG"] = FIXED_SYNTH_TAG
    env["D4_SVF_OVERRIDE"] = str(adapted_svf)
    env.pop("D4_FORMAL_NO_SVF", None)
    if args.phase == "match":
        env["D4_FORMAL_MATCH_ONLY"] = "1"
    else:
        env.pop("D4_FORMAL_MATCH_ONLY", None)
    command = [str(args.fm_shell), "-f", str(args.tcl.resolve())]

    start = datetime.now(timezone.utc)
    started_monotonic = time.monotonic()
    timed_out = False
    interrupt_action = None
    with log_path.open("xb") as log_stream:
        proc = subprocess.Popen(
            command,
            cwd=report_dir,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log_stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            exit_code = proc.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            interrupt_action = terminate_with_interrupt(proc, args.interrupt_grace_seconds)
            exit_code = proc.returncode
    duration = round(time.monotonic() - started_monotonic, 3)

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    errors = native_error_records(report_dir, log_text)
    guidance = parse_guidance(log_text)
    guidance_ok, guidance_issues = key_guidance_check(guidance)
    common = {
        "schema_version": 1,
        "phase": args.phase,
        "started_utc": start.isoformat(),
        "duration_seconds": duration,
        "command": command,
        "working_directory": str(report_dir),
        "formal_tcl_sha256": file_hash(args.tcl.resolve()),
        "runner_sha256": file_hash(Path(__file__).resolve()),
        "adapter_sha256": file_hash(Path(__file__).resolve().with_name("prepare_d4_svf_compat_probe.py")),
        "manifest_sha256": file_hash(manifest_path),
        "fixed_synth_tag": FIXED_SYNTH_TAG,
        "fixed_mapped_sha256": FIXED_MAPPED_SHA256,
        "adapted_svf_sha256": manifest["adapted_svf"]["sha256"],
        "operative_guidance_sha256": manifest["adapted_svf"]["operative_guidance_sha256_after_removing_file_info"],
        "source_md5": manifest["native_svf"]["sources"][0]["actual_md5"],
        "native_helper_file_count": manifest["native_relative_helper_context"]["file_count"],
        "native_helper_inventory_sha256": manifest["native_relative_helper_context"]["inventory_sha256"],
        "strategy": "set synopsys_auto_setup true; verify uses Formality default strategy with no manual strategy flags",
        "license_server": license_value,
        "timeout_seconds": args.timeout_seconds,
        "timed_out": timed_out,
        "interrupt_action": interrupt_action,
        "exit_code": exit_code,
        "log_path": str(log_path),
        "log_sha256": file_hash(log_path),
        "native_error_count": len(errors),
        "native_error_lines": errors[:12],
        "guidance": guidance,
        "key_guidance_matches_original_native_baseline": guidance_ok,
        "key_guidance_issues": guidance_issues,
    }

    if args.phase == "match":
        marker_ok = "D4_A3_FORMAL_MATCH_ONLY_COMPLETE=1" in log_text
        memory_ok, memory_summary = memory_blackbox_check(report_dir / "black_boxes.rpt")
        passed = exit_code == 0 and not timed_out and marker_ok and not errors and guidance_ok and memory_ok
        common["match_only_marker"] = marker_ok
        common["memory_blackboxes"] = memory_summary
        common["result"] = "MATCH_READY" if passed else "MATCH_DIAGNOSTIC_FAILED_OR_INCOMPLETE"
        common["acceptance_checks"] = {
            "process_exit_zero": exit_code == 0,
            "not_timed_out": not timed_out,
            "match_only_marker": marker_ok,
            "no_native_error_lines": not errors,
            "key_guidance_matches_original_native_baseline": guidance_ok,
            "19_identical_memory_blackbox_instances": memory_ok,
        }
    else:
        checks = proof_log_checks(log_text, report_dir)
        pass_marker = "D4_A3_RTL_TO_MAPPED_FORMAL_PASS scope=logic_with_identical_19_memory_boundaries" in log_text
        passed = exit_code == 0 and not timed_out and pass_marker and checks["accepted"]
        common["memory_blackboxes"] = checks["memory_summary"]
        common["result"] = "EQUIVALENCE_PASS" if passed else "EQUIVALENCE_NEGATIVE_OR_INCOMPLETE"
        common["acceptance_checks"] = {
            "process_exit_zero": exit_code == 0,
            "not_timed_out": not timed_out,
            "pass_marker": pass_marker,
            "13758_matched": checks["matched_13758"],
            "13758_passing": checks["passing_13758"],
            "formality_reports_success_and_zero_failing": checks["formal_success"] and checks["zero_failing"],
            "no_unmatched_points": checks["no_unmatched"],
            "no_native_error_lines": not checks["native_errors"],
            "key_guidance_matches_original_native_baseline": checks["guidance_ok"],
            "19_identical_memory_blackbox_instances": checks["memory_ok"],
        }
        common["verification_completion_note"] = (
            "Formality does not emit a standalone unverified-count progress token on every completed run. "
            "A final Verification SUCCEEDED status with all 13758 compare points passing and a zero-failing "
            "table is used as the completed-proof criterion; partial/timed-out runs do not satisfy it."
        )
        for name in ("failing.rpt", "unverified_points.rpt", "aborted_points.rpt"):
            path = report_dir / name
            if path.is_file():
                common.setdefault("failure_reports", []).append({"path": str(path), "sha256": file_hash(path), "size": path.stat().st_size})

    common["summary_path"] = str(summary_path)
    summary_path.write_text(json.dumps(common, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"D4_FORMAL_COMPAT_{args.phase.upper()}_RESULT={common['result']}")
    print(f"D4_FORMAL_COMPAT_NATIVE_ERRORS={len(errors)}")
    print(f"D4_FORMAL_COMPAT_KEY_GUIDANCE_BASELINE_MATCH={int(guidance_ok)}")
    if guidance:
        for name in KEY_GUIDANCE_BASELINE:
            row = guidance.get(name)
            if row:
                print(f"D4_GUIDANCE_{name}={row['accepted']}/{row['rejected']}/{row['total']}")
    print(f"D4_FORMAL_COMPAT_LOG={log_path}")
    print(f"D4_FORMAL_COMPAT_SUMMARY={summary_path}")
    return 0 if passed else 2


def review_existing(args):
    report_dir = args.review_existing.resolve(strict=True)
    if not report_dir.is_dir():
        raise ValueError(f"Existing report directory is not a directory: {report_dir}")
    current_manifest_path = args.manifest.resolve(strict=True)
    current_manifest = validate_manifest(current_manifest_path)
    original_manifest_path = args.run_manifest.resolve(strict=True)
    original_manifest_hash = file_hash(original_manifest_path)
    old_summary_path = report_dir / "run_summary.json"
    old_summary = json.loads(old_summary_path.read_text(encoding="utf-8"))
    if old_summary.get("manifest_sha256") != original_manifest_hash:
        raise ValueError("Saved run summary does not point to the supplied at-run manifest")
    expected = {
        "fixed_mapped_sha256": current_manifest["fixed_candidate"]["mapped_sha256"],
        "adapted_svf_sha256": current_manifest["adapted_svf"]["sha256"],
        "operative_guidance_sha256": current_manifest["adapted_svf"]["operative_guidance_sha256_after_removing_file_info"],
        "source_md5": current_manifest["native_svf"]["sources"][0]["actual_md5"],
        "native_helper_file_count": current_manifest["native_relative_helper_context"]["file_count"],
        "native_helper_inventory_sha256": current_manifest["native_relative_helper_context"]["inventory_sha256"],
    }
    for key, value in expected.items():
        if old_summary.get(key) != value:
            raise ValueError(f"At-run summary and current validated manifest disagree on {key}")
    log_path = report_dir / "console.log"
    if file_hash(log_path) != old_summary.get("log_sha256"):
        raise ValueError("Full-run console.log changed after the recorded runner summary")
    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    checks = proof_log_checks(log_text, report_dir)
    pass_marker = "D4_A3_RTL_TO_MAPPED_FORMAL_PASS scope=logic_with_identical_19_memory_boundaries" in log_text
    accepted = (
        old_summary.get("exit_code") == 0 and not old_summary.get("timed_out")
        and pass_marker and checks["accepted"]
    )
    original_manifest = json.loads(original_manifest_path.read_text(encoding="utf-8"))
    old_scripts = original_manifest.get("scripts", [])
    executed_runner = next((row for row in old_scripts if Path(row["path"]).name == "run_d4_formal_metadata_compat.py"), None)
    report_hashes = {}
    for name in (
        "console.log", "formality.log", "fm_shell_command.log", "unmatched.rpt",
        "black_boxes.rpt", "dont_verify.rpt", "constants.rpt",
    ):
        path = report_dir / name
        if path.is_file():
            report_hashes[name] = file_hash(path)
    native = current_manifest["native_svf"]
    adapted = current_manifest["adapted_svf"]
    helper_context = current_manifest["native_relative_helper_context"]
    source_bindings = [
        {
            "path": row["path"],
            "svf_md5": row["svf_md5"],
            "actual_md5": row["actual_md5"],
            "actual_sha256": row["actual_sha256"],
        }
        for row in native["sources"]
    ]
    review_name = Path(args.review_output)
    if review_name.name != str(review_name):
        raise ValueError("--review-output must be a filename inside the existing report directory")
    review_path = report_dir / review_name
    if review_path.exists():
        raise FileExistsError(f"Refusing to overwrite review result: {review_path}")
    review = {
        "schema_version": 1,
        "result": "EQUIVALENCE_PASS" if accepted else "EQUIVALENCE_NEGATIVE_OR_INCOMPLETE",
        "reviewed_utc": datetime.now(timezone.utc).isoformat(),
        "at_run_summary_path": str(old_summary_path),
        "at_run_summary_sha256": file_hash(old_summary_path),
        "at_run_manifest_path": str(original_manifest_path),
        "at_run_manifest_sha256": original_manifest_hash,
        "at_run_runner_sha256": None if executed_runner is None else executed_runner["sha256"],
        "review_manifest_path": str(current_manifest_path),
        "review_manifest_sha256": file_hash(current_manifest_path),
        "review_runner_sha256": file_hash(Path(__file__).resolve()),
        "console_log_path": str(log_path),
        "console_log_sha256": file_hash(log_path),
        "report_hashes": report_hashes,
        "proof_point_counts": {
            "matched": 13758 if checks["matched_13758"] else None,
            "passing": 13758 if checks["passing_13758"] else None,
            "failing": 0 if checks["zero_failing"] else None,
            "unmatched": 0 if checks["no_unmatched"] else None,
            "unverified_counter_printed_by_formality": False,
        },
        "source_binding": {
            "fixed_synth_tag": current_manifest["fixed_candidate"]["synth_tag"],
            "mapped_sha256": current_manifest["fixed_candidate"]["mapped_sha256"],
            "sources": source_bindings,
        },
        "metadata_only_transform": {
            "compatibility_mode": current_manifest["compatibility_mode"],
            "native_svf_sha256": native["sha256"],
            "native_svf_size": native["size"],
            "native_guide_info_file_commands": native["guide_info_file_commands"],
            "adapted_svf_sha256_only": adapted["sha256"],
            "operative_guidance_sha256": adapted["operative_guidance_sha256_after_removing_file_info"],
            "only_file_info_metadata_changed": adapted["only_file_info_metadata_changed"],
        },
        "native_sidefile_context": {
            "helper_base": helper_context["helper_base"],
            "relative_helper_file_count": helper_context["file_count"],
            "relative_helper_inventory_sha256": helper_context["inventory_sha256"],
            "references": helper_context["references"],
        },
        "at_run_wrapper_classification": {
            "original_result": old_summary.get("result"),
            "original_progress_token_gate": old_summary.get("acceptance_checks", {}).get("0_fail_0_aborted_13758_pass_0_unverified"),
            "classification_note": "The completed native console has no periodic progress-token match; this check does not override Formality's final success/point summary.",
        },
        "prior_run_evidence": current_manifest.get("diagnosis", {}).get("prior_run_evidence", {}),
        "prior_124_unverified_point_identities": current_manifest.get("diagnosis", {}).get("prior_124_unverified_point_identities"),
        "native_errors": checks["native_errors"],
        "native_error_log_files_scanned": checks["native_error_log_files_scanned"],
        "guidance": checks["guidance"],
        "memory_blackboxes": checks["memory_summary"],
        "acceptance_checks": {
            "recorded_at_run_exit_zero": old_summary.get("exit_code") == 0,
            "recorded_at_run_not_timed_out": not old_summary.get("timed_out"),
            "formal_pass_marker": pass_marker,
            "formality_verification_succeeded": checks["formal_success"],
            "13758_compare_points_matched": checks["matched_13758"],
            "13758_compare_points_passing": checks["passing_13758"],
            "zero_failing_compare_points": checks["zero_failing"],
            "no_unmatched_points": checks["no_unmatched"],
            "no_native_error_lines": not checks["native_errors"],
            "key_guidance_matches_original_native_baseline": checks["guidance_ok"],
            "19_identical_memory_blackbox_instances": checks["memory_ok"],
        },
        "inference_limit": "FM 2018 final success plus 13758 passing and 0 failing is accepted as complete proof; the completed console does not print a separate 0-unverified counter.",
        "scope_limit": "memory macro contents remain a separate gate-side validation; this is RTL-to-mapped logic equivalence with identical 19 macro instance boundaries",
    }
    review_path.write_text(json.dumps(review, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"D4_FORMAL_COMPAT_REVIEW_RESULT={review['result']}")
    print(f"D4_FORMAL_COMPAT_REVIEW_NATIVE_ERRORS={len(checks['native_errors'])}")
    print(f"D4_FORMAL_COMPAT_REVIEW_SUMMARY={review_path}")
    return 0 if accepted else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("match", "verify"))
    parser.add_argument("--report-dir", type=Path)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--run-manifest", type=Path, default=DEFAULT_MANIFEST,
                        help="manifest recorded by an existing run during --review-existing")
    parser.add_argument("--review-existing", type=Path,
                        help="audit an existing completed run without launching Formality")
    parser.add_argument("--review-output", default="final_acceptance_review.json",
                        help="new review filename inside the existing report directory")
    parser.add_argument("--fm-shell", type=Path, default=DEFAULT_FM_SHELL)
    parser.add_argument("--tcl", type=Path, default=DEFAULT_TCL)
    parser.add_argument("--license-server", default=DEFAULT_LICENSE)
    parser.add_argument("--timeout-seconds", type=int)
    parser.add_argument("--interrupt-grace-seconds", type=int, default=300)
    args = parser.parse_args(argv)
    if args.timeout_seconds is None:
        args.timeout_seconds = 1800 if args.phase == "match" else 21600
    if args.timeout_seconds < 1 or args.interrupt_grace_seconds < 1:
        parser.error("Timeout and interrupt grace must be positive")
    try:
        if args.review_existing is not None:
            return review_existing(args)
        if args.phase is None or args.report_dir is None:
            parser.error("--phase and --report-dir are required unless --review-existing is used")
        return run(args)
    except Exception as exc:
        print(f"D4_FORMAL_COMPAT_RUNNER_FAIL={exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
