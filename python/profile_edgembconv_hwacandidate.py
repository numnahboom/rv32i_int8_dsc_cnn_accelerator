#!/usr/bin/env python3
"""Static, auditable profiles for the independent EdgeMBConv HW candidate.

This module intentionally contains only a frozen graph specification.  It does
not import the C0 or C1 model/training modules and never writes to their output
directories.  The graph is represented as semantic operators, then expanded
into per-operator and per-block ledgers.  This makes a dense 3x3 operation,
pointwise 1x1 operation, and depthwise 3x3 operation impossible to hide in a
single aggregate number.

Variants are the minimum pre-training ablation set agreed for the candidate:

* A: current EdgeMBConv-Hybrid (two fused blocks);
* B: replace only the 32x32 residual fused block with an MBConv;
* C: replace both fused blocks with MBConv (DW/PW-oriented candidate);
* D4: C with one 4x4 residual MBConv removed;
* D8: C with one 8x8 residual MBConv removed.

No width, precision, input, output, or semantic MAC is silently changed.  A's
semantic total is guarded against the already published 17,211,904-MAC
profile.  The generated manifest is suitable as a later training/export graph
lock, but it is not an accuracy, cycle, synthesis, or power result.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SCHEMA = "C10-HWQA-v1-edgembconv-hwacandidate-static-ablation"
DEFAULT_OUT_DIR = Path("build/edgembconv_hwacandidate")
DEFAULT_REPORT = Path("docs/reports/edgembconv_hwacandidate_static_ablation_20260902.md")
EXPECTED_A_SEMANTIC_MACS = 17_211_904
FUSED_ANOMALY_THRESHOLD = 0.25


@dataclass(frozen=True)
class OpSpec:
    block: str
    block_type: str
    local_name: str
    kind: str
    input_h: int
    input_w: int
    cin: int
    cout: int
    kernel: int
    stride: int = 1
    groups: int = 1
    activation: str = "linear"
    residual: bool = False

    @property
    def h(self) -> int:
        return (self.input_h + self.stride - 1) // self.stride

    @property
    def w(self) -> int:
        return (self.input_w + self.stride - 1) // self.stride

    @property
    def mac(self) -> int:
        return self.h * self.w * self.cout * (self.cin // self.groups) * self.kernel * self.kernel

    @property
    def weight_params(self) -> int:
        return self.cout * (self.cin // self.groups) * self.kernel * self.kernel

    @property
    def bias_params(self) -> int:
        return self.cout

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": f"{self.block}.{self.local_name}",
            "block": self.block,
            "block_type": self.block_type,
            "kind": self.kind,
            "input_h": self.input_h,
            "input_w": self.input_w,
            "h": self.h,
            "w": self.w,
            "cin": self.cin,
            "cout": self.cout,
            "kernel": self.kernel,
            "stride": self.stride,
            "groups": self.groups,
            "mac": self.mac,
            "weight_params": self.weight_params,
            "bias_params": self.bias_params,
            "parameter_count": self.weight_params + self.bias_params,
            "activation": self.activation,
            "residual": self.residual,
        }


@dataclass
class Graph:
    variant_id: str
    variant_name: str
    description: str
    ops: list[OpSpec] = field(default_factory=list)
    blocks: list[str] = field(default_factory=list)
    block_types: dict[str, str] = field(default_factory=dict)
    block_residual: dict[str, bool] = field(default_factory=dict)
    block_activation: dict[str, list[str]] = field(default_factory=dict)
    state_h: int = 32
    state_w: int = 32
    state_c: int = 3

    def _check_shape(self, h: int, w: int, cin: int) -> None:
        if (h, w, cin) != (self.state_h, self.state_w, self.state_c):
            raise ValueError(
                f"{self.variant_id}: graph shape mismatch, expected "
                f"{self.state_h}x{self.state_w}x{self.state_c}, got {h}x{w}x{cin}"
            )

    def _begin_block(self, name: str, block_type: str, residual: bool) -> None:
        if name in self.block_types:
            raise ValueError(f"duplicate block {name}")
        self.blocks.append(name)
        self.block_types[name] = block_type
        self.block_residual[name] = residual
        self.block_activation[name] = []

    def _append(self, spec: OpSpec) -> None:
        if spec.groups <= 0 or spec.cin % spec.groups or spec.cout % spec.groups:
            raise ValueError(f"invalid groups={spec.groups} for {spec.cin}->{spec.cout}")
        self.ops.append(spec)
        self.block_activation[spec.block].append(spec.activation)
        self.state_h, self.state_w, self.state_c = spec.h, spec.w, spec.cout

    def stem(self) -> None:
        name = "stem"
        self._begin_block(name, "stem", False)
        self._check_shape(32, 32, 3)
        self._append(OpSpec(name, "stem", "dense3x3", "dense3x3", 32, 32, 3, 16, 3, activation="relu6"))

    def fused(self, name: str, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
        self._begin_block(name, "fused_mbconv", residual)
        self._check_shape(self.state_h, self.state_w, cin)
        if residual and (stride != 1 or cin != cout):
            raise ValueError(f"invalid residual fused block {name}")
        ih, iw = self.state_h, self.state_w
        self._append(OpSpec(name, "fused_mbconv", "expand.dense3x3", "dense3x3", ih, iw, cin, hidden,
                            3, stride=stride, activation="relu6", residual=residual))
        self._append(OpSpec(name, "fused_mbconv", "project.1x1", "pw1x1", self.state_h, self.state_w,
                            hidden, cout, 1, activation="linear", residual=residual))

    def mb(self, name: str, cin: int, hidden: int, cout: int, stride: int, residual: bool) -> None:
        self._begin_block(name, "mbconv", residual)
        self._check_shape(self.state_h, self.state_w, cin)
        if residual and (stride != 1 or cin != cout):
            raise ValueError(f"invalid residual MBConv block {name}")
        ih, iw = self.state_h, self.state_w
        self._append(OpSpec(name, "mbconv", "expand.1x1", "pw1x1", ih, iw, cin, hidden,
                            1, activation="relu6", residual=residual))
        self._append(OpSpec(name, "mbconv", "spatial.dw3x3", "dw3x3", self.state_h, self.state_w,
                            hidden, hidden, 3, stride=stride, groups=hidden,
                            activation="relu6", residual=residual))
        self._append(OpSpec(name, "mbconv", "project.1x1", "pw1x1", self.state_h, self.state_w,
                            hidden, cout, 1, activation="linear", residual=residual))

    def head(self) -> None:
        name = "head"
        self._begin_block(name, "head", False)
        self._check_shape(self.state_h, self.state_w, self.state_c)
        self._append(OpSpec(name, "head", "project.1x1", "pw1x1", self.state_h, self.state_w,
                            self.state_c, 256, 1, activation="linear"))

    def classifier(self) -> None:
        # GAP is a reduction, not a MAC category in this ledger.  The FC is
        # retained as an explicit "other" MAC row so semantic totals reconcile.
        name = "classifier"
        self._begin_block(name, "classifier", False)
        if (self.state_c,) != (256,):
            raise ValueError(f"{self.variant_id}: head must produce 256 channels")
        self.state_h, self.state_w = 1, 1
        self._append(OpSpec(name, "classifier", "fc", "other", 1, 1, 256, 10, 1, activation="linear"))


def add_common_tail(graph: Graph, repeats_8: int = 3, repeats_4: int = 2) -> None:
    """Append the fixed MBConv body after the two early candidate choices."""
    graph.mb("mb16.1", 32, 64, 32, 1, True)
    graph.mb("mb16.2", 32, 64, 32, 1, True)
    graph.mb("mb8.down", 32, 64, 64, 2, False)
    for rep in range(repeats_8):
        graph.mb(f"mb8.{rep + 1}", 64, 128, 64, 1, True)
    graph.mb("mb4.down", 64, 128, 128, 2, False)
    for rep in range(repeats_4):
        graph.mb(f"mb4.{rep + 1}", 128, 256, 128, 1, True)
    graph.head()
    graph.classifier()


def build_graph(variant_id: str) -> Graph:
    metadata = {
        "A": (
            "A_current_edgembconv_hybrid",
            "Current EdgeMBConv-Hybrid: two early fused blocks, then fixed MBConv body.",
        ),
        "B": (
            "B_mb32_replaces_fused32",
            "Replace only the 32x32 residual fused block with MBConv; retain the 16x16 fused downsample.",
        ),
        "C": (
            "C_all_mbconv_early",
            "Replace both fused blocks with MBConv; only the 3x3 stem remains dense.",
        ),
        "D4": (
            "D4_C_minus_one_mb4",
            "C with one of the two 4x4 residual MBConv blocks removed.",
        ),
        "D8": (
            "D8_C_minus_one_mb8",
            "C with one of the three 8x8 residual MBConv blocks removed.",
        ),
    }
    if variant_id not in metadata:
        raise ValueError(f"unknown variant {variant_id}; choose {', '.join(metadata)}")
    variant_name, description = metadata[variant_id]
    graph = Graph(variant_id, variant_name, description)
    graph.stem()
    if variant_id == "A":
        graph.fused("fused32.residual", 16, 32, 16, 1, True)
        graph.fused("fused16.down", 16, 32, 32, 2, False)
    elif variant_id == "B":
        graph.mb("mb32.replacement_fused32", 16, 32, 16, 1, True)
        graph.fused("fused16.down", 16, 32, 32, 2, False)
    else:
        graph.mb("mb32.replacement_fused32", 16, 32, 16, 1, True)
        graph.mb("mb16.replacement_fused16_down", 16, 32, 32, 2, False)
    add_common_tail(graph, repeats_8=2 if variant_id == "D8" else 3,
                    repeats_4=1 if variant_id == "D4" else 2)
    return graph


def op_activation(op: OpSpec, input_tensor: bool = False) -> dict[str, Any]:
    if input_tensor:
        h, w, c = op.input_h, op.input_w, op.cin
    else:
        h, w, c = op.h, op.w, op.cout
    return {"h": h, "w": w, "channels": c, "elements": h * w * c, "bytes_int8": h * w * c}


def profile_graph(graph: Graph) -> dict[str, Any]:
    op_rows = [op.as_dict() for op in graph.ops]
    semantic_macs = sum(op.mac for op in graph.ops)
    conv_macs = sum(op.mac for op in graph.ops if op.kind != "other")
    weights = sum(op.weight_params for op in graph.ops)
    biases = sum(op.bias_params for op in graph.ops)
    params = weights + biases
    if semantic_macs <= 0 or params <= 0:
        raise ValueError(f"empty graph {graph.variant_id}")

    # Build block summaries while preserving the exact operator order.
    block_rows: list[dict[str, Any]] = []
    for block in graph.blocks:
        rows = [op for op in graph.ops if op.block == block]
        first, last = rows[0], rows[-1]
        tensors: list[dict[str, Any]] = [dict(op_activation(first, True))]
        for op in rows:
            tensors.append(dict(op_activation(op)))
        peak = max(tensors, key=lambda t: int(t["elements"]))
        by_kind = {kind: sum(op.mac for op in rows if op.kind == kind)
                   for kind in ("dense3x3", "pw1x1", "dw3x3", "other")}
        block_mac = sum(by_kind.values())
        block_params = sum(op.weight_params + op.bias_params for op in rows)
        fused = graph.block_types[block] == "fused_mbconv"
        fused_fraction = block_mac / semantic_macs
        block_rows.append({
            "name": block,
            "block_type": graph.block_types[block],
            "input_shape": {"h": first.input_h, "w": first.input_w, "channels": first.cin},
            "output_shape": {"h": last.h, "w": last.w, "channels": last.cout},
            "residual": graph.block_residual[block],
            "activation_sequence": graph.block_activation[block],
            "operators": [f"{op.block}.{op.local_name}" for op in rows],
            "mac_by_kind": by_kind,
            "mac": block_mac,
            "mac_share": block_mac / semantic_macs,
            "weight_params": sum(op.weight_params for op in rows),
            "bias_params": sum(op.bias_params for op in rows),
            "parameter_count": block_params,
            "parameter_share": block_params / params,
            "peak_activation": peak,
            "peak_activation_elements": int(peak["elements"]),
            "peak_activation_bytes_int8": int(peak["bytes_int8"]),
            "is_fused_mac_anomaly": bool(fused and fused_fraction >= FUSED_ANOMALY_THRESHOLD),
            "fused_mac_fraction": fused_fraction if fused else 0.0,
        })

    category_rows: list[dict[str, Any]] = []
    for kind in ("dense3x3", "pw1x1", "dw3x3", "other"):
        mac = sum(op.mac for op in graph.ops if op.kind == kind)
        category_rows.append({
            "kind": kind,
            "mac": mac,
            "semantic_mac_percent": 100.0 * mac / semantic_macs,
            "convolution_mac_percent": 100.0 * mac / conv_macs if conv_macs else 0.0,
        })
    dense_mac = next(row["mac"] for row in category_rows if row["kind"] == "dense3x3")
    pw_mac = next(row["mac"] for row in category_rows if row["kind"] == "pw1x1")
    dw_mac = next(row["mac"] for row in category_rows if row["kind"] == "dw3x3")
    dense_conv_fraction = dense_mac / conv_macs if conv_macs else 0.0
    dw_pw_fraction = (pw_mac + dw_mac) / semantic_macs
    if dense_conv_fraction >= 0.25:
        narrative_status = "MIXED_DENSE_COST_WEAKENS_DW_PW_NARRATIVE"
    elif dense_conv_fraction > 0.10:
        narrative_status = "MOSTLY_DW_PW_WITH_LIMITED_DENSE_OPERATOR"
    else:
        narrative_status = "CONSISTENT_WITH_DW_PW_ACCELERATOR"
    fused_blocks = [row for row in block_rows if row["block_type"] == "fused_mbconv"]
    anomaly_blocks = [row["name"] for row in block_rows if row["is_fused_mac_anomaly"]]
    stage_activations: list[dict[str, Any]] = [{
        "name": "input", "h": 32, "w": 32, "channels": 3, "elements": 32 * 32 * 3, "bytes_int8": 32 * 32 * 3,
    }]
    for row in block_rows:
        if row["name"] == "classifier":
            # GAP creates a 1x1x256 tensor consumed by FC; no MAC is assigned
            # to GAP and it must appear before, not after, the classifier.
            stage_activations.append({"name": "gap", "h": 1, "w": 1, "channels": 256, "elements": 256, "bytes_int8": 256})
        shape = row["output_shape"]
        elements = int(shape["h"]) * int(shape["w"]) * int(shape["channels"])
        stage_activations.append({"name": row["name"], **shape, "elements": elements, "bytes_int8": elements})
    arithmetic_checks = {
        "layer_mac_sum": sum(int(row["mac"]) for row in op_rows),
        "layer_mac_sum_matches_semantic": sum(int(row["mac"]) for row in op_rows) == semantic_macs,
        "all_layer_mac_formulas_match": all(
            int(row["mac"]) == int(row["h"]) * int(row["w"]) * int(row["cout"]) *
            (int(row["cin"]) // int(row["groups"])) * int(row["kernel"]) * int(row["kernel"])
            for row in op_rows
        ),
        "all_parameter_formulas_match": all(
            int(row["weight_params"]) == int(row["cout"]) * (int(row["cin"]) // int(row["groups"])) *
            int(row["kernel"]) * int(row["kernel"]) and
            int(row["bias_params"]) == int(row["cout"])
            for row in op_rows
        ),
        "block_mac_sum": sum(int(row["mac"]) for row in block_rows),
        "block_mac_sum_matches_semantic": sum(int(row["mac"]) for row in block_rows) == semantic_macs,
        "category_mac_sum": sum(int(row["mac"]) for row in category_rows),
        "category_mac_sum_matches_semantic": sum(int(row["mac"]) for row in category_rows) == semantic_macs,
        "block_parameter_sum": sum(int(row["parameter_count"]) for row in block_rows),
        "block_parameter_sum_matches_total": sum(int(row["parameter_count"]) for row in block_rows) == params,
        "category_partition": "dense3x3 + pw1x1 + dw3x3 + other = semantic_macs",
    }
    if not all(bool(value) for key, value in arithmetic_checks.items()
               if key.endswith("matches_semantic") or key.endswith("matches_total") or key.endswith("formulas_match")):
        raise AssertionError(f"arithmetic ledger failed for {graph.variant_id}: {arithmetic_checks}")
    return {
        "schema": SCHEMA,
        "variant_id": graph.variant_id,
        "variant_name": graph.variant_name,
        "description": graph.description,
        "fixed_input": {"dataset": "CIFAR-10", "shape": [32, 32, 3], "classes": 10},
        "operator_contract": {
            "allowed_primitives": ["dense3x3", "pw1x1", "dw3x3", "residual_add", "relu6", "gap", "fc"],
            "weight": "symmetric per-output-channel int8",
            "activation": "signed int8; ReLU6 output [0,127]; residual/linear [-128,127]",
            "accumulator": "int32 hardware contract; this static ledger uses exact integer arithmetic",
            "semantic_mac_definition": "one int8 multiply-accumulate per kernel/input/output product; no MAC reduction",
        },
        "layers": op_rows,
        "blocks": block_rows,
        "operator_mac_categories": category_rows,
        "application_narrative_audit": {
            "dense3x3_fraction_of_convolution_mac": dense_conv_fraction,
            "dw_pw_fraction_of_semantic_mac": dw_pw_fraction,
            "status": narrative_status,
            "interpretation": (
                "A's 32x32 fused block is a material dense cost and must not be described as DW/PW work."
                if graph.variant_id == "A" else
                "The candidate is predominantly PW/DW work; any remaining dense stem/fused downsample must remain explicitly accounted for."
            ),
        },
        "conv_mac": conv_macs,
        "other_mac": semantic_macs - conv_macs,
        "semantic_macs": semantic_macs,
        "binary_ops_at_2_ops_per_mac": 2 * semantic_macs,
        "weight_params": weights,
        "bias_params": biases,
        "parameter_count": params,
        "parameter_count_definition": "deployed kernel weights plus one folded bias per output channel; BN is folded and not double-counted",
        "residual_adds": sum(
            row["output_shape"]["h"] * row["output_shape"]["w"] * row["output_shape"]["channels"]
            for row in block_rows if row["residual"]
        ),
        "peak_activation_elements_internal": max(row["peak_activation_elements"] for row in block_rows),
        "peak_activation_bytes_int8_internal": max(row["peak_activation_bytes_int8"] for row in block_rows),
        "peak_activation_elements_stage_boundary": max(int(row["elements"]) for row in stage_activations),
        "peak_activation_bytes_int8_stage_boundary": max(int(row["bytes_int8"]) for row in stage_activations),
        "activation_shapes_stage_boundary": stage_activations,
        "fused_block_audit": {
            "threshold_fraction_of_total_semantic_mac": FUSED_ANOMALY_THRESHOLD,
            "fused_block_count": len(fused_blocks),
            "anomalous_blocks": anomaly_blocks,
            "status": "ANOMALY" if anomaly_blocks else "NO_SINGLE_FUSED_BLOCK_OVER_THRESHOLD",
        },
        "arithmetic_checks": arithmetic_checks,
        "hardware_mapping_audit": {
            "dense3x3": {
                "current_dw_pw_accelerator": "NO_DIRECT_MAPPING",
                "proposed_128mac_partial_k_path": "YES_WITH_DENSE_WINDOW_WEIGHT_FEED",
                "minimum_new_mechanism": "reuse dense128_os_8x16-style 128-MAC output-stationary tile, SAME-halo/window feeder, and dense weight layout; no new arithmetic precision",
            },
            "pw1x1": {
                "current_dw_pw_accelerator": "YES",
                "proposed_128mac_partial_k_path": "YES_DIRECTLY",
                "minimum_new_mechanism": "map Cin tokens to tagged partial-K groups; retain existing PW weight lookup/requant and scratch-bank ownership",
            },
            "dw3x3": {
                "current_dw_pw_accelerator": "YES",
                "proposed_128mac_partial_k_path": "YES_AS_DW_PRODUCER",
                "minimum_new_mechanism": "reuse retained DW tile/window engine and its halo/commit fence; no dense primitive required",
            },
            "residual_add": {
                "current_dw_pw_accelerator": "PARTIAL",
                "proposed_128mac_partial_k_path": "PARTIAL",
                "minimum_new_mechanism": "same-scale int8 residual add plus explicit output-scale/requant alignment at block boundary",
            },
            "gap_fc": {
                "current_dw_pw_accelerator": "GAP_EXISTING; FC_SERIAL_OR_SMALL_PW",
                "proposed_128mac_partial_k_path": "FC_SMALL_TAIL",
                "minimum_new_mechanism": "reuse existing GAP/FC control; no candidate-specific MAC block",
            },
        },
        "profile_status": "PASS",
    }


BASELINE_ANCHORS = [
    {
        "id": "C0",
        "name": "EdgeDSCNet-C10 control",
        "semantic_macs": 5_136_896,
        "reported_params": 72_010,
        "parameter_note": "C0 report: 70,880 weights + 1,130 biases",
        "accuracy_status": "formal baseline; 70.05% FP32 is not an architecture upper bound",
    },
    {
        "id": "C1",
        "name": "CIFAR ResNet-20 quality anchor",
        "semantic_macs": 40_813_184,
        "reported_params": 270_896,
        "parameter_note": "C1 profile's published params field is kernel-weight count (biases are not included)",
        "accuracy_status": "quality anchor; not a replacement decision",
    },
]


def pct(value: float) -> str:
    return f"{100.0 * value:.2f}%"


def fmt_int(value: int) -> str:
    return f"{value:,}"


def generate_report(manifest: dict[str, Any]) -> str:
    profiles = manifest["variants"]
    lines = [
        "# EdgeMBConv hardware-aware candidate: static ablation ledger",
        "",
        "Date: 2026-09-02  ",
        f"Schema: `{SCHEMA}`  ",
        "",
        "This report freezes a candidate workload for later training, export, cycle modeling, and RTL integration. It does not claim accuracy, cycle, synthesis, route, power, or energy results. The existing C0 artifacts and paths are untouched and remain the formal baseline.",
        "",
        "## Scope and locked principles",
        "",
        "- Fixed CIFAR-10 input: 32x32x3, 10 classes; no input or precision reduction.",
        "- MBConv (PW-DW-PW) is the body primitive. Residual adds and expansion are explicit.",
        "- Fused blocks are limited to the current candidate A; they are an ablation variable, not an assumed default.",
        "- No arbitrary width changes or dense 3x3 additions were introduced. D4/D8 only remove one already-defined residual block.",
        "- Every parameter count below means deployed kernel weights plus one folded bias per output channel. The supplied C1 anchor uses its existing weight-only convention; this mismatch is called out rather than hidden.",
        "",
        "## Minimum ablation set",
        "",
        "| Variant | Definition | Dense 3x3 policy | Primitive set | Training/accuracy status |",
        "| --- | --- | --- | --- | --- |",
        "| A | Current EdgeMBConv-Hybrid | stem + two fused blocks | dense3x3, PW, DW, residual | not run in this static slice |",
        "| B | A with 32x32 residual fused block replaced by MBConv | stem + one 16x16 fused block | same subset, fused count reduced | not run |",
        "| C | Both early fused blocks replaced by MBConv | stem only | DW/PW-oriented body | not run |",
        "| D4 | C minus one 4x4 residual MBConv | stem only | same as C | not run |",
        "| D8 | C minus one 8x8 residual MBConv | stem only | same as C | not run |",
        "",
        "## Operator ledger",
        "",
        "The three requested operator percentages are shown against both semantic MACs and convolution MACs. FC is reported as `other`, so the semantic percentages reconcile exactly rather than silently assigning FC to a convolution class.",
        "",
        "| Variant | Params (weights+bias) | Semantic MAC | Dense 3x3 | PW 1x1 | DW 3x3 | Other | Peak internal int8 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for p in profiles:
        by_kind = {r["kind"]: r for r in p["operator_mac_categories"]}
        lines.append(
            f"| {p['variant_id']} | {fmt_int(p['parameter_count'])} | {fmt_int(p['semantic_macs'])} | "
            f"{fmt_int(by_kind['dense3x3']['mac'])} ({pct(by_kind['dense3x3']['mac'] / p['semantic_macs'])}) | "
            f"{fmt_int(by_kind['pw1x1']['mac'])} ({pct(by_kind['pw1x1']['mac'] / p['semantic_macs'])}) | "
            f"{fmt_int(by_kind['dw3x3']['mac'])} ({pct(by_kind['dw3x3']['mac'] / p['semantic_macs'])}) | "
            f"{fmt_int(by_kind['other']['mac'])} ({pct(by_kind['other']['mac'] / p['semantic_macs'])}) | "
            f"{fmt_int(p['peak_activation_elements_internal'])} elems ({fmt_int(p['peak_activation_bytes_int8_internal'])} B) |"
        )
    lines += [
        "",
        "### DW/PW application-narrative audit",
        "",
        "| Variant | Dense 3x3 / convolution MAC | PW+DW / semantic MAC | Assessment |",
        "| --- | ---: | ---: | --- |",
    ]
    for p in profiles:
        audit = p["application_narrative_audit"]
        lines.append(
            f"| {p['variant_id']} | {pct(audit['dense3x3_fraction_of_convolution_mac'])} | "
            f"{pct(audit['dw_pw_fraction_of_semantic_mac'])} | {audit['status']} |"
        )
    lines += [
        "",
        "### Operator shares (semantic / convolution denominator)",
        "",
        "| Variant | Dense 3x3 | PW 1x1 | DW 3x3 | Other | Conv MAC total |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for p in profiles:
        by_kind = {r["kind"]: r for r in p["operator_mac_categories"]}
        lines.append(
            f"| {p['variant_id']} | {pct(by_kind['dense3x3']['mac'] / p['semantic_macs'])} / {pct(by_kind['dense3x3']['mac'] / p['conv_mac'])} | "
            f"{pct(by_kind['pw1x1']['mac'] / p['semantic_macs'])} / {pct(by_kind['pw1x1']['mac'] / p['conv_mac'])} | "
            f"{pct(by_kind['dw3x3']['mac'] / p['semantic_macs'])} / {pct(by_kind['dw3x3']['mac'] / p['conv_mac'])} | "
            f"{pct(by_kind['other']['mac'] / p['semantic_macs'])} / - | {fmt_int(p['conv_mac'])} |"
        )
    lines += ["", "## Block ledger", "", "Each row includes MAC and parameter shares over the variant's full semantic graph. A fused anomaly threshold is 25% of total semantic MACs.", ""]
    for p in profiles:
        lines += [f"### {p['variant_id']} — {p['variant_name']}", "", "| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |", "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
        for b in p["blocks"]:
            ins, outs = b["input_shape"], b["output_shape"]
            anomaly = " **FUSED-MAC-ANOMALY**" if b["is_fused_mac_anomaly"] else ""
            lines.append(
                f"| `{b['name']}` | {b['block_type']}{anomaly} | {ins['h']}x{ins['w']}x{ins['channels']} -> {outs['h']}x{outs['w']}x{outs['channels']} | "
                f"{fmt_int(b['mac'])} | {pct(b['mac_share'])} | {fmt_int(b['parameter_count'])} | {pct(b['parameter_share'])} | "
                f"{fmt_int(b['peak_activation_elements'])} elems | {'yes' if b['residual'] else 'no'} |"
            )
        audit = p["fused_block_audit"]
        if audit["status"] == "ANOMALY":
            lines += ["", f"Fused audit: **ANOMALY** — `{', '.join(audit['anomalous_blocks'])}` exceeds {100 * FUSED_ANOMALY_THRESHOLD:.0f}% of semantic MACs.", ""]
        else:
            lines += ["", "Fused audit: no single fused block exceeds the 25% semantic-MAC threshold.", ""]
    lines += [
        "## Baseline comparison anchors",
        "",
        "These are comparison anchors only. No accuracy/cycle/synthesis evidence is inferred for any candidate from this static ledger.",
        "",
        "| ID | Architecture | Reported semantic MAC | Reported params | Candidate A MAC delta | Candidate A param delta | Note |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    a = profiles[0]
    for base in BASELINE_ANCHORS:
        lines.append(
            f"| {base['id']} | {base['name']} | {fmt_int(base['semantic_macs'])} | {fmt_int(base['reported_params'])} | "
            f"{a['semantic_macs'] - base['semantic_macs']:+,} ({pct((a['semantic_macs'] - base['semantic_macs']) / base['semantic_macs'])}) | "
            f"{a['parameter_count'] - base['reported_params']:+,} ({pct((a['parameter_count'] - base['reported_params']) / base['reported_params'])}) | {base['parameter_note']} |"
        )
    lines += [
        "",
        "C0's published 70.05% FP32 result is retained as formal baseline evidence, not treated as its architecture ceiling; its training protocol lacked augmentation, BN, and a scheduler. C1 ResNet-20 remains a quality anchor, not an automatic replacement target.",
        "",
        "## Hardware mapping audit",
        "",
        "- PW 1x1 maps directly to the existing DW/PW accelerator and tagged partial-K/scratch-bank path.",
        "- DW 3x3 maps to the existing retained DW window/tile producer and commit fence.",
        "- Dense 3x3 does not map directly to the DW/PW path. The minimum candidate mechanism is the separately-prototyped 128-MAC output-stationary tile plus a SAME-halo/window feeder and dense weight layout. A's stem and fused blocks therefore must be counted explicitly; they cannot be called DW/PW work.",
        "- Residual adds require scale alignment and a block-boundary add, but no new multiply primitive.",
        "- GAP/FC remain a small tail and are not hidden in the three convolution categories.",
        "",
        "## Decision boundary",
        "",
        "This evidence only locks the candidates and their arithmetic. The next gate is to train A/B/C/D4/D8 under the same fixed protocol, evaluate FP32 and deployment INT8 on the full test set, and then run a real cycle model before selecting any graph for RTL integration. No candidate is declared better than C0 here.",
        "",
        "## Generated artifacts",
        "",
        f"- Manifest: `build/edgembconv_hwacandidate/edgembconv_hwacandidate_manifest.json`",
        f"- Per-variant profiles: `build/edgembconv_hwacandidate/profile_<variant>.json`",
        f"- Generator: `python/profile_edgembconv_hwacandidate.py`",
        "",
    ]
    return "\n".join(lines)


def build_manifest() -> dict[str, Any]:
    profiles = []
    for variant_id in ("A", "B", "C", "D4", "D8"):
        profile = profile_graph(build_graph(variant_id))
        if variant_id == "A":
            profile["expected_semantic_macs"] = EXPECTED_A_SEMANTIC_MACS
            profile["semantic_mac_match"] = profile["semantic_macs"] == EXPECTED_A_SEMANTIC_MACS
            if not profile["semantic_mac_match"]:
                raise AssertionError(
                    f"A semantic MAC mismatch: {profile['semantic_macs']} != {EXPECTED_A_SEMANTIC_MACS}"
                )
        profiles.append(profile)
    anchor_a = profiles[0]
    for profile in profiles:
        profile["delta_vs_A"] = {
            "semantic_macs": profile["semantic_macs"] - anchor_a["semantic_macs"],
            "semantic_macs_percent": (profile["semantic_macs"] - anchor_a["semantic_macs"]) / anchor_a["semantic_macs"],
            "parameter_count": profile["parameter_count"] - anchor_a["parameter_count"],
            "parameter_count_percent": (profile["parameter_count"] - anchor_a["parameter_count"]) / anchor_a["parameter_count"],
        }
    return {
        "schema": SCHEMA,
        "fixed_task": {
            "dataset": "CIFAR-10",
            "input_shape": [32, 32, 3],
            "classes": 10,
            "quality_policy": "accuracy may not be assumed from static cost; full FP32 and INT8 test10k evaluation required",
            "c0_policy": "C0 retained as formal baseline and its artifacts/paths are not modified by this candidate",
        },
        "variants": profiles,
        "baseline_anchors": BASELINE_ANCHORS,
        "ablation_policy": {
            "minimum_set": ["A", "B", "C", "D4", "D8"],
            "primitive_consistency": "all variants use only dense3x3, PW1x1, DW3x3, residual, ReLU6, GAP, FC; D4/D8 only remove one existing MBConv block",
            "forbidden_shortcuts": ["input reduction", "precision reduction", "MAC accounting reduction", "unreported dense3x3 addition", "C0 overwrite"],
        },
        "evidence_boundary": {
            "accuracy": "UNVERIFIED",
            "cycles": "UNVERIFIED",
            "synthesis_post_route": "UNVERIFIED",
            "power": "UNVERIFIED",
            "energy_efficiency": "UNVERIFIED",
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    manifest = build_manifest()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "edgembconv_hwacandidate_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    for profile in manifest["variants"]:
        (args.out_dir / f"profile_{profile['variant_id']}.json").write_text(
            json.dumps(profile, indent=2) + "\n", encoding="utf-8"
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(generate_report(manifest), encoding="utf-8")
    print(json.dumps({
        "schema": SCHEMA,
        "out_dir": str(args.out_dir),
        "report": str(args.report),
        "variants": [
            {
                "id": p["variant_id"],
                "semantic_macs": p["semantic_macs"],
                "parameter_count": p["parameter_count"],
                "dense3x3_mac": next(r["mac"] for r in p["operator_mac_categories"] if r["kind"] == "dense3x3"),
                "pw1x1_mac": next(r["mac"] for r in p["operator_mac_categories"] if r["kind"] == "pw1x1"),
                "dw3x3_mac": next(r["mac"] for r in p["operator_mac_categories"] if r["kind"] == "dw3x3"),
                "fused_audit": p["fused_block_audit"],
            }
            for p in manifest["variants"]
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
