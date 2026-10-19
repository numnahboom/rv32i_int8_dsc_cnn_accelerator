from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
PYTHON_DIR = ROOT / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import export_d4_fullnet_vectors as exporter
import export_eval_edgembconv_hwacandidate_a as ref_a
import export_eval_edgembconv_hwacandidate_d4 as ref_d4
from resnet20_hwqa import load_cifar10


DATA_ROOT = Path(r"D:\Stuff\data")


@pytest.fixture(scope="module")
def exported():
    tmp = ROOT / "build/reports/d4_fullnet_vectors_20261018/test_run"
    tmp.mkdir(parents=True, exist_ok=True)
    report = exporter.export_vectors(
        data_root=DATA_ROOT,
        out_root=tmp / "vectors",
        report_dir=tmp / "reports",
        sample_indices=[0],
    )
    return tmp, report


def test_frozen_graph_rom_mapping_and_descriptor_counts(exported):
    _, report = exported
    assert report["selected_indices"] == [0]
    assert set(report["artifact_dirs"]) == {"0"}
    ledger = report["ledger"]
    assert ledger["semantic_macs"] == 11_645_440
    assert ledger["dense3x3"] == 442_368
    assert ledger["pw1x1"] == 10_223_616
    assert ledger["dw3x3"] == 976_896
    assert ledger["op_count"] == 41
    assert ledger["add_count"] == 7
    assert ledger["conv_weight_values"] > 0
    assert ledger["fc_weight_values"] == 2560
    assert ledger["quant_groups"] == ledger["quant_words_per_bank"] - 1
    out = Path(report["artifact_dirs"]["0"])
    descriptors = (out / "descriptors.mem").read_text(encoding="ascii").splitlines()
    assert len(descriptors) == 41 * exporter.DESCRIPTOR_WORDS
    assert int(descriptors[0], 16) == exporter.OP_CONV
    descriptor_doc = json.loads((out / "descriptor.json").read_text(encoding="utf-8"))
    assert descriptor_doc["residual_lut"]["entry_order"] == "signed_int8_code_ascending_minus128_to_127"
    assert descriptor_doc["residual_lut"]["address_from_raw_activation_byte"] == "raw_byte_xor_0x80"


def test_every_tap_matches_existing_integer_reference_and_fc_acc_is_exact(exported):
    tmp, report = exported
    arrays, manifest, scales = exporter.load_frozen_deployment()
    images, labels = load_cifar10(DATA_ROOT, "test")
    index = 0
    direct_taps, _, gap, fc_acc, _ = exporter.run_reference_taps(arrays, manifest, scales, images[index])
    ops = exporter.build_operations(arrays, manifest, scales)
    out = Path(report["artifact_dirs"][str(index)])

    captured: dict[str, np.ndarray] = {}
    add_names = [op.name for op in ops if op.kind == exporter.OP_ADD]
    add_index = 0
    original_conv1 = ref_d4.conv1_q
    original_conv3 = ref_d4.conv3_q
    original_add = ref_d4.add_q
    original_check = ref_d4.check_acc
    fc_seen: dict[str, np.ndarray] = {}

    def capture_conv(original):
        def wrapped(*args, **kwargs):
            result = original(*args, **kwargs)
            label = kwargs.get("label", args[6])
            captured[str(label)] = np.asarray(result).copy()
            return result
        return wrapped

    def capture_add(*args, **kwargs):
        nonlocal add_index
        result = original_add(*args, **kwargs)
        captured[add_names[add_index]] = np.asarray(result).copy()
        add_index += 1
        return result

    def capture_fc(acc, label, stats):
        original_check(acc, label, stats)
        if label == "fc":
            fc_seen["fc"] = np.asarray(acc, dtype=np.int64).copy()

    ref_d4.conv1_q = capture_conv(original_conv1)
    ref_d4.conv3_q = capture_conv(original_conv3)
    ref_d4.add_q = capture_add
    ref_d4.check_acc = capture_fc
    try:
        prediction, _ = ref_d4.run_integer(arrays, scales, images[index : index + 1], labels[index : index + 1], 1)
    finally:
        ref_d4.conv1_q = original_conv1
        ref_d4.conv3_q = original_conv3
        ref_d4.add_q = original_add
        ref_d4.check_acc = original_check

    head = captured["head"]
    capture_gap = ref_a.round_away(head.astype(np.int64).sum(axis=(1, 2)) / 16.0).clip(-128, 127).astype(np.int8)
    captured["gap"] = capture_gap[0].reshape(1, 1, -1)
    expected_tap_lines = (out / "expected_taps.mem").read_text(encoding="ascii").splitlines()
    offsets = [int(x, 16) for x in (out / "tap_offsets.mem").read_text(encoding="ascii").splitlines()]
    assert len(offsets) == len(ops) == 41
    for i, op in enumerate(ops):
        if op.kind == exporter.OP_FC:
            assert offsets[i] == len(expected_tap_lines)
            continue
        got = captured[op.name]
        if op.relu:
            got = np.clip(got, 0, 127).astype(np.int8)
        assert np.array_equal(got[0] if got.ndim == 4 else got, direct_taps[op.name]), op.name
        words = expected_tap_lines[offsets[i] : offsets[i] + op.output_word_count]
        unpacked = exporter.unpack_activation_words(words, op.hout, op.wout, op.cout)
        assert np.array_equal(unpacked, direct_taps[op.name]), op.name

    assert add_index == 7
    assert np.array_equal(fc_seen["fc"].reshape(-1).astype(np.int32), fc_acc)
    assert np.array_equal(np.asarray([int(v, 16) for v in (out / "fc_acc.mem").read_text(encoding="ascii").splitlines()], dtype=np.uint32), fc_acc.astype(np.uint32))
    record = json.loads((out / "expected_fc.json").read_text(encoding="utf-8"))
    assert record["raw_int32_accumulators"] == [int(v) for v in fc_acc]
    logits = np.asarray(record["reconstructed_logits"], dtype=np.float64)
    fc_scales = np.asarray(
        next(row for row in manifest["layers"] if row.get("name") == "fc")["weight_scale"],
        dtype=np.float32,
    )
    head_scale = float(next(row for row in manifest["layers"] if row.get("name") == "head")["out_scale"])
    direct_manifest_logits = fc_acc.astype(np.float64) * (
        float(head_scale) * fc_scales.astype(np.float64)
    )
    assert np.array_equal(logits, direct_manifest_logits)
    assert record["dequant_scales_float64"] == [
        float(v) for v in float(head_scale) * fc_scales.astype(np.float64)
    ]
    assert np.argmax(logits) == int(prediction[0])
    assert record["argmax"] == int(prediction[0])
    assert np.array_equal(gap, direct_taps["gap"].reshape(-1))


