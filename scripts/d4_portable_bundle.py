#!/usr/bin/env python3
"""Package/restore frozen D4 inputs and small FPGA evidence, never PDK files.

Python 3.6 compatible so a clean checkout can run on the lab server. Large
waveforms/checkpoints stay in the original workspace; their hashes remain in
the acceptance records. Restore refuses unsafe paths and different existing
files. All archive members are checked before any files are installed.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "artifacts/d4_p_portable.tar.gz"
REPORT_DIRS = [
    "d4_fullnet_fc_static_local_ce_20261018",
    "d4_fullnet_synth_fc_static_local_ce_20261018",
    "d4_fullnet_route_fc_static_local_ce_20261018",
    "d4_p_reset_memory_audit_20261019",
    "d4_p_activity_power_20261019_contract",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def create(archive):
    paths = set((ROOT / "build/d4_fullnet_vectors").glob("sample_*/*"))
    deploy = ROOT / "build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy"
    paths.update(deploy.glob("*"))
    for name in REPORT_DIRS:
        paths.update(p for p in (ROOT / "build/reports" / name).rglob("*")
                     if p.is_file() and p.stat().st_size < 300000
                     and p.suffix in (".json", ".txt", ".tsv", ".sv", ".v"))
    for name in ("d4_p_final_acceptance_20261019.json", "d4_fullnet_work_state.json"):
        paths.add(ROOT / "build/reports" / name)
    payloads = {p.relative_to(ROOT).as_posix(): p.read_bytes()
                for p in sorted(paths) if p.is_file()}
    if len(list((ROOT / "build/d4_fullnet_vectors").glob("sample_*/input.mem"))) != 14:
        raise RuntimeError("Expected all 14 accepted input vector directories")
    core_sha = digest((ROOT / "rtl/cnn/d4_fullnet_top.sv").read_bytes())
    if core_sha != "d438bc8855d2999307bed61b044c3b4fb716e5f17e53afbe5ba830bec323083e":
        raise RuntimeError("P core source identity changed")
    manifest = {"format": 1, "baseline_core_sha256": core_sha,
                "limits": "No large DCP/VCD/SAIF; historical FPGA evidence, not ASIC PPA",
                "files": {n: {"sha256": digest(b), "bytes": len(b)}
                          for n, b in payloads.items()}}
    payloads["bundle_manifest.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    archive.parent.mkdir(parents=True, exist_ok=True)
    with archive.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w") as tar:
            for name, data in sorted(payloads.items()):
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), 0o644, 0
                tar.addfile(info, io.BytesIO(data))
    index = {"archive": archive.name, "sha256": digest(archive.read_bytes()),
             "bytes": archive.stat().st_size, "files": len(manifest["files"]),
             "baseline_core_sha256": core_sha}
    archive.with_suffix(".json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(index, sort_keys=True))


def restore(archive, verify_only):
    index = json.loads(archive.with_suffix(".json").read_text(encoding="utf-8"))
    if digest(archive.read_bytes()) != index["sha256"]:
        raise RuntimeError("Archive SHA256 mismatch")
    with tarfile.open(str(archive), "r:gz") as tar:
        members = tar.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)):
            raise RuntimeError("Duplicate members")
        for member in members:
            name = PurePosixPath(member.name)
            if (not member.isfile() or name.is_absolute() or ".." in name.parts
                    or "\\" in member.name or ":" in member.name
                    or (member.name != "bundle_manifest.json" and name.parts[0] != "build")):
                raise RuntimeError("Unsafe member: " + member.name)
        manifest = json.load(tar.extractfile("bundle_manifest.json"))
        if set(names) != set(manifest["files"]) | {"bundle_manifest.json"}:
            raise RuntimeError("Member list differs from manifest")
        for name, item in manifest["files"].items():
            data = tar.extractfile(name).read()
            if len(data) != item["bytes"] or digest(data) != item["sha256"]:
                raise RuntimeError("Payload mismatch: " + name)
            target = ROOT / name
            if ROOT.resolve() not in target.resolve().parents:
                raise RuntimeError("Target escapes workspace: " + name)
            if target.exists() and digest(target.read_bytes()) != item["sha256"]:
                raise RuntimeError("Refusing to overwrite changed file: " + name)
        if not verify_only:
            for name in manifest["files"]:
                target = ROOT / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(name).read())
    print("D4_BUNDLE_PASS files={} action={}".format(len(manifest["files"]),
                                                   "verify" if verify_only else "restore"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "restore", "verify"))
    parser.add_argument("--archive", type=Path, default=DEFAULT)
    args = parser.parse_args()
    if args.action == "create":
        create(args.archive)
    else:
        restore(args.archive, args.action == "verify")
