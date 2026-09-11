#!/usr/bin/env python3
"""Traceable cycle and memory model for the frozen EdgeMBConv D4 candidate.

This is intentionally a *model*, not an RTL replacement.  The network graph
is read from the already validated D4 static profile and deployment manifest;
there is no second hand-written layer list here.  The model maps every dense
or pointwise operation to the isolated ``dense128_os_8x16`` contract: eight
pixels by sixteen output channels, one reduction token per cycle, and two
physical 8x8 slices (128 signed INT8 products per accepted token).  Depthwise
operations use the measured 4x8 DW command service and source-fill contract.

All quantities are emitted in a machine-readable schedule as well as a human
report.  Values marked ``validated_rtl`` come from existing probes; values
marked ``exact_formula`` are work/packing identities; values marked
``rtl_assumption`` are deliberately visible assumptions requiring a later
integrated RTL test.  In particular this model makes no full-network timing,
power, or energy claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROFILE = ROOT / "build" / "edgembconv_hwacandidate" / "profile_D4.json"
DEFAULT_MANIFEST = (
    ROOT
    / "build"
    / "edgembconv_hwacandidate_d4"
    / "edgembconv_hwacandidate_d4_deploy"
    / "edgembconv_hwacandidate_d4_deploy_manifest.json"
)
DEFAULT_QUALITY = (
    ROOT
    / "build"
    / "edgembconv_hwacandidate_d4"
    / "edgembconv_hwacandidate_d4_test10k.json"
)
DEFAULT_OUT = ROOT / "build" / "edgembconv_hwacandidate_d4_cycle_model"
DEFAULT_REPORT = ROOT / "docs" / "reports" / "edgembconv_hwacandidate_d4_cycle_model_20260902.md"

# Locked D4 profile values.  These are guards, not a second network
# description: layer shapes and counts still come only from profile_D4.json.
LOCKED_PROFILE = {
    "variant_id": "D4",
    "parameter_count": 204_090,
    "semantic_macs": 11_645_440,
    "dense3x3": 442_368,
    "pw1x1": 10_223_616,
    "dw3x3": 976_896,
}

# Existing XC7Z020/C0 comparison anchor.  This is historical measured
# full-top evidence and is never used to infer D4 hardware behavior.
C0_BASELINE = {
    "semantic_macs": 5_136_896,
    "cycles": 1_003_577,
    "int8_top1": 0.6616,
    "source": "docs/reports/fulltop_csa_baseline_20260828.md",
}

# ---------------------------------------------------------------------------
# Validated primitive constants
# ---------------------------------------------------------------------------

# dense128_os_8x16 / C1 stem trace: 128 tiles x 27 accepted tokens, first
# tile was 59 cycles, equal to K + 32 vector4 output commits.  The same 32
# commits apply to a full 8x16 physical tile.  An operation-level boundary
# startup/drain cycle is kept separately as a conservative integration
# assumption; it is not silently folded into the primitive measurement.
PW_PIXEL_TILE = 8
PW_COUT_TILE = 16
PW_PRODUCTS_PER_TOKEN = 128
PW_VECTOR4_BYTES = 4
PW_PHYSICAL_VECTOR4_WRITES = (PW_PIXEL_TILE * PW_COUT_TILE) // PW_VECTOR4_BYTES
PW_DENSE128_FIRST_TILE_K = 27
PW_DENSE128_FIRST_TILE_CYCLES = 59

# 4x8 depthwise probe (one 16-channel command group).  The command emits 288
# tap tokens, each token carrying 16 channel products, and 128 packed
# stream4 writes.  The measured command service already includes its issue
# and drain behavior.  Source fill is measured as words + 7 cycles.
DW_JOB_CYCLES = {1: 1_767, 2: 2_232}
DW_TOKENS_PER_COMMAND = 4 * 8 * 9
DW_CHANNELS_PER_TOKEN = 16
DW_STREAM4_WRITES_PER_COMMAND = 4 * 8 * 4
FILL_PIPELINE_OVERHEAD = 7
DW_CONFIG_CYCLES_PER_16CH_GROUP = 9

# Existing paired-scratch transfer contract: one 8-pixel vector is two
# 32-bit reads; each read costs three cycles in the measured response path,
# with a three-cycle row/fence turnaround.
SCRATCH_READ_CYCLES_PER_WORD = 3
SCRATCH_ROW_FENCE_CYCLES = 3
SCRATCH_8PIXEL_WORDS_PER_8CH_GROUP = 2

# Model-only control assumptions.  They are explicit in every output.
PIPELINE_BOUNDARY_STARTUP = 1
PIPELINE_BOUNDARY_DRAIN = 1
WEIGHT_CACHE_BYTES = 4 * 1024
WEIGHT_REFILL_BUS_BYTES_PER_CYCLE = 16  # one 16-Cout INT8 row
ACTIVATION_BUS_BYTES_PER_CYCLE = 8  # one 8-pixel INT8 vector
RESIDUAL_VECTOR_BYTES = 4
GAP_SCALAR_CYCLES_PER_INT8 = 1
FC_EXISTING_SCALAR_CYCLES_PER_MAC = 1


def ceil_div(a: int, b: int) -> int:
    if b <= 0:
        raise ValueError("ceil_div denominator must be positive")
    return (a + b - 1) // b


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def profile_guard(profile: dict[str, Any], manifest: dict[str, Any]) -> None:
    if profile.get("variant_id") != LOCKED_PROFILE["variant_id"]:
        raise RuntimeError("profile is not locked D4")
    for key in ("parameter_count", "semantic_macs"):
        if int(profile.get(key, -1)) != LOCKED_PROFILE[key]:
            raise RuntimeError(f"D4 profile guard failed for {key}")
    cats = {str(r["kind"]): int(r["mac"]) for r in profile.get("operator_mac_categories", [])}
    for kind, key in (("dense3x3", "dense3x3"), ("pw1x1", "pw1x1"), ("dw3x3", "dw3x3")):
        if cats.get(kind, -1) != LOCKED_PROFILE[key]:
            raise RuntimeError(f"D4 profile category guard failed for {kind}")
    mp = manifest.get("profile", {})
    for key in ("parameter_count", "semantic_macs", "dense3x3", "pw1x1", "dw3x3"):
        if int(mp.get(key, -1)) != LOCKED_PROFILE[key]:
            raise RuntimeError(f"D4 deployment manifest guard failed for {key}")
    if manifest.get("variant_id") != "D4":
        raise RuntimeError("deployment manifest is not D4")


@dataclass
class OpLedger:
    name: str
    block: str
    kind: str
    input_h: int
    input_w: int
    output_h: int
    output_w: int
    cin: int
    cout: int
    kernel: int
    stride: int
    semantic_macs: int
    parameter_count: int
    residual: bool
    pixel_count: int = 0
    pixel_tiles_8: int = 0
    cout_tiles_16: int = 0
    physical_tiles_8x16: int = 0
    physical_macs: int = 0
    masked_macs: int = 0
    issue_cycles: int = 0
    requant_vector4_writes: int = 0
    physical_vector4_commits: int = 0
    pipeline_startup_cycles: int = 0
    pipeline_drain_cycles: int = 0
    core_service_cycles: int = 0
    activation_word_reads: int = 0
    activation_read_cycles: int = 0
    source_activation_word_reads: int = 0
    source_window_word_reads: int = 0
    source_fill_cycles: int = 0
    activation_write_words: int = 0
    kernel_weight_words: int = 0
    bias_words: int = 0
    multiplier_words: int = 0
    shift_words: int = 0
    total_weight_words: int = 0
    weight_cache_refills: int = 0
    weight_refill_cycles: int = 0
    weight_tile_bytes: int = 0
    feed_cycles: int = 0
    selected_service_cycles: int = 0
    serial_service_cycles: int = 0
    dw_spatial_tiles_4x8: int = 0
    dw_commands: int = 0
    dw_tokens: int = 0
    dw_stream4_writes: int = 0
    dw_source_words_per_command: int = 0
    dw_config_cycles: int = 0
    dw_source_fill_work_cycles: int = 0
    dw_initial_fill_cycles: int = 0
    dw_compute_cycles: int = 0
    scratch_transfer_read_words: int = 0
    scratch_transfer_cycles: int = 0
    notes: list[str] = field(default_factory=list)
    source_class: str = "exact_formula"


@dataclass
class BlockLedger:
    name: str
    block_type: str
    input_shape: str
    output_shape: str
    residual: bool
    semantic_macs: int
    parameter_count: int
    mac_share: float
    parameter_share: float
    op_names: list[str]
    op_cycles_selected: int
    op_cycles_serial: int
    pw_cycles: int
    dw_cycles: int
    dw_pw_overlap_potential: int
    residual_scratch_read_words: int
    residual_read_cycles: int
    residual_add_cycles: int
    residual_service_cycles: int
    vector4_writeback_count: int
    pipeline_startup_cycles: int
    pipeline_drain_cycles: int
    boundary_fence_cycles: int
    selected_service_cycles: int
    serial_service_cycles: int
    notes: list[str] = field(default_factory=list)


def op_from_profile(row: dict[str, Any]) -> OpLedger:
    return OpLedger(
        name=str(row["name"]),
        block=str(row["block"]),
        kind=str(row["kind"]),
        input_h=int(row["input_h"]),
        input_w=int(row["input_w"]),
        output_h=int(row["h"]),
        output_w=int(row["w"]),
        cin=int(row["cin"]),
        cout=int(row["cout"]),
        kernel=int(row["kernel"]),
        stride=int(row["stride"]),
        semantic_macs=int(row["mac"]),
        parameter_count=int(row["parameter_count"]),
        residual=bool(row.get("residual", False)),
    )


def model_pw_or_dense(op: OpLedger) -> None:
    p = op.output_h * op.output_w
    pt = ceil_div(p, PW_PIXEL_TILE)
    mt = ceil_div(op.cout, PW_COUT_TILE)
    tiles = pt * mt
    op.pixel_count = p
    op.pixel_tiles_8 = pt
    op.cout_tiles_16 = mt
    op.physical_tiles_8x16 = tiles
    reduction_k = op.cin * (op.kernel * op.kernel if op.kind == "dense3x3" else 1)
    op.physical_macs = tiles * PW_PRODUCTS_PER_TOKEN * reduction_k
    op.masked_macs = op.physical_macs - op.semantic_macs
    op.issue_cycles = tiles * reduction_k
    op.requant_vector4_writes = ceil_div(p * op.cout, PW_VECTOR4_BYTES)
    op.physical_vector4_commits = tiles * PW_PHYSICAL_VECTOR4_WRITES
    op.pipeline_startup_cycles = PIPELINE_BOUNDARY_STARTUP
    # dense128 C1 measured K+32 per full tile; 32 commits are the drain.  A
    # separate boundary drain is charged only once for operation closure.
    op.pipeline_drain_cycles = PIPELINE_BOUNDARY_DRAIN
    op.core_service_cycles = op.issue_cycles + op.physical_vector4_commits + 1

    # One activation token is eight bytes (two packed 32-bit words); this is
    # repeated for each Cout tile because the engine is output stationary.
    op.activation_word_reads = tiles * reduction_k * 2
    op.activation_read_cycles = ceil_div(op.activation_word_reads, 2)
    op.activation_write_words = ceil_div(p * op.cout, 4)
    op.source_activation_word_reads = op.activation_word_reads

    kernel_params = op.cin * op.cout
    if op.kind == "dense3x3":
        kernel_params *= op.kernel * op.kernel
    op.kernel_weight_words = ceil_div(kernel_params, 4)
    op.bias_words = op.cout
    op.multiplier_words = op.cout
    op.shift_words = ceil_div(op.cout, 4)
    op.total_weight_words = op.kernel_weight_words + op.bias_words + op.multiplier_words + op.shift_words
    op.weight_cache_refills = mt
    op.weight_tile_bytes = op.cin * PW_COUT_TILE * (op.kernel * op.kernel if op.kind == "dense3x3" else 1)
    if op.weight_tile_bytes > WEIGHT_CACHE_BYTES:
        raise RuntimeError(f"D4 op {op.name} exceeds 4 KiB weight tile cache")
    op.weight_refill_cycles = ceil_div(kernel_params, WEIGHT_REFILL_BUS_BYTES_PER_CYCLE)

    if op.kind == "dense3x3":
        # The dense128 trace consumes an 8-pixel horizontal tile.  A SAME
        # feeder therefore gathers a 3x10 window for each 1x8 tile.  Padding
        # locations are retained in the physical footprint; no halo traffic
        # is silently set to zero.
        tile_h, tile_w = 1, PW_PIXEL_TILE
        fh = (tile_h - 1) * op.stride + op.kernel
        fw = (tile_w - 1) * op.stride + op.kernel
        words_per_window = ceil_div(fh * fw * op.cin, 4)
        spatial_tiles = ceil_div(op.output_h, tile_h) * ceil_div(op.output_w, tile_w)
        op.source_window_word_reads = spatial_tiles * words_per_window
        op.source_fill_cycles = op.source_window_word_reads + FILL_PIPELINE_OVERHEAD
        op.feed_cycles = max(op.activation_read_cycles, op.source_fill_cycles, op.weight_refill_cycles)
        op.notes.extend(["dense128_os_8x16 mapping", f"SAME footprint={fh}x{fw} per 1x8 output tile"])
        op.source_class = "validated_rtl+exact_formula"
    else:
        op.feed_cycles = max(op.activation_read_cycles, op.weight_refill_cycles)
        op.notes.append("PW output-stationary 8-pixel x 16-Cout tile")
        op.source_class = "validated_rtl+exact_formula"
    op.selected_service_cycles = max(op.core_service_cycles, op.feed_cycles)
    op.serial_service_cycles = op.core_service_cycles + op.feed_cycles


def model_dw(op: OpLedger) -> None:
    p = op.output_h * op.output_w
    spatial_tiles = ceil_div(op.output_h, 4) * ceil_div(op.output_w, 8)
    groups16 = ceil_div(op.cin, 16)
    commands = spatial_tiles * groups16
    fh = (4 - 1) * op.stride + 3
    fw = (8 - 1) * op.stride + 3
    words_per_command = ceil_div(fh * fw * 16, 4)
    op.pixel_count = p
    op.dw_spatial_tiles_4x8 = spatial_tiles
    op.dw_commands = commands
    op.dw_tokens = commands * DW_TOKENS_PER_COMMAND
    op.dw_stream4_writes = commands * DW_STREAM4_WRITES_PER_COMMAND
    # A 4x8 command is intentionally retained even for the 4x4 D4 tail;
    # invalid columns are masked but still consume the measured command
    # service.  Thus physical products can exceed semantic products.
    op.physical_macs = op.dw_tokens * DW_CHANNELS_PER_TOKEN
    op.masked_macs = op.physical_macs - op.semantic_macs
    op.dw_source_words_per_command = words_per_command
    op.source_window_word_reads = commands * words_per_command
    op.dw_source_fill_work_cycles = commands * (words_per_command + FILL_PIPELINE_OVERHEAD)
    op.dw_initial_fill_cycles = words_per_command + FILL_PIPELINE_OVERHEAD
    op.dw_config_cycles = groups16 * DW_CONFIG_CYCLES_PER_16CH_GROUP
    op.dw_compute_cycles = commands * DW_JOB_CYCLES[op.stride] + op.dw_config_cycles
    op.pipeline_startup_cycles = op.dw_initial_fill_cycles
    op.pipeline_drain_cycles = 0  # measured command service includes drain
    op.core_service_cycles = op.dw_compute_cycles
    op.source_fill_cycles = op.dw_source_fill_work_cycles
    op.activation_write_words = op.dw_stream4_writes
    # Transfer the completed DW row store into the paired-scratch/PW feeder.
    # A row line is one 8-pixel vector; each 8-channel group takes two packed
    # 32-bit reads under the measured contract.  This is real traffic, not a
    # free edge between DW and project PW.
    row_lines = op.output_h * ceil_div(op.output_w, 8)
    op.scratch_transfer_read_words = row_lines * SCRATCH_8PIXEL_WORDS_PER_8CH_GROUP * ceil_div(op.cout, 8)
    op.scratch_transfer_cycles = op.scratch_transfer_read_words * SCRATCH_READ_CYCLES_PER_WORD + row_lines * SCRATCH_ROW_FENCE_CYCLES
    kernel_params = op.cin * op.kernel * op.kernel
    op.kernel_weight_words = ceil_div(kernel_params, 4)
    op.bias_words = op.cout
    op.multiplier_words = op.cout
    op.shift_words = ceil_div(op.cout, 4)
    op.total_weight_words = op.kernel_weight_words + op.bias_words + op.multiplier_words + op.shift_words
    op.weight_cache_refills = groups16
    op.weight_tile_bytes = 16 * op.kernel * op.kernel
    op.weight_refill_cycles = ceil_div(kernel_params, WEIGHT_REFILL_BUS_BYTES_PER_CYCLE)
    op.feed_cycles = op.dw_initial_fill_cycles
    # Double-bank source fill hides all later fills behind the measured DW
    # command issue/drain.  The initial fill remains exposed.
    op.selected_service_cycles = op.dw_initial_fill_cycles + op.dw_compute_cycles
    op.serial_service_cycles = op.dw_source_fill_work_cycles + op.dw_compute_cycles
    op.notes.extend([
        "measured 4x8 DW command service",
        f"SAME footprint={fh}x{fw}, 16-channel command groups={groups16}",
        "inactive-bank source fills hidden after initial fill (assumption)",
    ])
    op.source_class = "validated_rtl+exact_formula+rtl_assumption"


def model_other(op: OpLedger) -> None:
    # The only `other` op in D4 is FC; FC stays on the existing scalar unit in
    # this first mapping so the model does not credit an unverified new FC
    # datapath.
    p = op.output_h * op.output_w
    op.pixel_count = p
    op.pixel_tiles_8 = 1
    op.cout_tiles_16 = 1
    op.physical_tiles_8x16 = 1
    op.issue_cycles = op.semantic_macs
    op.physical_macs = op.semantic_macs
    op.pipeline_startup_cycles = PIPELINE_BOUNDARY_STARTUP
    op.pipeline_drain_cycles = PIPELINE_BOUNDARY_DRAIN
    op.core_service_cycles = op.semantic_macs + 2
    op.activation_word_reads = ceil_div(op.cin, 4)
    op.activation_read_cycles = op.activation_word_reads
    op.source_activation_word_reads = op.activation_word_reads
    op.activation_write_words = ceil_div(op.cout, 4)
    op.kernel_weight_words = ceil_div(op.cin * op.cout, 4)
    op.bias_words = op.cout
    op.multiplier_words = op.cout
    op.shift_words = ceil_div(op.cout, 4)
    op.total_weight_words = op.kernel_weight_words + op.bias_words + op.multiplier_words + op.shift_words
    op.weight_cache_refills = 1
    op.weight_tile_bytes = op.cin * op.cout
    op.weight_refill_cycles = ceil_div(op.kernel_weight_words, 4)
    op.feed_cycles = max(op.activation_read_cycles, op.weight_refill_cycles)
    op.selected_service_cycles = op.core_service_cycles
    op.serial_service_cycles = op.core_service_cycles + op.feed_cycles
    op.notes.append("existing scalar FC unit; no unverified 128-MAC FC credit")
    op.source_class = "existing_rtl_contract+exact_formula"


def model_op(op: OpLedger) -> None:
    if op.kind in ("pw1x1", "dense3x3"):
        model_pw_or_dense(op)
    elif op.kind == "dw3x3":
        model_dw(op)
    else:
        model_other(op)


def group_rows(rows: Iterable[dict[str, Any]]) -> list[tuple[str, list[OpLedger]]]:
    grouped: dict[str, list[OpLedger]] = {}
    order: list[str] = []
    for row in rows:
        op = op_from_profile(row)
        grouped.setdefault(op.block, [])
        if op.block not in order:
            order.append(op.block)
        model_op(op)
        grouped[op.block].append(op)
    return [(name, grouped[name]) for name in order]


def make_block(name: str, ops: list[OpLedger], total_macs: int, total_params: int) -> BlockLedger:
    first, last = ops[0], ops[-1]
    input_shape = f"{first.input_h}x{first.input_w}x{first.cin}"
    output_shape = f"{last.output_h}x{last.output_w}x{last.cout}"
    residual = any(op.residual for op in ops)
    macs = sum(op.semantic_macs for op in ops)
    params = sum(op.parameter_count for op in ops)
    dw_ops = [op for op in ops if op.kind == "dw3x3"]
    pw_ops = [op for op in ops if op.kind in ("pw1x1", "dense3x3")]
    # The project PW consumes DW output through the paired-scratch transfer.
    # It is a feeder phase for the project stage and can overlap with its
    # output-stationary compute only if a later RTL stream proves it.
    if dw_ops and pw_ops:
        project = pw_ops[-1]
        transfer = sum(op.scratch_transfer_cycles for op in dw_ops)
        project.feed_cycles = max(project.feed_cycles, transfer)
        project.selected_service_cycles = max(project.core_service_cycles, project.feed_cycles)
        project.serial_service_cycles = project.core_service_cycles + project.feed_cycles
        project.source_activation_word_reads = 0
        project.notes.append("DW output enters via paired-scratch transfer")
    dw_cycles = sum(op.selected_service_cycles for op in dw_ops)
    pw_cycles = sum(op.selected_service_cycles for op in pw_ops)

    # The DW source fill can be prefetched while the following project PW
    # weight tile is being selected.  This is reported as potential only and
    # is not subtracted from the selected dependency-ordered schedule.
    dw_pw_overlap = 0
    if dw_ops and pw_ops:
        dw_hidden = sum(max(0, op.dw_source_fill_work_cycles - op.dw_initial_fill_cycles) for op in dw_ops)
        project_refill = max(op.weight_refill_cycles for op in pw_ops if op is not pw_ops[0]) if len(pw_ops) > 1 else 0
        dw_pw_overlap = min(dw_hidden, project_refill)

    residual_words = 0
    residual_read = 0
    residual_add = 0
    residual_service = 0
    notes: list[str] = []
    if residual:
        # The shortcut shape is the block input shape.  D4 residual blocks
        # all have equal spatial/channel input and output shapes.
        residual_words = ceil_div(first.input_h * first.input_w * first.cin, RESIDUAL_VECTOR_BYTES)
        residual_read = residual_words
        residual_add = residual_words
        # A one-word synchronous BRAM read followed by a vector add can be
        # pipelined, hence words+one.  This is a validation assumption.
        residual_service = residual_words + 1
        notes.append("residual scratch read/add is pipelined; exact RTL latency pending")

    op_selected = sum(op.selected_service_cycles for op in ops)
    op_serial = sum(op.serial_service_cycles for op in ops)
    startup = sum(op.pipeline_startup_cycles for op in ops)
    drain = sum(op.pipeline_drain_cycles for op in ops)
    vector_writes = sum(op.requant_vector4_writes or op.dw_stream4_writes for op in ops)
    boundary_fence = 1
    selected = op_selected + residual_service + boundary_fence
    serial = op_serial + residual_read + residual_add + boundary_fence
    return BlockLedger(
        name=name,
        block_type="stem" if name == "stem" else ("head" if name == "head" else ("classifier" if name == "classifier" else "mbconv")),
        input_shape=input_shape,
        output_shape=output_shape,
        residual=residual,
        semantic_macs=macs,
        parameter_count=params,
        mac_share=macs / total_macs,
        parameter_share=params / total_params,
        op_names=[op.name for op in ops],
        op_cycles_selected=op_selected,
        op_cycles_serial=op_serial,
        pw_cycles=pw_cycles,
        dw_cycles=dw_cycles,
        dw_pw_overlap_potential=dw_pw_overlap,
        residual_scratch_read_words=residual_words,
        residual_read_cycles=residual_read,
        residual_add_cycles=residual_add,
        residual_service_cycles=residual_service,
        vector4_writeback_count=vector_writes,
        pipeline_startup_cycles=startup,
        pipeline_drain_cycles=drain,
        boundary_fence_cycles=boundary_fence,
        selected_service_cycles=selected,
        serial_service_cycles=serial,
        notes=notes,
    )


def make_schedule(
    profile_path: Path,
    manifest_path: Path,
    frequency_mhz: float = 125.0,
    quality_path: Path = DEFAULT_QUALITY,
) -> dict[str, Any]:
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    quality = json.loads(quality_path.read_text(encoding="utf-8")) if quality_path.exists() else None
    profile_guard(profile, manifest)
    groups = group_rows(profile["layers"])
    total_macs = int(profile["semantic_macs"])
    total_params = int(profile["parameter_count"])
    blocks = [make_block(name, ops, total_macs, total_params) for name, ops in groups]
    ops = [op for _, group in groups for op in group]

    # Non-convolution tail.  GAP reuses the existing one-int8 accumulation
    # contract; packed activation word count is reported separately.
    gap_h, gap_w, gap_c = 4, 4, 256
    gap_elements = gap_h * gap_w * gap_c
    gap_input_words = ceil_div(gap_elements, 4)
    gap_scalar_cycles = gap_elements * GAP_SCALAR_CYCLES_PER_INT8
    gap_output_words = ceil_div(gap_c, 4)
    gap_cycles = gap_scalar_cycles + 1
    fc_op = next(op for op in ops if op.kind == "other")
    fc_cycles = fc_op.selected_service_cycles

    selected_conv_cycles = sum(b.selected_service_cycles for b in blocks)
    serial_conv_cycles = sum(b.serial_service_cycles for b in blocks)
    selected_total = selected_conv_cycles + gap_cycles + fc_cycles
    serial_total = serial_conv_cycles + gap_cycles + fc_op.serial_service_cycles
    potential_overlap = sum(b.dw_pw_overlap_potential for b in blocks)
    d4_int8_top1 = float(quality["int8"]["top1"]) if quality is not None else 0.9146
    if quality is not None and (
        quality.get("variant_id") != "D4"
        or int(quality["profile"]["semantic_macs"]) != total_macs
    ):
        raise RuntimeError("D4 quality result is not the locked deployment result")

    # Exact deterministic vectors for the first bounded D4 PW RTL test.  The
    # scoreboard can regenerate all 128 INT32 lanes without checkpoint data.
    validation_acts = [[k + p + 1 for p in range(8)] for k in range(16)]
    validation_weights = [[c - 7 for c in range(16)] for _ in range(16)]
    validation_psum = [
        [
            sum(validation_acts[k][p] * validation_weights[k][c] for k in range(16))
            for c in range(16)
        ]
        for p in range(8)
    ]

    # Memory accounting in bytes/BRAM36 is deliberately explicit.  The
    # cache numbers describe a candidate layout, not a Vivado utilization
    # result.
    kernel_bytes = int(profile["weight_params"])
    bias_count = int(profile["bias_params"])
    bias_bytes = bias_count * 4
    multiplier_bytes = bias_count * 4
    shift_bytes = bias_count
    metadata_bytes = bias_bytes + multiplier_bytes + shift_bytes
    all_weight_bytes = kernel_bytes + metadata_bytes
    stage_boundary_bytes = int(profile["peak_activation_bytes_int8_stage_boundary"])
    internal_peak_bytes = int(profile["peak_activation_bytes_int8_internal"])
    memory_items = [
        {"name": "activation_ping_pong", "bytes": 2 * stage_boundary_bytes, "bram36_lower_bound": ceil_div(2 * stage_boundary_bytes, 4608), "source": "profile stage-boundary peak + mapping assumption"},
        {"name": "expanded_dw_scratch", "bytes": internal_peak_bytes, "bram36_lower_bound": ceil_div(internal_peak_bytes, 4608), "source": "profile internal peak"},
        {"name": "shortcut_scratch", "bytes": stage_boundary_bytes, "bram36_lower_bound": ceil_div(stage_boundary_bytes, 4608), "source": "exact residual input shape maximum"},
        {"name": "pw_weight_cache_double_bank", "bytes": 2 * WEIGHT_CACHE_BYTES, "bram36_lower_bound": ceil_div(2 * WEIGHT_CACHE_BYTES, 4608), "source": "rtl_assumption; overlap refill"},
        {"name": "dw_weight_and_qparam_cache", "bytes": 4608, "bram36_lower_bound": 1, "source": "rtl_assumption"},
        {"name": "dw_window_line_buffer", "bytes": 4608, "bram36_lower_bound": 1, "source": "rtl_assumption; max 4x8 SAME footprint"},
        {"name": "global_weight_and_qparam_store", "bytes": all_weight_bytes, "bram36_lower_bound": ceil_div(all_weight_bytes, 4608), "source": "profile weight/bias counts + quantization contract"},
    ]
    memory_total_bytes = sum(int(item["bytes"]) for item in memory_items)
    memory_bram_lower = sum(int(item["bram36_lower_bound"]) for item in memory_items)

    # Exact per-op and per-block conservation checks are kept in the output.
    category_macs = {
        kind: sum(op.semantic_macs for op in ops if op.kind == kind)
        for kind in ("dense3x3", "pw1x1", "dw3x3")
    }
    category_macs["other"] = total_macs - sum(category_macs.values())
    schedule: dict[str, Any] = {
        "schema": "C10-HWQA-v1-edgembconv-hwacandidate-D4-cycle-model-v1",
        "variant_id": "D4",
        "architecture": "D4_C_minus_one_mb4",
        "network_sources": {
            "profile": str(profile_path.relative_to(ROOT)).replace("\\", "/"),
            "profile_sha256": sha256_file(profile_path),
            "deployment_manifest": str(manifest_path.relative_to(ROOT)).replace("\\", "/"),
            "deployment_manifest_sha256": sha256_file(manifest_path),
            "quality_result": str(quality_path.relative_to(ROOT)).replace("\\", "/") if quality_path.exists() else None,
            "quality_result_sha256": sha256_file(quality_path) if quality_path.exists() else None,
            "network_description_policy": "profile and validated deployment manifest only; no hand-written layer graph",
        },
        "locked_profile": LOCKED_PROFILE,
        "engine": {
            "name": "unified128_os_8pixel_x_16cout_partial_k",
            "physical_macs_per_token": PW_PRODUCTS_PER_TOKEN,
            "pixel_tile": PW_PIXEL_TILE,
            "cout_tile": PW_COUT_TILE,
            "activation_bytes_per_token": ACTIVATION_BUS_BYTES_PER_CYCLE,
            "weight_row_bytes_per_token": WEIGHT_REFILL_BUS_BYTES_PER_CYCLE,
            "validated_dense128_first_tile": {"k": PW_DENSE128_FIRST_TILE_K, "cycles": PW_DENSE128_FIRST_TILE_CYCLES, "equation": "27 accepted tokens + 32 vector4 commits"},
        },
        "dw_primitive": {
            "job_cycles_stride1": DW_JOB_CYCLES[1],
            "job_cycles_stride2": DW_JOB_CYCLES[2],
            "tokens_per_command": DW_TOKENS_PER_COMMAND,
            "channels_per_token": DW_CHANNELS_PER_TOKEN,
            "stream4_writes_per_command": DW_STREAM4_WRITES_PER_COMMAND,
            "source_fill_equation": "words_per_4x8_command + 7",
        },
        "assumptions": {
            "weight_cache_bytes_per_bank": WEIGHT_CACHE_BYTES,
            "weight_cache_refill_bus": f"{WEIGHT_REFILL_BUS_BYTES_PER_CYCLE} bytes/cycle",
            "activation_bus": f"{ACTIVATION_BUS_BYTES_PER_CYCLE} bytes/cycle",
            "residual": "one synchronous word read + vector add pipeline; words+1 cycles, pending RTL validation",
            "dw_source_fill": "double-bank hidden after initial fill; serial upper bound also emitted",
            "dw_pw_overlap": "prefetch potential reported but not credited in selected dependency schedule",
            "gap": "existing scalar GAP accumulation contract; packed word traffic reported separately",
            "fc": "existing scalar FC unit; no unverified 128-MAC FC credit",
            "post_route": "not run; this schedule is not full-top timing/power evidence",
        },
        "operator_macs": category_macs,
        "operator_mac_shares_semantic": {k: v / total_macs for k, v in category_macs.items()},
        "operations": [asdict(op) for op in ops],
        "blocks": [asdict(block) for block in blocks],
        "tail": {
            "gap": {"input_elements": gap_elements, "input_word_reads": gap_input_words, "scalar_add_cycles": gap_scalar_cycles, "output_word_writes": gap_output_words, "service_cycles": gap_cycles, "source_class": "existing_rtl_contract+exact_formula"},
            "fc": {"semantic_macs": fc_op.semantic_macs, "weight_word_reads": fc_op.total_weight_words, "service_cycles": fc_cycles, "source_class": fc_op.source_class},
        },
        "memory_mapping": {"items": memory_items, "total_modeled_bytes": memory_total_bytes, "bram36_lower_bound_sum": memory_bram_lower, "note": "lower bound assumes perfect independent packing; not Vivado utilization"},
        "totals": {
            "conv_semantic_macs": total_macs - category_macs["other"],
            "semantic_macs": total_macs,
            "physical_macs_issued": sum(op.physical_macs for op in ops),
            "masked_physical_macs": sum(op.masked_macs for op in ops),
            "weight_kernel_word_reads": sum(op.kernel_weight_words for op in ops),
            "weight_total_word_reads": sum(op.total_weight_words for op in ops),
            "weight_cache_refills": sum(op.weight_cache_refills for op in ops),
            "activation_word_reads": sum(op.activation_word_reads for op in ops) + gap_input_words,
            "source_window_word_reads": sum(op.source_window_word_reads for op in ops),
            "activation_write_words": sum(op.activation_write_words for op in ops),
            "scratch_transfer_read_words": sum(op.scratch_transfer_read_words for op in ops),
            "residual_scratch_read_words": sum(b.residual_scratch_read_words for b in blocks),
            "pipeline_startup_cycles": sum(b.pipeline_startup_cycles for b in blocks),
            "pipeline_drain_cycles": sum(b.pipeline_drain_cycles for b in blocks),
            "dw_pw_overlap_potential_cycles": potential_overlap,
            "selected_conv_cycles": selected_conv_cycles,
            "selected_total_cycles": selected_total,
            "serial_upper_conv_cycles": serial_conv_cycles,
            "serial_upper_total_cycles": serial_total,
            "frequency_mhz": frequency_mhz,
            "selected_latency_ms": selected_total / (frequency_mhz * 1000.0),
            "serial_upper_latency_ms": serial_total / (frequency_mhz * 1000.0),
        },
        "c0_comparison": {
            **C0_BASELINE,
            "d4_int8_top1": d4_int8_top1,
            "d4_quality_delta_pp_vs_c0": (d4_int8_top1 - C0_BASELINE["int8_top1"]) * 100.0,
            "d4_semantic_mac_delta": total_macs - C0_BASELINE["semantic_macs"],
            "d4_semantic_mac_delta_pct": (total_macs / C0_BASELINE["semantic_macs"] - 1.0) * 100.0,
            "d4_selected_cycle_ratio_vs_c0": selected_total / C0_BASELINE["cycles"],
            "d4_selected_cycle_speedup_vs_c0": C0_BASELINE["cycles"] / selected_total,
            "interpretation": "D4 cycle value is a model; C0 cycle value is measured full-top. They are not equivalent evidence until D4 RTL integration is measured.",
        },
        "resource_risk": {
            "xc7z020_dsp_available": 220,
            "unified128_array_dsp_if_one_dsp_per_mac": 128,
            "remaining_dsp_budget_for_shared_logic_at_70pct": 26,
            "existing_c0_shared_estimate_dsp": 65,
            "risk": "128 + reused shared arithmetic/control may exceed the <70% DSP gate unless MAC packing/LUT mapping or resource sharing is demonstrated",
            "no_hardware_claim": True,
        },
        "first_rtl_validation_block": {
            "name": "edgembconv_hwacandidate_d4_pw32_expand_128tile",
            "purpose": "first D4-specific PW vector contract before full block integration",
            "interface": {
                "clock": "1 synchronous clock; ready/valid on token input and output",
                "valid_in": "one accepted K token per cycle when ready_in",
                "first_k": "1 only on k=0",
                "last_k": "1 only on k=15 for mb32.expand",
                "k_idx": "0..15",
                "pixel_mask": "8'hff",
                "cout_mask": "16'hffff",
                "act_vec": "signed int8 p0..p7 for one input channel",
                "wgt_vec_lo_hi": "signed int8 weights for Cout 0..15 for the same K",
                "ready_out": "held low for a 3-cycle output-stability check, then high",
                "expected_psum": "128 exact INT32 lanes from independent Python dot product",
            },
            "shape": {"pixels": 8, "cin": 16, "cout": 32, "cout_tile": 16, "tiles": 1},
                "expected": {
                "accepted_tokens": 16,
                "semantic_macs": 8 * 16 * 16,
                    "physical_macs": 8 * 16 * 16,
                    "vector4_commits_per_cout_tile": 32,
                    "ideal_core_cycles": 16 + 32,
                    "with_boundary_startup_and_fence_assumption": 16 + 32 + 1 + 1,
                    "with_three_cycle_output_stall_and_boundary_assumption": 16 + 32 + 1 + 1 + 3,
                },
                "exact_vector": {
                    "bias": 0,
                    "activation_tokens_k0_to_k15_pixel0_to_p7": validation_acts,
                    "weight_tokens_k0_to_k15_cout0_to_cout15": validation_weights,
                    "expected_psum_pixel0_to_p7_cout0_to_cout15": validation_psum,
                    "generator": "act[k][p]=k+p+1; weight[k][c]=c-7; psum[p][c]=sum_k(act[k][p]*weight[k][c])",
                },
                "source_class": "validated_dense128_contract+exact_formula; expected full D4 vectors pending RTL test",
        },
    }
    return schedule


def format_int(value: int) -> str:
    return f"{int(value):,}"


def render_report(schedule: dict[str, Any]) -> str:
    p = schedule["locked_profile"]
    t = schedule["totals"]
    lines = [
        "# EdgeMBConv hardware-aware candidate D4 — cycle/memory model",
        "",
        "This independent D4 report freezes the validated deployment graph and does not modify C0, training artifacts, checkpoints, or production RTL. It is a traceable cycle projection, not full-top synthesis, post-route, power, or energy evidence.",
        "",
        "## Frozen source and acceptance boundary",
        "",
        f"- Profile: `{schedule['network_sources']['profile']}` (SHA256 `{schedule['network_sources']['profile_sha256']}`)",
        f"- Deployment manifest: `{schedule['network_sources']['deployment_manifest']}` (SHA256 `{schedule['network_sources']['deployment_manifest_sha256']}`)",
        f"- Guard: PASS — params={format_int(p['parameter_count'])}, semantic MAC={format_int(p['semantic_macs'])}, dense3x3={format_int(p['dense3x3'])}, PW={format_int(p['pw1x1'])}, DW={format_int(p['dw3x3'])}",
        "- Network shape/counts are read from those files only; no hand-written D4 layer list is used.",
        "",
        "## Mapping provenance",
        "",
        "| Item | Mapping | Evidence class |",
        "|---|---|---|",
        "| PW / dense tile | 8 pixels × 16 Cout, one K token/cycle, 128 products/token | validated dense128 RTL contract + exact tile formula |",
        "| Dense stem halo | 1×8 output tile, SAME 3×10 footprint, packed 32-bit source words | exact shape/halo formula; feeder integration pending |",
        "| DW service | 4×8 command, 16-channel group, 288 vector tap tokens, 128 stream4 writes | measured 4x8 RTL probe |",
        "| DW source fill | footprint words + 7 cycles; first fill exposed, later fills double-bank hidden | measured fill contract + scheduler assumption |",
        "| Requant/writeback | explicit vector4 writes; physical tail commits retained | exact packing formula, requant RTL still to integrate |",
        "| Residual | shortcut scratch read plus vector add, words+1 pipeline | model assumption; exact RTL validation pending |",
        "",
        "## Operator totals",
        "",
        "| Operator | Semantic MAC | Share |",
        "|---|---:|---:|",
    ]
    for kind, value in schedule["operator_macs"].items():
        lines.append(f"| {kind} | {format_int(value)} | {100 * schedule['operator_mac_shares_semantic'][kind]:.2f}% |")
    lines += [
        f"| **total** | **{format_int(t['semantic_macs'])}** | **100.00%** |",
        "",
        "The D4 convolution narrative remains DW/PW-oriented: dense 3×3 is 3.80% of semantic MACs; PW+DW are 96.18%. There is no fused block in D4, so no single fused block anomaly is present.",
        "",
        "## Per-operation schedule",
        "",
        "Columns distinguish semantic work from physical tile issue and memory/overlap accounting.",
        "",
        "| Op | Type | Shape | K/M | semantic MAC | tiles | issue | DW/source service | weight words/refills | activation words | vector4 writes | selected cycles | serial cycles |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for op in schedule["operations"]:
        shape = f"{op['input_h']}x{op['input_w']}x{op['cin']}→{op['output_h']}x{op['output_w']}x{op['cout']}"
        tiles = op["physical_tiles_8x16"] if op["kind"] in ("pw1x1", "dense3x3") else op["dw_commands"]
        issue = op["issue_cycles"] if op["kind"] != "dw3x3" else op["dw_compute_cycles"]
        source_service = op["source_fill_cycles"] if op["kind"] == "dw3x3" else op["source_window_word_reads"]
        lines.append(
            f"| `{op['name']}` | {op['kind']} | {shape} | {op['cin']}/{op['cout']} | {format_int(op['semantic_macs'])} | {format_int(tiles)} | {format_int(issue)} | {format_int(source_service)} | {format_int(op['total_weight_words'])}/{op['weight_cache_refills']} | {format_int(op['activation_word_reads'])} | {format_int(op['requant_vector4_writes'] or op['dw_stream4_writes'])} | {format_int(op['selected_service_cycles'])} | {format_int(op['serial_service_cycles'])} |"
        )
    lines += [
        "",
        "## Per-block schedule",
        "",
        "| Block | Input→output | MAC | MAC share | params | param share | PW cycles | DW cycles | residual read/add | DW→PW overlap potential | selected | serial |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for block in schedule["blocks"]:
        lines.append(
            f"| `{block['name']}` | {block['input_shape']}→{block['output_shape']} | {format_int(block['semantic_macs'])} | {100 * block['mac_share']:.2f}% | {format_int(block['parameter_count'])} | {100 * block['parameter_share']:.2f}% | {format_int(block['pw_cycles'])} | {format_int(block['dw_cycles'])} | {format_int(block['residual_read_cycles'])}/{format_int(block['residual_add_cycles'])} | {format_int(block['dw_pw_overlap_potential'])} | {format_int(block['selected_service_cycles'])} | {format_int(block['serial_service_cycles'])} |"
        )
    lines += [
        "",
        "## Total cycle accounting",
        "",
        f"- Physical MACs issued by padded 8×16 tiles: **{format_int(t['physical_macs_issued'])}**; masked physical products: **{format_int(t['masked_physical_macs'])}**. Semantic work remains **{format_int(t['semantic_macs'])}**; no network computation is removed.",
        f"- Selected dependency-ordered projection: **{format_int(t['selected_total_cycles'])} cycles** = convolution {format_int(t['selected_conv_cycles'])} + GAP {format_int(schedule['tail']['gap']['service_cycles'])} + FC {format_int(schedule['tail']['fc']['service_cycles'])}.",
        f"- Serial memory upper comparison: **{format_int(t['serial_upper_total_cycles'])} cycles**.",
        f"- At {t['frequency_mhz']:.0f} MHz: selected {t['selected_latency_ms']:.3f} ms; serial upper {t['serial_upper_latency_ms']:.3f} ms.",
        f"- Potential DW→following-PW prefetch overlap: {format_int(t['dw_pw_overlap_potential_cycles'])} cycles, **not credited** in selected total because the current schedule keeps block dependencies explicit.",
        "- Source-window words, activation words, scratch words, vector4 writeback, startup/drain, and residual service are all retained in the schedule; none is treated as zero-cost.",
        "",
        "## Memory budget mapping",
        "",
        "| Buffer | Bytes | BRAM36 lower bound | Evidence/meaning |",
        "|---|---:|---:|---|",
    ]
    for item in schedule["memory_mapping"]["items"]:
        lines.append(f"| {item['name']} | {format_int(item['bytes'])} | {item['bram36_lower_bound']} | {item['source']} |")
    lines += [
        f"| **modeled total** | **{format_int(schedule['memory_mapping']['total_modeled_bytes'])}** | **{schedule['memory_mapping']['bram36_lower_bound_sum']}** | lower-bound sum, not Vivado utilization |",
        "",
        f"Kernel weights are {format_int(int(json.loads((ROOT / schedule['network_sources']['profile']).read_text(encoding='utf-8'))['weight_params']))} INT8 bytes/parameters; the profile separately reports bias_params={format_int(int(json.loads((ROOT / schedule['network_sources']['profile']).read_text(encoding='utf-8'))['bias_params']))}. Bias/multiplier/shift metadata is counted as INT32/packed-INT8 words in the machine schedule.",
        "",
        "## DSP/resource risk",
        "",
        "The 128-MAC array is 128 DSP48E1 if one INT8 product maps to one DSP. XC7Z020 has 220 DSPs, leaving 26 DSPs at the requested 70% ceiling. The historical C0 hierarchy used roughly 65 DSPs including shared stem/FC/control arithmetic; whether those resources can be removed, packed, or mapped to LUTs is not yet proven. Therefore this model does not claim the resource gate.",
        "",
        "## C0 comparison",
        "",
        f"- C0 historical full-top evidence: {format_int(C0_BASELINE['semantic_macs'])} MAC, {format_int(C0_BASELINE['cycles'])} measured cycles, INT8 top-1 {100 * C0_BASELINE['int8_top1']:.2f}%.",
        f"- D4 deployment quality source: {100 * schedule['c0_comparison']['d4_int8_top1']:.2f}% INT8 (`{schedule['network_sources']['quality_result']}`); delta **+{schedule['c0_comparison']['d4_quality_delta_pp_vs_c0']:.2f} pp**.",
        f"- D4 adds {format_int(schedule['c0_comparison']['d4_semantic_mac_delta'])} semantic MAC ({schedule['c0_comparison']['d4_semantic_mac_delta_pct']:.2f}%) relative to C0. The selected D4 cycle value is a model and cannot be called a measured speedup; the model ratio is {schedule['c0_comparison']['d4_selected_cycle_ratio_vs_c0']:.3f}× C0.",
        "- C0's 70.05%/66.16% quality is a retained trained-baseline result, not an architecture ceiling; D4 is not declared a replacement.",
        "",
        "## First RTL validation block",
        "",
        "The first bounded validation should instantiate the existing dense128 output-stationary primitive with a D4-shaped `mb32.expand` tile. It must use nonzero deterministic vectors and an independent Python INT32 scoreboard.",
        "",
        "| Item | Expected |",
        "|---|---:|",
        "| Shape | 8 pixels × Cin16 × Cout16 tile (one of mb32.expand's two Cout tiles) |",
        "| Accepted K tokens | 16 |",
        "| Semantic/physical products | 2,048 / 2,048 |",
        "| Vector4 commits | 32 |",
        "| Ideal core cycles | 48 = 16 issue + 32 drain |",
        "| Boundary startup/fence assumption | 50 cycles |",
        "| Three-cycle output stall + boundary assumption | 53 cycles |",
        "",
        "Exact vectors (all signed INT8, bias=0): `act[k][p]=k+p+1` for k=0..15 and p=0..7; `weight[k][c]=c-7` for c=0..15. The expected lane formula is `psum[p][c]=sum_k(act[k][p]*weight[k][c])`; the complete 8×16 expected INT32 matrix is recorded in the machine schedule. Required checks are first/last K tags, lane masks, exact 128 psums, output stability during a 3-cycle ready stall, and no duplicate/missing token. Full D4 block and full-top exact logits remain future gates.",
        "",
        "## Limitations and next gate",
        "",
        "- No D4 RTL integration, synthesis, post-route timing, congestion, activity-based power, or board power was run here.",
        "- The selected schedule assumes packed 32-bit activation words and banked 8-byte activation / 16-byte weight rows; the current legacy external one-int8-per-word ABI cannot be silently substituted.",
        "- DW command service is measured, but D4's expanded-channel command count and multi-block steady-state overlap still require an RTL producer/consumer test.",
        "- Resource risk is material: 128 DSP array plus shared arithmetic may exceed the <70% DSP limit. This is an architecture/dataflow validation issue, not evidence that D4 wins C0.",
        "",
        "Machine-readable schedule: `build/edgembconv_hwacandidate_d4_cycle_model/edgembconv_hwacandidate_d4_cycle_schedule.json`.",
        "",
    ]
    return "\n".join(lines)


def run_checks(schedule: dict[str, Any]) -> list[str]:
    p = schedule["locked_profile"]
    t = schedule["totals"]
    checks: list[str] = []
    if sum(schedule["operator_macs"].values()) != p["semantic_macs"]:
        raise AssertionError("operator MAC totals do not reconcile")
    if sum(op["semantic_macs"] for op in schedule["operations"]) != p["semantic_macs"]:
        raise AssertionError("operation MAC totals do not reconcile")
    if sum(op["parameter_count"] for op in schedule["operations"]) != p["parameter_count"]:
        raise AssertionError("operation parameter totals do not reconcile")
    for op in schedule["operations"]:
        if op["kind"] in ("pw1x1", "dense3x3"):
            if op["physical_macs"] < op["semantic_macs"]:
                raise AssertionError(f"physical MACs undercount {op['name']}")
            reduction_k = op["cin"] * (op["kernel"] ** 2 if op["kind"] == "dense3x3" else 1)
            if op["physical_macs"] != op["physical_tiles_8x16"] * 128 * reduction_k:
                raise AssertionError(f"tile conservation failed {op['name']}")
        if op["kind"] == "dw3x3":
            if op["dw_tokens"] * 16 != op["physical_macs"] or op["physical_macs"] < op["semantic_macs"]:
                raise AssertionError(f"DW token/physical-work conservation failed {op['name']}")
            if op["dw_commands"] * 128 != op["dw_stream4_writes"]:
                raise AssertionError(f"DW write conservation failed {op['name']}")
    if t["selected_total_cycles"] <= 0 or t["serial_upper_total_cycles"] < t["selected_total_cycles"]:
        raise AssertionError("invalid cycle totals")
    vec = schedule["first_rtl_validation_block"]["exact_vector"]
    acts = vec["activation_tokens_k0_to_k15_pixel0_to_p7"]
    wgts = vec["weight_tokens_k0_to_k15_cout0_to_cout15"]
    expected = vec["expected_psum_pixel0_to_p7_cout0_to_cout15"]
    regenerated = [
        [sum(acts[k][p] * wgts[k][c] for k in range(16)) for c in range(16)]
        for p in range(8)
    ]
    if regenerated != expected:
        raise AssertionError("first RTL validation vector psums do not regenerate")
    checks.extend([
        "profile/manifest locked values reconcile",
        "semantic operator and operation MAC sums reconcile",
        "operation parameter sum reconciles",
        "PW/dense physical tile work is not below semantic work",
        "DW token and stream4 write conservation reconcile",
        "selected cycle total is positive and no greater than serial comparison",
        "first RTL validation vectors regenerate exact INT32 psums",
    ])
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--quality", type=Path, default=DEFAULT_QUALITY)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--frequency-mhz", type=float, default=125.0)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    profile_path = args.profile.resolve()
    manifest_path = args.manifest.resolve()
    schedule = make_schedule(profile_path, manifest_path, args.frequency_mhz, args.quality.resolve())
    checks = run_checks(schedule)
    if args.check_only:
        print(json.dumps({"status": "PASS", "checks": checks, "totals": schedule["totals"]}, indent=2))
        return 0
    args.out_dir.mkdir(parents=True, exist_ok=True)
    schedule["consistency_checks"] = {"status": "PASS", "checks": checks}
    schedule_path = args.out_dir / "edgembconv_hwacandidate_d4_cycle_schedule.json"
    schedule_path.write_text(json.dumps(schedule, indent=2) + "\n", encoding="utf-8")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(render_report(schedule), encoding="utf-8")
    print(json.dumps({"status": "PASS", "schedule": str(schedule_path), "report": str(args.report), "checks": checks, "totals": schedule["totals"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
