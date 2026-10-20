#!/usr/bin/env python3
"""Prepare the A2 native-context, metadata-only SVF compatibility input."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SYNTH_TAG = "asic_A2_sync_reset_tt_20261020"
RUN_TAG = "asic_A2_sync_reset_formal_20261020"
MAPPED_SHA256 = "7a42e9c61090181cee0c8212e0cf65f83693f1bdfb1027948b108290dbd5c0bd"
DEFAULT_SVF_SHA256 = "0a71b7a8b5503d562191f8de54b4ae05188b55d1b7a3ee1a6ddb4b800dea3fe1"
RESET_POLICY = "hdlin_ff_always_sync_set_reset=1\n"
RESET_POLICY_SHA256 = "c89f6442b6e0e0c6d30f62eba276001e5c18c5b8241e871a72ded07460bd42e0"
AREA_UM2 = 9147690.068825
FULLNET_SOURCE = "build/asic_eval/native_asymmetric_logic_rom_mask_weights/d4_fullnet_eval.sv"
EXPECTED_INPUTS = {
    "build/reports/asic_A2_sync_reset_tt_20261020/mapped.v": MAPPED_SHA256,
    "build/reports/asic_A2_sync_reset_tt_20261020/default.svf": DEFAULT_SVF_SHA256,
    "build/reports/asic_A2_sync_reset_tt_20261020/reset_policy.txt": RESET_POLICY_SHA256,
    "build/reports/asic_A2_sync_reset_tt_20261020/executed_script.tcl": "f01e4a48874f9a9d3930c364f6151001b2075ef7520565a75be928cb1db6c002",
    "build/reports/asic_A2_sync_reset_tt_20261020/executed_sources.sha256": "aba2eda594f1c8ab85e226ca8fcb29beee781b0e05647106eacf41bc8128a538",
    FULLNET_SOURCE: "ee0f42c227d42f960de8ce8b284f4da06839aac250cfcc05cb3e2156b85bd9b4",
    "rtl/asic/d4_rq_native_multiplier_lane.sv": "4b1076d0951b636519c1eea7abe666759962b24712e6dd41026597f4717c745a",
    "rtl/asic/d4_feature_banks_asymmetric.sv": "15659ed164d74d1d31da49a1ead84d7dd5147ff340ec95ddafcf446e74cd463f",
    "rtl/asic/d4_smic180_sram.sv": "e2ac02672f09e6fa38dd684162caae438a09b40c65280f710e48fe91a0101de1",
    "rtl/asic/d4_weight_rom_banks.sv": "7e052fe9c89b13e9857115e97a4c49600ee017ad0d5782f826576c18558d127a",
    "build/asic_macros/act_2048x128/RASP2048X16M16_typical.db": "e8075d731c9d624f702414eccc6fa204040745295582e0f1a33c826136ff6818",
    "build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_typical.db": "882c03ae1419f2ac2d4568827a5b0415877651e446ad38f5a8d277028bd35348",
    **{
        "build/asic_macros/weights/D4WROM{0}/D4WROM{0}_typical.db".format(index): digest
        for index, digest in enumerate((
            "87c880c89ea04e75c1f3e60eab356d54ae217c4bc9bea89b9f21e3a0d6f39255",
            "dc683ebe067e79b81de6a2f750905ec9f169f823f4d02e08b693ef7bca23c215",
            "74b4c5c476c2a99be5c086190b61060025874cb0c0556e2f272cad8d47b002c9",
            "7dbf69ef16904ee364c998edc9f9db7ae3e947cc5a43bb10674380b589354dd5",
            "399d0999f27d04d3933931eeb22c03f4760a654367f57d8a991fde98110125ee",
            "1b863dc2f8b8fa43d56ae823c6d20bd619abb1e7cfc14d5c6a673a8b8fe789df",
            "1b012ab30e82cdd5f66bf9da4aadca234ef6927f08f76cf3c0167c91b9e5e6f9",
            "84eff9c0a0448d32c67ed16b11d44ec7a2fccd4adc59fc255058880b10719877",
        ))
    },
    "/opt/pdk/smic0.18um/DigitalIC/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db": "36913fdb1ecdf181c1e0c33bf4e5f27db5ae0a237f289df4dc3b2b93b47d76f8",
}

FILE_INFO_TRIPLE_RE = re.compile(
    rb"(guide_info\s+\\\s+-file\s+\\\s+\{\s+\{\s+)"
    rb"([^\s{}]+)(\s+)(\d+)(\s+)([0-9a-fA-F]{32})(\s+\}\s+\})"
)
FILE_INFO_PAIR_RE = re.compile(
    rb"guide_info\s+\\\s+-file\s+\\\s+\{\s+\{\s+([^\s{}]+)\s+([0-9a-fA-F]{32})\s+\}\s+\}"
)
FILE_INFO_BLOCK_RE = re.compile(rb"guide_info\s+\\\s+-file\s+\\\s+\{\s+\{.*?\}\s+\}", re.DOTALL)
NETLIST_GUIDANCE_RE = re.compile(
    rb"guide_(architecture|boundary)_netlist\s+\\\s+-file\s+\{\s*([^{}\s]+)\s*\}"
)


def file_hash(path, algorithm="sha256"):
    digest = hashlib.new(algorithm)
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def within(child, parent):
    try:
        Path(child).resolve(strict=True).relative_to(Path(parent).resolve(strict=True))
        return True
    except (OSError, ValueError):
        return False


def adapt_bytes(original):
    triples = list(FILE_INFO_TRIPLE_RE.finditer(original))
    blocks = list(FILE_INFO_BLOCK_RE.finditer(original))
    if not triples or len(triples) != len(blocks):
        raise ValueError("Unrecognized or missing guide_info -file triple; refusing partial edit")
    output = bytearray()
    records = []
    cursor = 0
    for match in triples:
        output.extend(original[cursor:match.start(3)])
        output.extend(b" ")
        output.extend(match.group(6))
        cursor = match.end(6)
        records.append({
            "source_path": match.group(2).decode("utf-8"),
            "original_scalar": match.group(4).decode("ascii"),
            "source_md5": match.group(6).decode("ascii").lower(),
        })
    output.extend(original[cursor:])
    adapted = bytes(output)
    if len(list(FILE_INFO_PAIR_RE.finditer(adapted))) != len(triples):
        raise ValueError("Adapted SVF is not the expected source-path + MD5 pair form")
    if FILE_INFO_BLOCK_RE.sub(b"", original) != FILE_INFO_BLOCK_RE.sub(b"", adapted):
        raise ValueError("Operative SVF guidance changed during metadata adaptation")
    return adapted, records, sha256(FILE_INFO_BLOCK_RE.sub(b"", original))


def sidefile_inventory(svf_path, data):
    helper_root = Path(svf_path).parent / "d1"
    if not helper_root.is_dir():
        raise ValueError("Missing native SVF d1 sidefile context: {}".format(helper_root))
    references = []
    for match in NETLIST_GUIDANCE_RE.finditer(data):
        kind, relative = match.group(1).decode("ascii"), match.group(2).decode("utf-8")
        relpath = Path(relative)
        if relpath.is_absolute() or ".." in relpath.parts:
            raise ValueError("Unsafe native helper reference: {}".format(relative))
        target = helper_root / relpath
        if not target.is_dir() or not within(target, helper_root):
            raise ValueError("Unresolved native helper reference: d1/{}".format(relative))
        file_count = sum(1 for item in target.rglob("*") if item.is_file())
        if not file_count:
            raise ValueError("Native helper reference has no files: d1/{}".format(relative))
        references.append({"kind": kind, "path": relative, "file_count": file_count})
    if not references:
        raise ValueError("No architecture/boundary native helper references found")
    rows = []
    total_bytes = 0
    for path in sorted(item for item in helper_root.rglob("*") if item.is_file()):
        if not within(path, helper_root):
            raise ValueError("Native helper symlink escapes export tree: {}".format(path))
        relative = path.relative_to(helper_root).as_posix()
        size = path.stat().st_size
        digest = file_hash(path)
        total_bytes += size
        rows.append((relative, size, digest))
    inventory_hash = hashlib.sha256()
    for relative, size, digest in rows:
        inventory_hash.update("{}\0{}\0{}\n".format(relative, size, digest).encode("utf-8"))
    return {
        "root": str(helper_root.resolve()),
        "file_count": len(rows),
        "total_bytes": total_bytes,
        "inventory_sha256": inventory_hash.hexdigest(),
        "references": references,
    }


def candidate_inputs(root):
    records = []
    for relative, expected in EXPECTED_INPUTS.items():
        path = Path(relative) if Path(relative).is_absolute() else root / relative
        digest = file_hash(path)
        if digest != expected:
            raise ValueError("Fixed A2 input SHA256 mismatch: {}".format(path))
        key = relative if not Path(relative).is_absolute() else relative
        records.append({"key": key, "path": str(path.resolve()), "sha256": digest, "size": path.stat().st_size})
    reset_path = root / "build/reports" / SYNTH_TAG / "reset_policy.txt"
    if reset_path.read_text(encoding="ascii") != RESET_POLICY:
        raise ValueError("A2 reset policy text differs from the fixed sync-reset contract")
    result_path = root / "build/reports" / SYNTH_TAG / "result.json"
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if result.get("candidate") != "A2" or result.get("corner") != "tt" or result.get("cell_area_including_macros_um2") != AREA_UM2:
        raise ValueError("A2 result.json does not identify the assigned mapped candidate/area")
    return records, result


def build_manifest(root, svf_path, adapted_path, export_summary_path):
    root = Path(root).resolve(strict=True)
    mapped = root / "build/reports" / SYNTH_TAG / "mapped.v"
    inputs, result = candidate_inputs(root)
    svf_path = Path(svf_path).resolve(strict=True)
    if not within(svf_path, root):
        raise ValueError("Native exported SVF must be inside the project")
    original = svf_path.read_bytes()
    adapted, records, operative_hash = adapt_bytes(original)
    if len(records) != 1:
        raise ValueError("Expected one guide_info source for the fixed A2 full-network design")
    source = Path(records[0]["source_path"])
    if not source.is_absolute():
        source = root / source
    source = source.resolve(strict=True)
    if not within(source, root):
        raise ValueError("guide_info source escaped the fixed project root")
    source_md5 = file_hash(source, "md5")
    source_sha256 = file_hash(source)
    if source_md5 != records[0]["source_md5"]:
        raise ValueError("guide_info source MD5 does not match the actual RTL source")
    if source != (root / FULLNET_SOURCE).resolve(strict=True) or source_sha256 != EXPECTED_INPUTS[FULLNET_SOURCE]:
        raise ValueError("guide_info does not identify the fixed A2 full-network source")
    helper_context = sidefile_inventory(svf_path, original)
    export_summary_path = Path(export_summary_path).resolve(strict=True)
    export_summary = json.loads(export_summary_path.read_text(encoding="utf-8"))
    if export_summary.get("phase") != "export" or export_summary.get("result") != "NATIVE_EXPORT_READY":
        raise ValueError("Native export runner summary is missing or not accepted")
    adapted_path = Path(adapted_path)
    if adapted_path.resolve().parent != svf_path.parent or adapted_path.name != "metadata_md5_pair.svf":
        raise ValueError("Adapted SVF must stay in native formality_svf beside d1")
    if adapted_path.exists() and adapted_path.read_bytes() != adapted:
        raise FileExistsError("Refusing to overwrite a different adapted SVF")
    if not adapted_path.exists():
        adapted_path.write_bytes(adapted)
    script_names = (
        "asic_A2_formal.tcl", "prepare_d4_A2_svf_compat.py", "run_d4_asic_A2_sync_formal.py"
    )
    scripts = []
    for name in script_names:
        path = root / "scripts" / name
        if not path.is_file():
            raise ValueError("Missing A2 formal contract script: {}".format(path))
        scripts.append({"path": str(path), "sha256": file_hash(path)})
    return {
        "schema_version": 1,
        "candidate": "A2 sync-reset RTL-to-mapped equivalence",
        "compatibility_mode": "native-context metadata-only source-path + MD5 pair",
        "fixed_candidate": {
            "synth_tag": SYNTH_TAG,
            "formal_run_tag": RUN_TAG,
            "mapped_netlist": str(mapped.resolve()),
            "mapped_sha256": MAPPED_SHA256,
            "reset_policy": RESET_POLICY.strip(),
            "reset_policy_sha256": RESET_POLICY_SHA256,
            "cell_area_including_macros_um2": AREA_UM2,
            "result_json": result,
            "expected_rtl_output_bits": 252,
        },
        "inputs": inputs,
        "scripts": scripts,
        "native_export": {
            "text_svf_path": str(svf_path),
            "text_svf_sha256": sha256(original),
            "text_svf_size": len(original),
            "binary_default_svf_path": str(root / "build/reports" / SYNTH_TAG / "default.svf"),
            "binary_default_svf_sha256": DEFAULT_SVF_SHA256,
            "export_run_summary_path": str(export_summary_path),
            "export_run_summary_sha256": file_hash(export_summary_path),
            "guide_info_file_commands": len(records),
            "guide_info_records": [{
                **records[0], "actual_source_md5": source_md5,
                "actual_source_sha256": source_sha256, "actual_source_path": str(source),
            }],
            "operative_guidance_sha256": operative_hash,
            "native_sidefile_context": helper_context,
        },
        "adapted_svf": {
            "path": str(adapted_path.resolve()),
            "sha256": sha256(adapted),
            "size": len(adapted),
            "format": "source-path + source-MD5 pair",
            "operative_guidance_sha256": operative_hash,
            "only_file_info_metadata_changed": True,
        },
        "proof_contract": {
            "strategy": "synopsys_auto_setup true; bare verify with Formality default strategy",
            "design_assumptions": "none",
            "cutpoint_waivers": "none",
            "memory_scope": "11 identical macro black-box instances: 3 SRAM and 8 weight ROM",
            "success": "native Verification SUCCEEDED; dynamically reported matched and passing point counts agree; zero failing; no unmatched points; no native Error lines; all 252 top-level output bits remain compared",
            "verification_timeout_seconds": 7200,
        },
    }


def write_json_no_replace(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if path.exists() and path.read_bytes() != encoded:
        raise FileExistsError("Refusing to overwrite different manifest: {}".format(path))
    if not path.exists():
        path.write_bytes(encoded)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    base = ROOT / "build/reports" / RUN_TAG
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--source-svf", type=Path, default=base / "export/formality_svf/svf.txt")
    parser.add_argument("--adapted-svf", type=Path, default=base / "export/formality_svf/metadata_md5_pair.svf")
    parser.add_argument("--export-summary", type=Path, default=base / "export/run_summary.json")
    parser.add_argument("--manifest", type=Path, default=base / "manifest_native_context_md5.json")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.verify_only:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
            rebuilt = build_manifest(args.root, args.source_svf, args.adapted_svf, args.export_summary)
            if manifest != rebuilt:
                raise ValueError("Saved A2 manifest differs from current frozen input/metadata inventory")
            if file_hash(args.adapted_svf) != manifest["adapted_svf"]["sha256"]:
                raise ValueError("Adapted SVF hash changed")
        else:
            manifest = build_manifest(args.root, args.source_svf, args.adapted_svf, args.export_summary)
            write_json_no_replace(args.manifest, manifest)
        print("D4_A2_SVF_NATIVE_METADATA_ADAPTER_VALID=1")
        print("D4_A2_MAPPED_SHA256={}".format(manifest["fixed_candidate"]["mapped_sha256"]))
        print("D4_A2_SOURCE_MD5={}".format(manifest["native_export"]["guide_info_records"][0]["actual_source_md5"]))
        print("D4_A2_OPERATIVE_GUIDANCE_SHA256={}".format(manifest["adapted_svf"]["operative_guidance_sha256"]))
        print("D4_A2_NATIVE_HELPER_FILES={}".format(manifest["native_export"]["native_sidefile_context"]["file_count"]))
        print("D4_A2_MANIFEST={}".format(args.manifest.resolve()))
        return 0
    except Exception as exc:
        print("D4_A2_SVF_NATIVE_METADATA_ADAPTER_FAIL={}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
