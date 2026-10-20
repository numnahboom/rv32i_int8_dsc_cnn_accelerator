#!/usr/bin/env python3
"""Run one frozen A2 native export, match-only preflight, or full proof."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

try:
    from .prepare_d4_A2_svf_compat import (
        ROOT, RUN_TAG, SYNTH_TAG, build_manifest, candidate_inputs, file_hash,
    )
except ImportError:
    from prepare_d4_A2_svf_compat import (
        ROOT, RUN_TAG, SYNTH_TAG, build_manifest, candidate_inputs, file_hash,
    )


DEFAULT_FM_SHELL = Path("/opt/synopsys/fm/O-2018.06-SP1/bin/fm_shell")
DEFAULT_TCL = ROOT / "scripts/asic_A2_formal.tcl"
DEFAULT_MANIFEST = ROOT / "build/reports" / RUN_TAG / "manifest_native_context_md5.json"
DEFAULT_TIMEOUTS = {"export": 900, "match": 1800, "verify": 7200}
ERROR_RE = re.compile(r"^\s*Error\s*:", re.IGNORECASE)
MATCHED_RE = re.compile(r"\b(\d+) Compare points matched by name\b")
PASSING_RE = re.compile(r"\b(\d+) Passing compare points\b")
ZERO_FAIL_RE = re.compile(r"^Failing \(not equivalent\)(?:\s+0){8}\s*$", re.MULTILINE)
BLACKBOX_RE = re.compile(
    r"####\s+DESIGN LIBRARY - ([ri]):/[^\s]+\s+.*?"
    r"Type\s+Design Name\s+[-\s]+\s*(\w+)\s+.*?"
    r"Instances\s*:\s*(\d+)\s+of\s+(\d+)", re.DOTALL
)
EXPECTED_MEMORY_DESIGNS = {
    "D4_ACT_1024X128_M8": 1,
    "RASP2048X16M16": 2,
    **{"D4WROM{}".format(index): 1 for index in range(8)},
}
EXPECTED_OUTPUT_BITS = 252


def native_error_records(report_dir, console):
    records = []
    names = ["console.log"]
    for name in ("formality.log", "fm_shell_command.log"):
        if (report_dir / name).is_file():
            names.append(name)
    sources = [("console.log", console)]
    sources.extend((name, (report_dir / name).read_text(encoding="utf-8", errors="replace")) for name in names[1:])
    for name, text in sources:
        for line_number, line in enumerate(text.splitlines(), 1):
            if ERROR_RE.match(line):
                records.append({"log": name, "line_number": line_number, "text": line.strip()})
    return names, records


def memory_summary(path):
    found = {"r": {}, "i": {}}
    if not path.is_file():
        return False, {"error": "missing black_boxes.rpt"}
    for match in BLACKBOX_RE.finditer(path.read_text(encoding="utf-8", errors="replace")):
        side, design, count, declared = match.groups()
        count, declared = int(count), int(declared)
        if count != declared or design in found[side]:
            return False, {"error": "inconsistent or duplicate black-box row: {}/{}".format(side, design)}
        found[side][design] = count
    okay = found["r"] == EXPECTED_MEMORY_DESIGNS and found["i"] == EXPECTED_MEMORY_DESIGNS
    return okay, {
        "reference_designs": found["r"],
        "implementation_designs": found["i"],
        "reference_instances": sum(found["r"].values()),
        "implementation_instances": sum(found["i"].values()),
        "expected_identical_11_memory_instances": okay,
    }


def _module_block(text):
    match = re.search(r"(?m)^\s*module\s+d4_fullnet_top\b", text)
    if not match:
        raise ValueError("Cannot find d4_fullnet_top module")
    end = text.find("endmodule", match.end())
    if end < 0:
        raise ValueError("Missing endmodule for d4_fullnet_top")
    return text[match.start():end]


def source_outputs(text):
    match = re.search(
        r"\bmodule\s+d4_fullnet_top\s*#\s*\(.*?\)\s*\((.*?)\)\s*;",
        text, re.DOTALL,
    )
    if not match:
        raise ValueError("Cannot parse A2 RTL top-level ANSI port list")
    outputs = {}
    direction = None
    current_width = 1
    for part in match.group(1).split(","):
        direction_match = re.search(r"\b(input|output|inout)\b", part)
        if direction_match:
            direction = direction_match.group(1)
            width_match = re.search(r"\[(\d+)\s*:\s*(\d+)\]", part)
            current_width = 1 if not width_match else abs(int(width_match.group(1)) - int(width_match.group(2))) + 1
        if direction != "output":
            continue
        cleaned = re.sub(r"\b(output|wire|reg|logic|signed|unsigned)\b", " ", part)
        cleaned = re.sub(r"\[\d+\s*:\s*\d+\]", " ", cleaned)
        identifiers = re.findall(r"[A-Za-z_$][A-Za-z0-9_$]*", cleaned)
        if not identifiers:
            raise ValueError("Cannot parse one A2 RTL output declaration: {}".format(part))
        name = identifiers[-1]
        if name in outputs:
            raise ValueError("Duplicate A2 RTL output port: {}".format(name))
        outputs[name] = current_width
    return outputs


def mapped_outputs(text):
    block = _module_block(text)
    outputs = {}
    for declaration in re.findall(r"(?m)^\s*output\b[^;]*;", block):
        body = re.sub(r"^\s*output\b", "", declaration).rstrip(";").strip()
        width_match = re.search(r"\[(\d+)\s*:\s*(\d+)\]", body)
        width = 1 if not width_match else abs(int(width_match.group(1)) - int(width_match.group(2))) + 1
        if width_match:
            body = body[:width_match.start()] + body[width_match.end():]
        body = re.sub(r"\b(wire|reg|logic|signed|unsigned)\b", " ", body)
        for part in body.split(","):
            identifiers = re.findall(r"[A-Za-z_$][A-Za-z0-9_$]*", part)
            if not identifiers:
                continue
            name = identifiers[-1]
            if name in outputs:
                raise ValueError("Duplicate mapped A2 output port: {}".format(name))
            outputs[name] = width
    return outputs


def output_interface(root):
    source_path = root / "build/asic_eval/native_asymmetric_logic_rom_mask_weights/d4_fullnet_eval.sv"
    mapped_path = root / "build/reports" / SYNTH_TAG / "mapped.v"
    source = source_outputs(source_path.read_text(encoding="utf-8", errors="replace"))
    mapped = mapped_outputs(mapped_path.read_text(encoding="utf-8", errors="replace"))
    bits = sum(source.values())
    return {
        "rtl_ports": source,
        "mapped_ports": mapped,
        "rtl_output_bits": bits,
        "interfaces_identical": source == mapped,
        "all_252_expected_output_bits": bits == EXPECTED_OUTPUT_BITS and source == mapped,
    }


def report_checks(report_dir, console, root):
    error_logs, errors = native_error_records(report_dir, console)
    matched_values = [int(value) for value in MATCHED_RE.findall(console)]
    passing_values = [int(value) for value in PASSING_RE.findall(console)]
    matched = matched_values[-1] if matched_values else None
    passing = passing_values[-1] if passing_values else None
    unmatched_path = report_dir / "unmatched.rpt"
    unmatched_text = unmatched_path.read_text(encoding="utf-8", errors="replace") if unmatched_path.is_file() else ""
    no_unmatched = "No unmatched points." in unmatched_text
    memory_ok, memories = memory_summary(report_dir / "black_boxes.rpt")
    outputs = output_interface(root)
    dont_verify_path = report_dir / "dont_verify.rpt"
    dont_verify_text = dont_verify_path.read_text(encoding="utf-8", errors="replace") if dont_verify_path.is_file() else ""
    no_dont_verify = "Don't verify points:   None" in dont_verify_text or "Don't verify points: None" in dont_verify_text
    return {
        "native_error_logs_scanned": error_logs,
        "native_errors": errors,
        "matched_compare_points": matched,
        "passing_compare_points": passing,
        "matched_and_passing_counts_agree": matched is not None and matched == passing,
        "verification_succeeded": re.search(r"^Verification SUCCEEDED\s*$", console, re.MULTILINE) is not None,
        "zero_failing_summary": ZERO_FAIL_RE.search(console) is not None,
        "no_unmatched_points": no_unmatched,
        "memory_boundaries": memories,
        "memory_boundaries_valid": memory_ok,
        "output_interface": outputs,
        "no_dont_verify_points": no_dont_verify,
    }


def stop_process(proc):
    try:
        os.killpg(proc.pid, signal.SIGINT)
    except ProcessLookupError:
        return "already-exited"
    try:
        proc.wait(timeout=300)
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


def default_report_dir(phase, root):
    return root / "build/reports" / RUN_TAG / phase


def safe_report_dir(path, root):
    target = path.resolve()
    parent = (root / "build/reports" / RUN_TAG).resolve()
    try:
        target.relative_to(parent)
    except ValueError as exc:
        raise ValueError("Phase report directory must be under {}".format(parent)) from exc
    if target.exists():
        raise FileExistsError("Refusing to reuse phase report directory: {}".format(target))
    target.mkdir(parents=True, exist_ok=False)
    return target


def prepare_manifest(path, root):
    path = path.resolve(strict=True)
    manifest = json.loads(path.read_text(encoding="utf-8"))
    rebuilt = build_manifest(
        root,
        manifest["native_export"]["text_svf_path"],
        manifest["adapted_svf"]["path"],
        manifest["native_export"]["export_run_summary_path"],
    )
    if rebuilt != manifest:
        raise ValueError("A2 manifest no longer matches fixed mapping, sources, libraries, or native SVF context")
    if file_hash(manifest["adapted_svf"]["path"]) != manifest["adapted_svf"]["sha256"]:
        raise ValueError("A2 adapted SVF hash mismatch")
    return manifest


def run(args):
    root = args.root.resolve(strict=True)
    if args.phase != "export":
        manifest = prepare_manifest(args.manifest, root)
        guide = Path(manifest["adapted_svf"]["path"]).resolve(strict=True)
    else:
        candidate_inputs(root)
        manifest = None
        guide = None
    report_dir = safe_report_dir(args.report_dir or default_report_dir(args.phase, root), root)
    log_path = report_dir / "console.log"
    summary_path = report_dir / "run_summary.json"
    if not args.fm_shell.is_file():
        raise FileNotFoundError("Formality executable not found: {}".format(args.fm_shell))
    if not args.tcl.is_file():
        raise FileNotFoundError("A2 formal Tcl not found: {}".format(args.tcl))
    license_value = args.license_server or os.environ.get("SNPSLMD_LICENSE_FILE")
    if not license_value:
        raise ValueError("Set --license-server or SNPSLMD_LICENSE_FILE")
    env = os.environ.copy()
    env["SNPSLMD_LICENSE_FILE"] = license_value
    env["D4_ASIC_PROJECT_ROOT"] = str(root)
    env["D4_SYNTH_TAG"] = SYNTH_TAG
    for key in ("D4_FORMAL_EXPORT_SVF_ONLY", "D4_FORMAL_MATCH_ONLY", "D4_FORMAL_NO_SVF", "D4_FORMAL_ROUTED"):
        env.pop(key, None)
    env.pop("D4_SVF_OVERRIDE", None)
    if args.phase == "export":
        env["D4_FORMAL_EXPORT_SVF_ONLY"] = "1"
    else:
        env["D4_SVF_OVERRIDE"] = str(guide)
        if args.phase == "match":
            env["D4_FORMAL_MATCH_ONLY"] = "1"
    command = [str(args.fm_shell), "-f", str(args.tcl.resolve())]
    started = datetime.now(timezone.utc)
    started_mono = time.monotonic()
    timed_out = False
    interrupt_action = None
    with log_path.open("xb") as stream:
        proc = subprocess.Popen(
            command,
            cwd=report_dir,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            exit_code = proc.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            interrupt_action = stop_process(proc)
            exit_code = proc.returncode
    duration = round(time.monotonic() - started_mono, 3)
    console = log_path.read_text(encoding="utf-8", errors="replace")
    error_logs, errors = native_error_records(report_dir, console)
    common = {
        "schema_version": 1,
        "phase": args.phase,
        "started_utc": started.isoformat(),
        "duration_seconds": duration,
        "command": command,
        "working_directory": str(report_dir),
        "formal_tcl_sha256": file_hash(args.tcl.resolve()),
        "runner_sha256": file_hash(Path(__file__).resolve()),
        "adapter_sha256": file_hash(Path(__file__).resolve().with_name("prepare_d4_A2_svf_compat.py")),
        "manifest_path": None if manifest is None else str(args.manifest.resolve()),
        "manifest_sha256": None if manifest is None else file_hash(args.manifest.resolve()),
        "fixed_synth_tag": SYNTH_TAG,
        "fixed_mapped_sha256": None if manifest is None else manifest["fixed_candidate"]["mapped_sha256"],
        "license_server": license_value,
        "timeout_seconds": args.timeout_seconds,
        "timed_out": timed_out,
        "interrupt_action": interrupt_action,
        "exit_code": exit_code,
        "console_log": str(log_path),
        "console_sha256": file_hash(log_path),
        "native_error_logs_scanned": error_logs,
        "native_error_count": len(errors),
        "native_error_lines": errors[:20],
    }
    if args.phase == "export":
        native_svf = report_dir / "formality_svf/svf.txt"
        helper_root = report_dir / "formality_svf/d1"
        marker = "D4_A2_SVF_EXPORT_ONLY_COMPLETE=1" in console
        ready = native_svf.is_file() and helper_root.is_dir() and marker and exit_code == 0 and not timed_out
        common.update({
            "native_text_svf_path": str(native_svf),
            "native_text_svf_sha256": file_hash(native_svf) if native_svf.is_file() else None,
            "native_sidefile_root": str(helper_root),
            "native_sidefile_directory_present": helper_root.is_dir(),
            "export_only_marker": marker,
            "expected_parser_diagnostic_observed": bool(errors),
            "result": "NATIVE_EXPORT_READY" if ready else "NATIVE_EXPORT_FAILED_OR_INCOMPLETE",
            "acceptance_checks": {
                "process_exit_zero": exit_code == 0,
                "not_timed_out": not timed_out,
                "export_only_marker": marker,
                "native_text_svf_created": native_svf.is_file(),
                "native_sidefile_context_created": helper_root.is_dir(),
            },
        })
        passed = ready
    else:
        checks = report_checks(report_dir, console, root)
        common["proof_checks"] = checks
        if args.phase == "match":
            marker = "D4_A2_FORMAL_MATCH_ONLY_COMPLETE=1" in console
            passed = (
                exit_code == 0 and not timed_out and marker and not errors
                and checks["no_unmatched_points"] and checks["memory_boundaries_valid"]
                and checks["output_interface"]["all_252_expected_output_bits"]
            )
            common["match_only_marker"] = marker
            common["result"] = "MATCH_READY" if passed else "MATCH_DIAGNOSTIC_FAILED_OR_INCOMPLETE"
            common["acceptance_checks"] = {
                "process_exit_zero": exit_code == 0,
                "not_timed_out": not timed_out,
                "match_only_marker": marker,
                "no_native_error_lines": not errors,
                "no_unmatched_points": checks["no_unmatched_points"],
                "11_identical_memory_instances": checks["memory_boundaries_valid"],
                "252_output_bits_identical_and_compared": checks["output_interface"]["all_252_expected_output_bits"],
            }
        else:
            pass_marker = "D4_A2_RTL_TO_MAPPED_FORMAL_PASS scope=logic_with_identical_11_memory_boundaries_and_252_output_bits" in console
            passed = (
                exit_code == 0 and not timed_out and pass_marker and not errors
                and checks["verification_succeeded"] and checks["matched_and_passing_counts_agree"]
                and checks["zero_failing_summary"] and checks["no_unmatched_points"]
                and checks["memory_boundaries_valid"] and checks["output_interface"]["all_252_expected_output_bits"]
                and checks["no_dont_verify_points"]
            )
            common["pass_marker"] = pass_marker
            common["result"] = "EQUIVALENCE_PASS" if passed else "EQUIVALENCE_NEGATIVE_OR_INCOMPLETE"
            common["acceptance_checks"] = {
                "process_exit_zero": exit_code == 0,
                "not_timed_out": not timed_out,
                "a2_pass_marker": pass_marker,
                "no_native_error_lines": not errors,
                "native_verification_succeeded": checks["verification_succeeded"],
                "matched_and_passing_counts_agree": checks["matched_and_passing_counts_agree"],
                "actual_matched_compare_point_count": checks["matched_compare_points"],
                "zero_failing_summary": checks["zero_failing_summary"],
                "no_unmatched_points": checks["no_unmatched_points"],
                "11_identical_memory_instances": checks["memory_boundaries_valid"],
                "252_output_bits_identical_and_compared": checks["output_interface"]["all_252_expected_output_bits"],
                "no_dont_verify_points": checks["no_dont_verify_points"],
            }
            common["verification_completion_note"] = (
                "The actual compare-point total is parsed from the final Formality output. "
                "Completion requires its matched and passing counts to agree, the zero-failing summary, "
                "and no unmatched points; no periodic progress token is required."
            )
        for name in ("failing.rpt", "unverified_points.rpt", "aborted_points.rpt"):
            path = report_dir / name
            if path.is_file():
                common.setdefault("failure_reports", []).append({"name": name, "sha256": file_hash(path), "size": path.stat().st_size})
    common["summary_path"] = str(summary_path)
    summary_path.write_text(json.dumps(common, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("D4_A2_FORMAL_{}_RESULT={}".format(args.phase.upper(), common["result"]))
    print("D4_A2_FORMAL_NATIVE_ERRORS={}".format(len(errors)))
    if common.get("proof_checks"):
        print("D4_A2_FORMAL_MATCHED_POINTS={}".format(common["proof_checks"]["matched_compare_points"]))
        print("D4_A2_FORMAL_PASSING_POINTS={}".format(common["proof_checks"]["passing_compare_points"]))
        print("D4_A2_FORMAL_OUTPUT_BITS={}".format(common["proof_checks"]["output_interface"]["rtl_output_bits"]))
    print("D4_A2_FORMAL_REPORT_DIR={}".format(report_dir))
    print("D4_A2_FORMAL_SUMMARY={}".format(summary_path))
    return 0 if passed else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=("export", "match", "verify"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report-dir", type=Path)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--fm-shell", type=Path, default=DEFAULT_FM_SHELL)
    parser.add_argument("--tcl", type=Path, default=DEFAULT_TCL)
    parser.add_argument("--license-server")
    parser.add_argument("--timeout-seconds", type=int)
    args = parser.parse_args(argv)
    if args.timeout_seconds is None:
        args.timeout_seconds = DEFAULT_TIMEOUTS[args.phase]
    if args.timeout_seconds <= 0 or (args.phase == "verify" and args.timeout_seconds > 7200):
        parser.error("timeout must be positive and full verification is capped at 7200 seconds")
    try:
        return run(args)
    except Exception as exc:
        print("D4_A2_FORMAL_RUNNER_FAIL={}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