def test_integer_requant_luts_and_gap_rounding(exported):
    _, report = exported
    out = Path(report["artifact_dirs"]["0"])
    summary = json.loads((out / "run_summary.json").read_text(encoding="utf-8"))
    assert summary["requant_audit"]["mismatches"] == 0
    assert summary["requant_audit"]["accumulator_values"] > 0
    arrays, manifest, scales = exporter.load_frozen_deployment()
    ops = exporter.build_operations(arrays, manifest, scales)
    exporter._build_roms(ops, arrays, manifest, scales)
    lut_words = (out / "residual_lut.mem").read_text(encoding="ascii").splitlines()
    codes = np.arange(-128, 128, dtype=np.int64)
    by_name = {row["name"]: row for row in manifest["layers"]}
    for op in (item for item in ops if item.kind == exporter.OP_ADD):
        prefix = op.name.removesuffix(".add")
        a, b = exporter.build_residual_lut(op.in_scale, float(by_name[prefix + ".project"]["out_scale"]), op.out_scale)
        actual_a = [exporter.decode_lanes(word, 32, 1, signed=True)[0] for word in lut_words[op.lut_a_base : op.lut_a_base + 256]]
        actual_b = [exporter.decode_lanes(word, 32, 1, signed=True)[0] for word in lut_words[op.lut_b_base : op.lut_b_base + 256]]
        assert actual_a == a
        assert actual_b == b
        expected_a = ref_a.round_away(codes * (op.in_scale / op.out_scale)).astype(np.int64).tolist()
        expected_b = ref_a.round_away(codes * (float(by_name[prefix + ".project"]["out_scale"]) / op.out_scale)).astype(np.int64).tolist()
        assert actual_a == expected_a
        assert actual_b == expected_b
        assert min(actual_a + actual_b) >= -32768
        assert max(actual_a + actual_b) <= 32767

    ties = np.zeros((1, 4, 4, 4), dtype=np.int8)
    ties[0, 0, 0, 0] = -8
    ties[0, 0, 0, 1] = 8
    ties[0, 0, 0, 2] = -24
    ties[0, 0, 0, 3] = 24
    assert exporter.gap_round_away(ties).tolist() == [[-1, 1, -2, 2]]
    assert exporter.round_away_integer(np.asarray([-8, 8, -24, 24]), 16).tolist() == [-1, 1, -2, 2]


def test_activation_input_packing_and_first_per_class_selection(exported):
    _, report = exported
    out = Path(report["artifact_dirs"]["0"])
    images, labels = load_cifar10(DATA_ROOT, "test")
    input_words = (out / "input.mem").read_text(encoding="ascii").splitlines()
    decoded = exporter.unpack_activation_words(input_words, 32, 32, 3)
    expected = np.clip(images[0].astype(np.int16) - 128, -128, 127).astype(np.int8)
    assert np.array_equal(decoded, expected)
    selected = exporter.select_first_per_class(labels)
    assert len(selected) == 10
    assert len({int(labels[index]) for index in selected}) == 10
    assert all(index == int(np.flatnonzero(labels == labels[index])[0]) for index in selected)


