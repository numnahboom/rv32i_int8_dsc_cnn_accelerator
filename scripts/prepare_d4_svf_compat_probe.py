#!/usr/bin/env python3
"""Prepare and validate an A3 native-context, metadata-only SVF adapter.

The adapter removes only the extra numeric member of each DC ``guide_info
-file`` triple, leaving the source path and MD5 pair. It keeps the SVF beside
the native ``d1/netlists`` helper tree so relative guidance references retain
their original context. It never edits RTL, the mapped netlist, the original
SVF, or any native helper file.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
FIXED_SYNTH_TAG = "asic_A3_sync_reset_tt_20261020"
FIXED_MAPPED_SHA256 = "12861917f2bdd9a45fdb5fe19585a69c6262b4520795eebe7972ac2eb236f898"
FIXED_SOURCE_MD5 = "43487b16ac9a042b43c87e9dca1a1c99"
DEFAULT_SVF = ROOT / "build/reports/asic_A3_sync_reset_formal_20261020/formality_svf/svf.txt"
DEFAULT_MAPPED = ROOT / "build/reports" / FIXED_SYNTH_TAG / "mapped.v"
DEFAULT_ADAPTED = DEFAULT_SVF.with_name("metadata_md5_pair.svf")
DEFAULT_MANIFEST = ROOT / "build/reports/asic_svf_compat_parser_20261020/manifest_native_context_md5.json"

FILE_INFO_TRIPLE_RE = re.compile(
    rb"(guide_info\s+\\\s+-file\s+\\\s+\{\s+\{\s+)"
    rb"([^\s{}]+)(\s+)(\d+)(\s+)([0-9a-fA-F]{32})(\s+\}\s+\})"
)
FILE_INFO_PAIR_RE = re.compile(
    rb"guide_info\s+\\\s+-file\s+\\\s+\{\s+\{\s+([^\s{}]+)\s+([0-9a-fA-F]{32})\s+\}\s+\}"
)
FILE_INFO_BLOCK_RE = re.compile(
    rb"guide_info\s+\\\s+-file\s+\\\s+\{\s+\{.*?\}\s+\}", re.DOTALL
)
NETLIST_GUIDANCE_RE = re.compile(
    rb"guide_(architecture|boundary)_netlist\s+\\\s+-file\s+\{\s*([^{}\s]+)\s*\}"
)
GUIDANCE_ROW_RE = re.compile(r"^\s*([a-z_]+)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")
VERIFY_PROGRESS_RE = re.compile(r"\b0F/0A/(\d+)P/(\d+)U\b")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path, algorithm="sha256"):
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _within(child, parent):
    try:
        child.resolve(strict=True).relative_to(parent.resolve(strict=True))
        return True
    except (OSError, ValueError):
        return False


def adapt_bytes(original):
    triples = list(FILE_INFO_TRIPLE_RE.finditer(original))
    if not triples:
        raise ValueError("No original DC guide_info -file triple found")
    if len(triples) != len(list(FILE_INFO_BLOCK_RE.finditer(original))):
        raise ValueError("Unrecognized guide_info -file block; refusing partial edit")

    adapted = bytearray()
    records = []
    cursor = 0
    for match in triples:
        path = match.group(2).decode("utf-8")
        scalar = match.group(4).decode("ascii")
        md5 = match.group(6).decode("ascii").lower()
        adapted.extend(original[cursor:match.start(3)])
        adapted.extend(b" ")
        adapted.extend(match.group(6))
        cursor = match.end(6)
        records.append({"source_path": path, "original_scalar": scalar, "source_md5": md5})
    adapted.extend(original[cursor:])
    adapted_bytes = bytes(adapted)

    if len(list(FILE_INFO_PAIR_RE.finditer(adapted_bytes))) != len(triples):
        raise ValueError("Adapted SVF is not exactly the expected path+MD5 pair form")
    original_blocks = list(FILE_INFO_BLOCK_RE.finditer(original))
    adapted_blocks = list(FILE_INFO_BLOCK_RE.finditer(adapted_bytes))
    if len(original_blocks) != len(adapted_blocks):
        raise ValueError("guide_info -file command count changed")
    operative_original = FILE_INFO_BLOCK_RE.sub(b"", original)
    operative_adapted = FILE_INFO_BLOCK_RE.sub(b"", adapted_bytes)
    if operative_original != operative_adapted:
        raise ValueError("Operative SVF bytes changed")
    return adapted_bytes, records, sha256(operative_original)


def _native_sidefile_inventory(svf, data):
    helper_root = svf.parent / "d1"
    if not helper_root.is_dir():
        raise ValueError(f"Missing native SVF sidefile root: {helper_root}")
    refs = list(NETLIST_GUIDANCE_RE.finditer(data))
    if not refs:
        raise ValueError("No architecture/boundary netlist helper references found")
    by_kind = {}
    reference_records = []
    for match in refs:
        kind = match.group(1).decode("ascii")
        relative = match.group(2).decode("utf-8")
        relpath = Path(relative)
        if relpath.is_absolute() or ".." in relpath.parts:
            raise ValueError(f"Unsafe native sidefile reference: {relative}")
        target = helper_root / relpath
        if not target.is_dir() or not _within(target, helper_root):
            raise ValueError(f"Unresolved native sidefile reference: d1/{relative}")
        file_count = sum(1 for p in target.rglob("*") if p.is_file())
        if file_count < 1:
            raise ValueError(f"Native sidefile reference contains no files: d1/{relative}")
        stats = by_kind.setdefault(kind, {"references": 0, "resolved_files": 0})
        stats["references"] += 1
        stats["resolved_files"] += file_count
        reference_records.append({"kind": kind, "path": relative, "file_count": file_count})

    files = sorted(p for p in helper_root.rglob("*") if p.is_file())
    records = []
    total_bytes = 0
    for path in files:
        if not _within(path, helper_root):
            raise ValueError(f"Native helper symlink escapes export tree: {path}")
        rel = path.relative_to(helper_root).as_posix()
        digest = file_hash(path)
        size = path.stat().st_size
        total_bytes += size
        records.append((rel, digest, size))
    inventory_digest = hashlib.sha256()
    for rel, digest, size in records:
        inventory_digest.update(f"{rel}\0{size}\0{digest}\n".encode("utf-8"))
    return {
        "root": str(helper_root),
        "file_count": len(records),
        "total_bytes": total_bytes,
        "inventory_sha256": inventory_digest.hexdigest(),
        "references": reference_records,
        "reference_groups": by_kind,
    }


def _saved_guidance_summary(log_path):
    if not log_path.is_file():
        return {}
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    starts = [i for i, line in enumerate(lines) if "Guidance Summary" in line]
    if not starts:
        return {}
    summary = {}
    for line in lines[starts[-1] + 1:]:
        match = GUIDANCE_ROW_RE.match(line)
        if match:
            name, accepted, rejected, unsupported, unprocessed, total = match.groups()
            summary[name] = {
                "accepted": int(accepted), "rejected": int(rejected),
                "unsupported": int(unsupported), "unprocessed": int(unprocessed),
                "total": int(total),
            }
        elif summary and (not line.strip() or line.startswith("Note:")):
            break
    return summary


def _prior_run_evidence():
    reports = ROOT / "build/reports"
    prior_runs = {
        "native_triple_with_parser_error": reports / "asic_A3_sync_reset_formal_20261020/console.log",
        "standalone_crc_pair_without_native_sidefiles": reports / "asic_A3_sync_reset_formal_compat_20261020/console.log",
        "no_svf_negative": reports / "asic_A3_sync_reset_formal_no_svf_20261020/console.log",
    }
    result = {}
    for label, path in prior_runs.items():
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        progress = list(VERIFY_PROGRESS_RE.finditer(text))
        errors = [line.strip() for line in text.splitlines() if re.match(r"^\s*Error\s*:", line, re.IGNORECASE)]
        terminal_patterns = (
            r"Verification\s+(?:SUCCEEDED|FAILED)",
            r"\d+\s+Compare points matched by name",
            r"\d+\s+Passing compare points",
            r"\d+\s+Failing compare points",
            r"\d+\s+Unverified compare points",
            r"\d+\(\d+\)\s+Unmatched reference\(implementation\) compare points",
            r"Failing \(not equivalent\)",
        )
        terminal_lines = [
            line.strip() for line in text.splitlines()
            if any(re.search(pattern, line, re.IGNORECASE) for pattern in terminal_patterns)
        ]
        report_names = (
            "unverified.rpt", "unverified_points.rpt", "aborted.rpt", "aborted_points.rpt",
            "failing.rpt", "failed_session",
        )
        point_reports_or_sessions = sorted(
            candidate.name for candidate in path.parent.iterdir()
            if any(candidate.name == name or candidate.name.startswith(name + ".") for name in report_names)
        )
        result[label] = {
            "console_log": str(path),
            "console_log_sha256": file_hash(path),
            "guidance_summary": _saved_guidance_summary(path),
            "last_progress": None if not progress else {"pass": int(progress[-1].group(1)), "unverified": int(progress[-1].group(2))},
            "terminal_summary_lines": terminal_lines[-16:],
            "native_error_lines": errors,
            "point_reports_or_sessions_present": point_reports_or_sessions,
        }
    return result


def build_manifest(svf, mapped, adapted, records, operative_sha256):
    svf = svf.resolve(strict=True)
    mapped = mapped.resolve(strict=True)
    root = ROOT.resolve(strict=True)
    if not _within(svf, root):
        raise ValueError(f"Source SVF must be inside repository root: {svf}")
    if not _within(mapped, root):
        raise ValueError(f"Mapped netlist must be inside repository root: {mapped}")
    if mapped.parent.name != FIXED_SYNTH_TAG or mapped.name != "mapped.v":
        raise ValueError(f"Candidate must be the fixed mapped.v under {FIXED_SYNTH_TAG}")
    mapped_sha = file_hash(mapped)
    if mapped_sha != FIXED_MAPPED_SHA256:
        raise ValueError("Fixed mapped.v SHA256 does not match the assigned candidate")
    original = svf.read_bytes()
    recomputed, verified_records, verified_operative_sha = adapt_bytes(original)
    if recomputed != adapted or verified_records != records or verified_operative_sha != operative_sha256:
        raise ValueError("In-memory adapter data is not reproducible from the original SVF")

    source_records = []
    for record in records:
        source_path = Path(record["source_path"]).resolve(strict=True)
        if not _within(source_path, root):
            raise ValueError(f"guide_info source path escapes repository root: {source_path}")
        md5 = file_hash(source_path, "md5")
        source_sha256 = file_hash(source_path)
        if md5 != record["source_md5"] or md5 != FIXED_SOURCE_MD5:
            raise ValueError(f"guide_info source MD5 mismatch: {source_path}")
        source_records.append({
            "path": str(source_path),
            "original_scalar": record["original_scalar"],
            "svf_md5": record["source_md5"],
            "actual_md5": md5,
            "actual_sha256": source_sha256,
        })
    if len(source_records) != 1:
        raise ValueError(f"Expected one fullnet source in file-info metadata, got {len(source_records)}")
    inventory = _native_sidefile_inventory(svf, original)
    script_records = []
    for script_name in (
        "prepare_d4_svf_compat_probe.py",
        "run_d4_formal_metadata_compat.py",
        "asic_A3_formal.tcl",
    ):
        script_path = ROOT / "scripts" / script_name
        if not script_path.is_file():
            raise ValueError(f"Missing compatibility/run-contract script: {script_path}")
        script_records.append({"path": str(script_path), "sha256": file_hash(script_path)})
    return {
        "schema_version": 1,
        "adapter": "prepare_d4_svf_compat_probe.py",
        "compatibility_mode": "native-context metadata-only path+MD5 pair",
        "fixed_candidate": {
            "synth_tag": FIXED_SYNTH_TAG,
            "mapped_netlist": str(mapped),
            "mapped_sha256": mapped_sha,
        },
        "scripts": script_records,
        "native_svf": {
            "path": str(svf),
            "sha256": sha256(original),
            "size": len(original),
            "operative_guidance_sha256_after_removing_file_info": operative_sha256,
            "guide_info_file_commands": len(records),
            "original_triples": records,
            "sources": source_records,
        },
        "adapted_svf": {
            "path": str(svf.with_name("metadata_md5_pair.svf")),
            "sha256": sha256(adapted),
            "size": len(adapted),
            "format": "source-path + source-MD5 pair",
            "operative_guidance_sha256_after_removing_file_info": operative_sha256,
            "only_file_info_metadata_changed": True,
        },
        "native_relative_helper_context": {
            "svf_parent": str(svf.parent),
            "helper_base": "d1/",
            **inventory,
        },
        "diagnosis": {
            "metadata_change": "reduce each DC guide_info -file triple to source-path + source-MD5 pair by removing only the middle numeric metadata field",
            "sidefile_context_change": "place the adapted ASCII SVF beside the native d1/netlists export tree so netlists/... references retain their native resolution context",
            "causal_limit": "the prior parser-only variant was outside the native sidefile tree; its zero accepted key netlist groups cannot isolate metadata-format effects from missing relative helpers",
            "prior_run_evidence": _prior_run_evidence(),
            "prior_124_unverified_point_identities": "not available: the saved CRCpair console has no point-list report or saved failure session; do not classify the 124 as harmless",
        },
        "run_contract": {
            "match_gate": "run match-only first; require no native Error lines and key guidance counts identical to the native baseline before any verification phase",
            "verify_budget": "at most one fresh verify phase, max 21600 seconds; no retry",
            "verification_strategy": "Tcl calls bare verify with no explicit strategy/effort switches; Formality documented default is incremental; synopsys_auto_setup remains true",
            "forbidden_changes": "no candidate, design assumptions, cutpoint waivers, constants, or memory-boundary changes",
            "success_criteria": "13758 compare points matched and passing, 0 failing/aborted/unverified, 0 unmatched points, no native Error lines, and the expected 19 identical memory black-box boundaries",
        },
        "scope": "metadata compatibility diagnostic; not an equivalence result",
    }


def validate_manifest(manifest_path):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or manifest.get("compatibility_mode") != "native-context metadata-only path+MD5 pair":
        raise ValueError("Unexpected compatibility manifest schema or mode")
    svf = Path(manifest["native_svf"]["path"]).resolve(strict=True)
    mapped = Path(manifest["fixed_candidate"]["mapped_netlist"]).resolve(strict=True)
    adapted_path = Path(manifest["adapted_svf"]["path"]).resolve(strict=True)
    if adapted_path.parent != svf.parent or adapted_path.name != "metadata_md5_pair.svf":
        raise ValueError("Adapted SVF must remain beside the native export's d1 sidefiles")
    original = svf.read_bytes()
    adapted = adapted_path.read_bytes()
    if sha256(original) != manifest["native_svf"]["sha256"]:
        raise ValueError("Original native SVF changed after adapter preparation")
    if sha256(adapted) != manifest["adapted_svf"]["sha256"]:
        raise ValueError("Adapted native-context SVF changed after adapter preparation")
    if file_hash(mapped) != manifest["fixed_candidate"]["mapped_sha256"] or file_hash(mapped) != FIXED_MAPPED_SHA256:
        raise ValueError("Fixed mapped.v changed after adapter preparation")
    for script in manifest.get("scripts", []):
        script_path = Path(script["path"]).resolve(strict=True)
        if file_hash(script_path) != script["sha256"]:
            raise ValueError(f"Compatibility/run-contract script changed: {script_path}")
    expected, records, operative_sha = adapt_bytes(original)
    if adapted != expected:
        raise ValueError("Adapted SVF is not reproducible from the original triple metadata")
    if operative_sha != manifest["native_svf"]["operative_guidance_sha256_after_removing_file_info"]:
        raise ValueError("Operative SVF guidance hash changed")
    if operative_sha != manifest["adapted_svf"]["operative_guidance_sha256_after_removing_file_info"]:
        raise ValueError("Adapted SVF operative guidance hash differs")
    current_sources = []
    for record in records:
        source = Path(record["source_path"]).resolve(strict=True)
        current_sources.append((str(source), file_hash(source, "md5"), file_hash(source)))
    recorded_sources = manifest["native_svf"]["sources"]
    if len(current_sources) != len(recorded_sources):
        raise ValueError("SVF source count changed")
    for (path, md5, source_sha), recorded in zip(current_sources, recorded_sources):
        if path != recorded["path"] or md5 != FIXED_SOURCE_MD5 or md5 != recorded["actual_md5"] or source_sha != recorded["actual_sha256"]:
            raise ValueError(f"guide_info source file changed: {path}")
    current_inventory = _native_sidefile_inventory(svf, original)
    recorded_inventory = manifest["native_relative_helper_context"]
    if current_inventory != {key: recorded_inventory[key] for key in current_inventory}:
        raise ValueError("Native SVF sidefile tree or relative references changed")
    return manifest


def prepare(svf, mapped, adapted_path, manifest_path):
    svf = svf.resolve(strict=True)
    mapped = mapped.resolve(strict=True)
    if adapted_path.resolve().parent != svf.parent:
        raise ValueError("Adapted SVF must be created in the original native export directory")
    if adapted_path.name != "metadata_md5_pair.svf":
        raise ValueError("Adapter output basename must be metadata_md5_pair.svf")
    original = svf.read_bytes()
    adapted, records, operative_sha = adapt_bytes(original)
    manifest = build_manifest(svf, mapped, adapted, records, operative_sha)
    if adapted_path.exists():
        if adapted_path.read_bytes() != adapted:
            raise FileExistsError(f"Refusing to overwrite different adapted SVF: {adapted_path}")
    else:
        adapted_path.write_bytes(adapted)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if manifest_path.exists():
        if manifest_path.read_bytes() != encoded:
            raise FileExistsError(f"Refusing to overwrite different manifest: {manifest_path}")
    else:
        manifest_path.write_bytes(encoded)
    verified = validate_manifest(manifest_path)
    return verified


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-svf", type=Path, default=DEFAULT_SVF)
    parser.add_argument("--mapped-netlist", type=Path, default=DEFAULT_MAPPED)
    parser.add_argument("--adapted-svf", type=Path, default=DEFAULT_ADAPTED)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--verify-only", action="store_true", help="validate existing adapter and manifest without writes")
    args = parser.parse_args(argv)
    try:
        if args.verify_only:
            manifest = validate_manifest(args.manifest)
        else:
            manifest = prepare(args.source_svf, args.mapped_netlist, args.adapted_svf, args.manifest)
        print("D4_SVF_NATIVE_METADATA_ADAPTER_VALID=1")
        print(f"D4_SVF_FILEINFO_COUNT={manifest['native_svf']['guide_info_file_commands']}")
        print(f"D4_SVF_OPERATIVE_SHA256={manifest['adapted_svf']['operative_guidance_sha256_after_removing_file_info']}")
        print(f"D4_SVF_ADAPTED_SHA256={manifest['adapted_svf']['sha256']}")
        print(f"D4_SVF_NATIVE_HELPER_FILES={manifest['native_relative_helper_context']['file_count']}")
        print(f"D4_SVF_MANIFEST={args.manifest.resolve()}")
        return 0
    except Exception as exc:  # validation failures must be visible to shell runners
        print(f"D4_SVF_NATIVE_METADATA_ADAPTER_FAIL={exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
