#!/usr/bin/env python3
"""Verify the local A3 Formality compatibility evidence bundle and archive."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile


FIXED_SYNTH_TAG = "asic_A3_sync_reset_tt_20261020"
FIXED_MAPPED_SHA256 = "12861917f2bdd9a45fdb5fe19585a69c6262b4520795eebe7972ac2eb236f898"
FIXED_SOURCE_MD5 = "43487b16ac9a042b43c87e9dca1a1c99"
EXPECTED_OPERATIVE_SHA256 = "c51224b8076be58995efd021303802a4a9b7fc8bdb563e70187a8653285c530c"
KEY_GUIDANCE_BASELINE = {
    "architecture_netlist": (22, 0, 22),
    "boundary_netlist": (21, 0, 21),
    "datapath": (87, 1, 88),
    "multiplier": (81, 0, 81),
}
EXPECTED_MEMORY_DESIGNS = {
    "D4_ACT_1024X128_M8": 1,
    "RASP2048X16M16": 2,
}
EXPECTED_MEMORY_DESIGNS.update({"D4RROM{}".format(index): 1 for index in range(8)})
EXPECTED_MEMORY_DESIGNS.update({"D4WROM{}".format(index): 1 for index in range(8)})
ALLOWED_SUFFIXES = {".json", ".log", ".rpt", ".py", ".md", ".txt"}
GUIDANCE_ROW_RE = re.compile(r"^\s*([a-z_]+)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")
ERROR_RE = re.compile(r"^\s*Error\s*:", re.IGNORECASE)
ZERO_FAIL_RE = re.compile(r"^Failing \(not equivalent\)(?:\s+0){8}\s*$", re.MULTILINE)
BLACKBOX_SECTION_RE = re.compile(
    r"####\s+DESIGN LIBRARY - ([ri]):/[^\s]+\s+.*?"
    r"Type\s+Design Name\s+[-\s]+\s*(\w+)\s+(\w+)\s+.*?"
    r"Instances\s*:\s*(\d+)\s+of\s+(\d+)", re.DOTALL
)
REQUIRED_FILES = {
    "console.log", "formality.log", "fm_shell_command.log", "unmatched.rpt",
    "black_boxes.rpt", "dont_verify.rpt", "constants.rpt", "run_summary.json",
    "final_acceptance_review_all_native_logs.json",
    "manifest_native_context_md5.json",
    "manifest_native_context_md5_postreview_full_log_scan.json",
    "prepare_d4_svf_compat_probe.py", "run_d4_formal_metadata_compat.py",
    "collect_d4_asic_formal_compat.py", "accept_d4_asic_formal_compat.py",
    "guidance_summary.json", "point_summary.json", "prior_boundary_evidence.json",
    "run_contract.json", "README.md", "SHA256SUMS.txt",
}
SOURCE_RELATIVE = Path("build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fail_if(condition, message, failures):
    if not condition:
        failures.append(message)


def parse_guidance(text):
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if "Guidance Summary" in line]
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


def verify_file_checksums(evidence, failures):
    checksum_path = evidence / "SHA256SUMS.txt"
    records = {}
    for line in checksum_path.read_text(encoding="ascii").splitlines():
        match = re.match(r"^([0-9a-f]{64})  ([^\s]+)$", line)
        if not match:
            failures.append("Malformed SHA256SUMS.txt line: {}".format(line))
            continue
        digest, name = match.groups()
        safe = PurePosixPath(name)
        if safe.is_absolute() or ".." in safe.parts or name in records:
            failures.append("Unsafe/duplicate checksum path: {}".format(name))
            continue
        records[name] = digest
    actual = {
        path.relative_to(evidence).as_posix(): path
        for path in evidence.rglob("*") if path.is_file() and path.name != "SHA256SUMS.txt"
    }
    if set(records) != set(actual):
        failures.append("SHA256SUMS file set differs from the evidence directory")
    for name, path in actual.items():
        if path.suffix.lower() not in ALLOWED_SUFFIXES:
            failures.append("Disallowed artifact type: {}".format(name))
        if records.get(name) != sha256_file(path):
            failures.append("Artifact checksum mismatch: {}".format(name))
    return records


def verify_zip(evidence, archive, failures):
    if not archive.is_file():
        failures.append("Archive not found: {}".format(archive))
        return None
    archive_hash = sha256_file(archive)
    sidecar = Path(str(archive) + ".sha256")
    if not sidecar.is_file():
        failures.append("Archive SHA256 sidecar is missing")
    else:
        fields = sidecar.read_text(encoding="ascii").strip().split()
        if not fields or fields[0] != archive_hash:
            failures.append("Archive SHA256 sidecar does not match")
    disk_files = {
        path.relative_to(evidence).as_posix(): path.read_bytes()
        for path in evidence.rglob("*") if path.is_file()
    }
    try:
        with zipfile.ZipFile(str(archive), "r") as bundle:
            names = bundle.namelist()
            if len(names) != len(set(names)):
                failures.append("Archive contains duplicate members")
            if set(names) != set(disk_files):
                failures.append("Archive member set differs from the validated evidence directory")
            for name in names:
                safe = PurePosixPath(name)
                if safe.is_absolute() or ".." in safe.parts:
                    failures.append("Unsafe archive member: {}".format(name))
                    continue
                if Path(name).suffix.lower() not in ALLOWED_SUFFIXES:
                    failures.append("Disallowed archive member type: {}".format(name))
                data = bundle.read(name)
                if name in disk_files and data != disk_files[name]:
                    failures.append("Archive content differs from validated file: {}".format(name))
    except (OSError, zipfile.BadZipFile) as exc:
        failures.append("Cannot read archive: {}".format(exc))
    return archive_hash


def verify_blackboxes(text):
    found = {"r": {}, "i": {}}
    totals = {"r": 0, "i": 0}
    for match in BLACKBOX_SECTION_RE.finditer(text):
        side, _library, design, instances, declared = match.groups()
        count = int(instances)
        if count != int(declared) or design in found[side]:
            return False, {"error": "inconsistent/duplicate row {}:{}".format(side, design)}
        found[side][design] = count
        totals[side] += count
    expected = EXPECTED_MEMORY_DESIGNS
    okay = found["r"] == expected and found["i"] == expected and totals == {"r": 19, "i": 19}
    return okay, {"reference": found["r"], "implementation": found["i"], "instances": totals}


def validate_evidence(evidence, workspace_root, failures):
    actual_files = {path.relative_to(evidence).as_posix() for path in evidence.rglob("*") if path.is_file()}
    if actual_files != REQUIRED_FILES:
        failures.append("Evidence file set does not match the explicit public allowlist")
    records = verify_file_checksums(evidence, failures)

    def read_json(name):
        try:
            return json.loads((evidence / name).read_text(encoding="utf-8"))
        except Exception as exc:
            failures.append("Cannot parse {}: {}".format(name, exc))
            return {}

    review = read_json("final_acceptance_review_all_native_logs.json")
    run_summary = read_json("run_summary.json")
    at_run_manifest = read_json("manifest_native_context_md5.json")
    review_manifest = read_json("manifest_native_context_md5_postreview_full_log_scan.json")
    derived_points = read_json("point_summary.json")
    derived_guidance = read_json("guidance_summary.json")
    derived_boundary = read_json("prior_boundary_evidence.json")
    derived_contract = read_json("run_contract.json")

    fail_if(review.get("result") == "EQUIVALENCE_PASS", "Post-review record does not report EQUIVALENCE_PASS", failures)
    fail_if(run_summary.get("result") == "EQUIVALENCE_NEGATIVE_OR_INCOMPLETE", "Original wrapper negative summary was not preserved", failures)
    fail_if(review.get("at_run_wrapper_classification", {}).get("original_result") == run_summary.get("result"), "Post-review does not bind the original wrapper classification", failures)
    fail_if(review.get("at_run_summary_sha256") == sha256_file(evidence / "run_summary.json"), "Original run summary hash binding failed", failures)
    fail_if(review.get("at_run_manifest_sha256") == sha256_file(evidence / "manifest_native_context_md5.json"), "At-run manifest hash binding failed", failures)
    fail_if(run_summary.get("manifest_sha256") == review.get("at_run_manifest_sha256"), "Original summary and at-run manifest hashes differ", failures)
    fail_if(review.get("review_manifest_sha256") == sha256_file(evidence / "manifest_native_context_md5_postreview_full_log_scan.json"), "Post-review manifest hash binding failed", failures)
    fail_if(review.get("at_run_runner_sha256") == next((row.get("sha256") for row in at_run_manifest.get("scripts", []) if Path(row.get("path", "")).name == "run_d4_formal_metadata_compat.py"), None), "At-run checker script hash is not bound to its manifest", failures)
    fail_if(review.get("console_log_sha256") == sha256_file(evidence / "console.log"), "Post-review console hash binding failed", failures)
    fail_if(run_summary.get("log_sha256") == sha256_file(evidence / "console.log"), "Original run summary console hash binding failed", failures)
    for name, digest in review.get("report_hashes", {}).items():
        path = evidence / name
        fail_if(path.is_file() and sha256_file(path) == digest, "Post-review report hash binding failed for {}".format(name), failures)
        fail_if(path.is_file(), "Post-review report is missing: {}".format(name), failures)

    # Native final proof is parsed directly from completed logs, never from a progress token.
    console = (evidence / "console.log").read_text(encoding="utf-8", errors="replace")
    matched = re.findall(r"\b(\d+) Compare points matched by name\b", console)
    passing = re.findall(r"\b(\d+) Passing compare points\b", console)
    zero_failing = ZERO_FAIL_RE.search(console) is not None
    fail_if(re.search(r"^Verification SUCCEEDED\s*$", console, re.MULTILINE) is not None, "Native final status is not Verification SUCCEEDED", failures)
    fail_if(bool(matched) and int(matched[-1]) == 13758, "Native console does not show all 13758 points matched", failures)
    fail_if(bool(passing) and int(passing[-1]) == 13758, "Native console does not show all 13758 points passing", failures)
    fail_if(zero_failing, "Native console lacks the zero-failing final summary row", failures)
    fail_if("No unmatched points." in (evidence / "unmatched.rpt").read_text(encoding="utf-8", errors="replace"), "unmatched.rpt does not state no unmatched points", failures)

    scanned = []
    error_lines = []
    for name in ("console.log", "formality.log", "fm_shell_command.log"):
        scanned.append(name)
        content = (evidence / name).read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(content.splitlines(), 1):
            if ERROR_RE.match(line):
                error_lines.append({"log": name, "line_number": number, "text": line.strip()})
    fail_if(not error_lines, "Native logs contain Error: lines: {}".format(error_lines), failures)
    fail_if(review.get("native_error_log_files_scanned") == scanned, "Post-review record does not list all three native logs", failures)
    fail_if(not review.get("native_errors"), "Post-review record contains native Error lines", failures)

    guidance = parse_guidance(console)
    for name, expected in KEY_GUIDANCE_BASELINE.items():
        row = guidance.get(name)
        actual = None if row is None else (row["accepted"], row["rejected"], row["total"])
        fail_if(actual == expected, "Guidance baseline mismatch for {}: {}".format(name, actual), failures)
        baseline_row = at_run_manifest.get("diagnosis", {}).get("prior_run_evidence", {}).get("native_triple_with_parser_error", {}).get("guidance_summary", {}).get(name)
        baseline_actual = None if baseline_row is None else (baseline_row["accepted"], baseline_row["rejected"], baseline_row["total"])
        fail_if(actual == baseline_actual, "Guidance row {} differs from the original native baseline {}".format(name, baseline_actual), failures)
    fail_if(derived_guidance.get("rows") == guidance, "Derived guidance report differs from native console", failures)
    fail_if(derived_points.get("counts", {}).get("verification_succeeded") is True, "Derived point report lacks success", failures)
    fail_if(derived_points.get("counts", {}).get("matched_compare_points") == 13758, "Derived point report matched count differs", failures)
    fail_if(derived_points.get("counts", {}).get("passing_compare_points") == 13758, "Derived point report passing count differs", failures)
    fail_if(derived_points.get("counts", {}).get("zero_failing_summary_row") is True, "Derived point report lacks zero-failing row", failures)
    fail_if(derived_points.get("counts", {}).get("no_unmatched_points_reported") is True, "Derived point report lacks unmatched result", failures)

    blackbox_ok, blackbox_details = verify_blackboxes((evidence / "black_boxes.rpt").read_text(encoding="utf-8", errors="replace"))
    fail_if(blackbox_ok, "Reference and implementation memory boundaries differ: {}".format(blackbox_details), failures)
    fail_if(review.get("memory_blackboxes", {}).get("instances_per_side") == {"i": 19, "r": 19}, "Post-review record lacks identical 19-memory instance totals", failures)

    source = review.get("source_binding", {}).get("sources", [{}])[0]
    native = review_manifest.get("native_svf", {})
    metadata = review_manifest.get("adapted_svf", {})
    source_binding = native.get("sources", [{}])[0]
    original_triples = native.get("original_triples", [])
    fail_if(review.get("source_binding", {}).get("fixed_synth_tag") == FIXED_SYNTH_TAG, "Fixed candidate tag mismatch", failures)
    fail_if(review.get("source_binding", {}).get("mapped_sha256") == FIXED_MAPPED_SHA256, "Fixed mapped candidate SHA256 mismatch", failures)
    fail_if(source.get("svf_md5") == FIXED_SOURCE_MD5 and source.get("actual_md5") == FIXED_SOURCE_MD5, "Source MD5 does not match SVF metadata and fixed expected value", failures)
    fail_if(source.get("actual_sha256") == source_binding.get("actual_sha256"), "Source SHA256 differs between review and manifest", failures)
    fail_if(source_binding.get("svf_md5") == source_binding.get("actual_md5") == FIXED_SOURCE_MD5, "Manifest source MD5 binding mismatch", failures)
    fail_if(bool(original_triples) and original_triples[0].get("source_md5") == FIXED_SOURCE_MD5, "Original SVF triple does not bind the fixed source MD5", failures)
    source_path = workspace_root / SOURCE_RELATIVE
    if not source_path.is_file():
        failures.append("Local source file is required to rehash the same-source binding: {}".format(source_path))
    else:
        source_md5 = hashlib.md5(source_path.read_bytes()).hexdigest()
        source_sha = sha256_file(source_path)
        fail_if(source_md5 == source_binding.get("actual_md5"), "Local fullnet source MD5 differs from the recorded source", failures)
        fail_if(source_sha == source_binding.get("actual_sha256"), "Local fullnet source SHA256 differs from the recorded source", failures)

    operative_native = native.get("operative_guidance_sha256_after_removing_file_info")
    operative_adapted = metadata.get("operative_guidance_sha256_after_removing_file_info")
    fail_if(metadata.get("only_file_info_metadata_changed") is True, "Manifest does not assert a metadata-only transformation", failures)
    fail_if(operative_native == operative_adapted == EXPECTED_OPERATIVE_SHA256, "Native/adapted operative guidance hashes do not match", failures)
    fail_if(review.get("metadata_only_transform", {}).get("operative_guidance_sha256") == operative_native, "Review operative-guidance hash is not bound to the manifest", failures)
    fail_if(run_summary.get("operative_guidance_sha256") == operative_native, "At-run summary operative-guidance hash differs", failures)
    fail_if(metadata.get("sha256") == review.get("metadata_only_transform", {}).get("adapted_svf_sha256_only"), "Adapted SVF metadata hash is not bound to the review", failures)
    fail_if(run_summary.get("adapted_svf_sha256") == metadata.get("sha256"), "At-run summary adapted-SVF hash differs", failures)
    fail_if(native.get("sha256") == review.get("metadata_only_transform", {}).get("native_svf_sha256"), "Native SVF metadata hash is not bound to the review", failures)
    fail_if(review_manifest.get("compatibility_mode") == "native-context metadata-only path+MD5 pair", "Unexpected compatibility mode", failures)
    fail_if(review.get("metadata_only_transform", {}).get("native_guide_info_file_commands") == 1, "Expected exactly one source file-info command", failures)

    context = review_manifest.get("native_relative_helper_context", {})
    fail_if(context.get("file_count") == 169, "Native helper inventory count differs from the recorded 169 files", failures)
    fail_if(context.get("inventory_sha256") == review.get("native_sidefile_context", {}).get("relative_helper_inventory_sha256"), "Native helper inventory hash binding failed", failures)
    fail_if(context.get("inventory_sha256") == run_summary.get("native_helper_inventory_sha256"), "Native helper inventory differs from the at-run summary", failures)
    fail_if(review.get("native_sidefile_context", {}).get("helper_base") == "d1/", "Native sidefile context does not identify d1/", failures)

    script_hashes = {Path(row.get("path", "")).name: row.get("sha256") for row in review_manifest.get("scripts", [])}
    for name in ("prepare_d4_svf_compat_probe.py", "run_d4_formal_metadata_compat.py"):
        fail_if(script_hashes.get(name) == sha256_file(evidence / name), "Post-review manifest does not bind packaged script {}".format(name), failures)
    fail_if(run_summary.get("formal_tcl_sha256") == script_hashes.get("asic_A3_formal.tcl"), "At-run Tcl hash does not match the post-review manifest", failures)

    run_contract = derived_contract.get("run_contract", {})
    fail_if("at most one" in run_contract.get("verify_budget", "") and "21600" in run_contract.get("verify_budget", ""), "Run contract does not preserve the single bounded verify budget", failures)
    fail_if("bare verify" in run_contract.get("verification_strategy", "") and "no explicit" in run_contract.get("verification_strategy", ""), "Run contract does not preserve the default verify strategy", failures)
    forbidden = run_contract.get("forbidden_changes", "").lower()
    fail_if("no candidate" in forbidden and "assumptions" in forbidden and "waivers" in forbidden, "Run contract does not prohibit assumptions/waivers or candidate changes", failures)
    fail_if("no candidate" in forbidden and "memory-boundary changes" in forbidden, "Run contract does not preserve the fixed candidate and memory boundary", failures)

    point_counts = review.get("proof_point_counts", {})
    fail_if(point_counts.get("matched") == 13758 and point_counts.get("passing") == 13758 and point_counts.get("failing") == 0 and point_counts.get("unmatched") == 0, "Post-review point counts do not match direct log parsing", failures)
    fail_if(point_counts.get("unverified_counter_printed_by_formality") is False, "Post-review does not record the missing standalone unverified counter", failures)

    prior = derived_boundary.get("prior_runs", {})
    no_svf = prior.get("no_svf_negative", {})
    no_svf_lines = "\n".join(no_svf.get("terminal_summary_lines", []))
    fail_if("Verification FAILED" in no_svf_lines and "20 Failing compare points" in no_svf_lines and "13002 Unverified compare points" in no_svf_lines and "1009(0) Unmatched" in no_svf_lines, "Prior no-SVF negative evidence is incomplete", failures)
    crc = prior.get("standalone_crc_pair_without_native_sidefiles", {})
    fail_if(crc.get("last_progress") == {"pass": 13634, "unverified": 124}, "Prior CRCpair stall evidence is incomplete", failures)
    fail_if("not classify the 124 as harmless" in str(derived_boundary.get("prior_124_unverified_point_identities")), "CRCpair uncertainty note is missing", failures)
    parser_error = prior.get("native_triple_with_parser_error", {})
    fail_if(any("Parse error" in line for line in parser_error.get("native_error_lines", [])), "Original native triple parser-error evidence is missing", failures)

    # The SVF and mapped netlist are intentionally absent. Their recorded hashes bind
    # the run; operative-byte equality was validated by the remote adapter manifest.
    fail_if("Formality does not emit" in review.get("inference_limit", "") or "does not print a separate" in review.get("inference_limit", ""), "Unverified-count inference limit is not recorded", failures)
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--workspace-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    evidence = args.evidence_dir.resolve(strict=True)
    workspace = args.workspace_root.resolve(strict=True)
    failures = []
    validate_evidence(evidence, workspace, failures)
    archive_hash = None
    if args.archive is not None:
        archive_hash = verify_zip(evidence, args.archive.resolve(strict=True), failures)
    if failures:
        for message in failures:
            print("FAIL: {}".format(message), file=sys.stderr)
        print("D4_ASIC_FORMAL_COMPAT_ACCEPT=FAIL", file=sys.stderr)
        return 2
    print("D4_ASIC_FORMAL_COMPAT_ACCEPT=PASS")
    if archive_hash:
        print("D4_ASIC_FORMAL_COMPAT_ARCHIVE_SHA256={}".format(archive_hash))
    print("D4_ASIC_FORMAL_COMPAT_EVIDENCE={}".format(evidence))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