def test_synthetic_edge_vectors_pack_provenance_and_share_roms(exported):
    tmp, real_report = exported
    real_sample_dir = Path(real_report["artifact_dirs"]["0"])
    real_mem_hashes = {
        path.name: exporter.sha256_file(path)
        for path in real_sample_dir.glob("*.mem")
    }
    out_root = tmp / "synthetic_vectors"
    synthetic_report = exporter.export_synthetic_edge_vectors(
        out_root=out_root,
        report_dir=tmp / "synthetic_reports",
        reference_sample_dir=real_sample_dir,
    )
    expected_names = {"centered_zero", "all_zero", "all_255", "checkerboard"}
    assert set(synthetic_report["synthetic_cases"]) == expected_names
    assert synthetic_report["official_dataset_indices"] is None
    assert synthetic_report["accuracy_labels"] is None
    assert "no official CIFAR-10 accuracy claim" in synthetic_report["evidence_boundary"]
    assert real_report["selected_indices"] == [0]
    assert set(real_report["artifact_dirs"]) == {"0"}

    yy, xx, cc = np.indices((32, 32, 3), dtype=np.int16)
    expected_codes = {
        "centered_zero": np.zeros((32, 32, 3), dtype=np.int8),
        "all_zero": np.full((32, 32, 3), -128, dtype=np.int8),
        "all_255": np.full((32, 32, 3), 127, dtype=np.int8),
        "checkerboard": np.where(((xx + yy + cc) & 1) == 0, -128, 127).astype(np.int8),
    }
    arrays, manifest, _ = exporter.load_frozen_deployment()
    fc_scales = exporter._float32_scales(manifest)
    head_scale = float(next(row for row in manifest["layers"] if row.get("name") == "head")["out_scale"])
    shared_artifacts = [
        "weights.mem", "bias.mem", "multiplier.mem", "shift.mem", "residual_lut.mem",
        "descriptors.mem", "descriptor.json", "tap_offsets.mem",
    ]

    for name in sorted(expected_names):
        case = synthetic_report["synthetic_cases"][name]
        out = Path(case["artifact_dir"])
        assert out == out_root / f"sample_synthetic_{name}"
        assert (out / "expected_taps.mem").is_file()
        assert len((out / "expected_taps.mem").read_text(encoding="ascii").splitlines()) == 24336
        fc_words = (out / "fc_acc.mem").read_text(encoding="ascii").splitlines()
        assert len(fc_words) == 10
        decoded = exporter.unpack_activation_words(
            (out / "input.mem").read_text(encoding="ascii").splitlines(), 32, 32, 3,
        )
        assert np.array_equal(decoded, expected_codes[name])

        summary = json.loads((out / "run_summary.json").read_text(encoding="utf-8"))
        record = json.loads((out / "expected_fc.json").read_text(encoding="utf-8"))
        provenance = case["input_provenance"]
        assert provenance["kind"] == "synthetic_uint8_image"
        assert provenance["name"] == name
        assert provenance["official_dataset"] is None
        assert provenance["official_dataset_index"] is None
        assert provenance["accuracy_label"] is None
        assert summary["sample_index"] is None and summary["label"] is None and summary["label_name"] is None
        assert summary["cifar_test_batch_sha256"] is None
        assert summary["input_provenance"] == provenance
        assert "no official CIFAR-10 accuracy label or accuracy claim" in summary["evidence_boundary"]
        assert record["sample_index"] is None and record["label"] is None and record["label_name"] is None
        assert record["input_provenance"] == provenance
        raw_acc = np.asarray(record["raw_int32_accumulators"], dtype=np.int32)
        mem_acc_words = [int(value, 16) for value in fc_words]
        mem_acc = np.asarray(
            [value if value < 0x80000000 else value - 0x100000000 for value in mem_acc_words],
            dtype=np.int32,
        )
        assert np.array_equal(raw_acc, mem_acc)
        expected_logits = raw_acc.astype(np.float64) * (
            float(head_scale) * fc_scales.astype(np.float64)
        )
        assert np.array_equal(np.asarray(record["reconstructed_logits"], dtype=np.float64), expected_logits)
        assert case["requant_audit"]["mismatches"] == 0
        assert case["requant_audit"]["accumulator_values"] > 0
        assert summary["accumulator_checks"] > 0

        hashes = json.loads((out / "artifact_sha256.json").read_text(encoding="utf-8"))
        for artifact, digest in hashes.items():
            assert exporter.sha256_file(out / artifact) == digest
        for artifact in shared_artifacts:
            assert exporter.sha256_file(out / artifact) == exporter.sha256_file(real_sample_dir / artifact)
            assert case["shared_artifact_sha256"][artifact] == exporter.sha256_file(real_sample_dir / artifact)

    assert {
        path.name: exporter.sha256_file(path)
        for path in real_sample_dir.glob("*.mem")
    } == real_mem_hashes
