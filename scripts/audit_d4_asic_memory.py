#!/usr/bin/env python3
"""Describe frozen D4 bank capacities and concurrent port separation."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sample = ROOT / "build/d4_fullnet_vectors/sample_0"
descriptor = sample / "descriptor.json"
operations = json.loads(descriptor.read_text())["operations"]
raw = [int(x, 16) for x in (sample / "descriptors.mem").read_text().split()]
peaks = [0, 0, 0]
peak_operations = ["", "", ""]
for op in operations:
    base = op["index"] * 32
    for field, offset in (("input_slot", 1), ("output_slot", 2), ("identity_slot", 3),
                          ("output_word_count", 20), ("input_word_count", 21)):
        if op[field] != raw[base + offset]:
            raise RuntimeError("Descriptor identity mismatch: " + field)
    for slot, count in ((op["input_slot"], op["input_word_count"]),
                        (op["output_slot"], op["output_word_count"])):
        if not 0 <= slot < 3 or not 0 <= count <= 2048:
            raise RuntimeError("Feature bank capacity exceeded")
        if count > peaks[slot]:
            peaks[slot], peak_operations[slot] = count, op["name"]
    if op["type"] == "CONV" and op["input_slot"] == op["output_slot"]:
        raise RuntimeError("Concurrent convolution read/write bank conflict")
    if op["type"] == "ADD" and op["input_slot"] == op["identity_slot"]:
        raise RuntimeError("Concurrent residual read bank conflict")
result = {"operations": len(operations), "logical_slot_peak_words": peaks,
          "peak_operations": peak_operations, "word_bits": 128,
          "physical_banks": 3, "words_per_bank": 2048,
          "capacity_bytes": 3*2048*128//8,
          "descriptor_sha256": hashlib.sha256(descriptor.read_bytes()).hexdigest(),
          "scope": "static descriptor capacity and bank separation; dynamic monitor remains required"}
out = ROOT / "build/reports/asic_memory_contract_20261020.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, sort_keys=True))
