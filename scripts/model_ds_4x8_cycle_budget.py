#!/usr/bin/env python3
"""Deterministic cycle ledger for the non-production 4x8 DS/PW screen.

The model is intentionally an accounting model, not a functional simulator.
It uses measured no-backpressure service times from the real RTL probes:

  * 4x8 DW producer command (one 16-channel group): 1767 cycles at stride 1,
    2232 cycles at stride 2; each command emits 288 DW tokens and 128
    stream4 writes.
  * source fill: 247 cycles for 240 words and 619 cycles for 612 words with
    a three-cycle response queue, i.e. words + 7.
  * packed 8-pixel x 8-cout PW job: Cin + 62 cycles, including its 32-beat
    row2 drain, measured at Cin=16/48/128.

The ledger then charges every source fill, DW token/write, paired-scratch
transfer, packed PW word, PW activation token, output drain, tail mask, and
layer fence.  It reports optimistic double-bank overlap as max(DW,PW) and a
serial upper comparison.  It does not claim that the current non-production
shell already implements the ideal scheduler; that is exactly the integration
question this ledger is intended to expose.
"""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass, asdict
from pathlib import Path


DW_SPECS = (
    (1, "DS1", 32, 32, 16, 32, 1),
    (2, "DS2", 32, 32, 32, 64, 2),
    (3, "DS3", 16, 16, 64, 64, 1),
    (4, "DS4", 16, 16, 64, 128, 2),
    (5, "DS5", 8, 8, 128, 128, 1),
    (6, "DS6", 8, 8, 128, 256, 2),
)

# Direct Verilator probe measurements.  Keep these constants visible: a
# future RTL change must update the probe and the ledger together.
DW_JOB_CYCLES = {1: 1767, 2: 2232}
DW_TOKENS_PER_JOB = 4 * 8 * 9
DW_STREAM4_WRITES_PER_JOB = 4 * 8 * 4
FILL_RESPONSE_LATENCY = 3
FILL_PIPELINE_TAIL = 4
PW_JOB_FIXED_OVERHEAD = 62
PW_DRAIN_BEATS = 32
TRANSFER_READ_CYCLES = 6
TRANSFER_FENCE_CYCLES = 3


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


@dataclass
class LayerLedger:
    index: int
    layer: str
    in_h: int
    in_w: int
    cin: int
    cout: int
    stride: int
    out_h: int
    out_w: int
    output_pixels: int
    pixel_jobs_8: int
    producer_tiles_4x8: int
    cin_groups_8: int
    cin_groups_16: int
    cout_tiles_8: int
    producer_commands: int
    dw_tokens: int
    dw_stream4_writes: int
    footprint_h: int
    footprint_w: int
    source_words: int
    initial_fill_cycles: int
    source_fill_total_cycles: int
    dw_config_cycles: int
    dw_issue_drain_cycles: int
    dw_job_cycles: int
    dw_service_cycles: int
    row_lines: int
    transfer_reads: int
    transfer_read_cycles: int
    transfer_commit_fence_cycles: int
    scratch_transfer_cycles: int
    packed_weight_words: int
    packed_weight_load_cycles: int
    pw_config_cycles: int
    pw_activation_tokens: int
    pw_job_cycles: int
    pw_issue_drain_cycles: int
    pw_floor_cycles: int
    pw_service_cycles: int
    overlap_floor_cycles: int
    overlap_service_cycles: int
    serial_cycles: int
    tail_pixels: int
    tail_fence_cycles: int
    overlap_assumed: str
    notes: str


def make_layer(spec: tuple[int, str, int, int, int, int, int]) -> LayerLedger:
    index, name, in_h, in_w, cin, cout, stride = spec
    out_h = ceil_div(in_h, stride)
    out_w = ceil_div(in_w, stride)
    pixels = out_h * out_w
    pixel_jobs = ceil_div(pixels, 8)

    # The physical producer is fixed at 4x8 output geometry.  DS6's 4x4
    # tail therefore still pays one 4x8 command per 16-channel group and
    # uses masks for the four invalid columns.
    tile_h = ceil_div(out_h, 4)
    tile_w = ceil_div(out_w, 8)
    producer_tiles = tile_h * tile_w
    groups16 = ceil_div(cin, 16)
    groups8 = ceil_div(cin, 8)
    cout_tiles = ceil_div(cout, 8)
    producer_commands = producer_tiles * groups16

    # Full fixed 4x8 footprint is used by the current producer, including
    # the DS6 spatial tail.  This is conservative and matches its ABI.
    footprint_h = (4 - 1) * stride + 3
    footprint_w = (8 - 1) * stride + 3
    words_per_command = footprint_h * footprint_w * 4
    source_words = producer_commands * words_per_command
    fill_cycles = words_per_command + FILL_RESPONSE_LATENCY + FILL_PIPELINE_TAIL
    source_fill_total = producer_commands * fill_cycles

    # One nine-tap vector configuration per 16-channel DW command group;
    # it is a one-time layer setup, not repeated for every spatial tile.
    dw_config = 9 * groups16
    dw_job = DW_JOB_CYCLES[stride]
    dw_issue_drain = producer_commands * dw_job
    # Warm-up model: one fill is exposed, then the inactive-bank source fill
    # is assumed to overlap the next DW command.  source_fill_total is kept
    # as traffic/work accounting and is deliberately not added here.
    dw_service = fill_cycles + dw_issue_drain + dw_config

    # A paired scratch line is one 8-pixel vector.  Each 16-channel DW
    # command contributes two 8-channel groups.  Transfer reads two image
    # halves per 8-channel group; the measured protocol has a small acquire
    # and commit fence around each line.
    row_lines = out_h * tile_w
    transfer_reads = row_lines * 2 * groups8
    transfer_read_cycles = row_lines * TRANSFER_READ_CYCLES * groups8
    transfer_commit_fence_cycles = row_lines * TRANSFER_FENCE_CYCLES
    transfer_cycles = transfer_read_cycles + transfer_commit_fence_cycles

    # Packed row-store format is two 32-bit words per 64-bit (cout,k) row.
    packed_words = 2 * cout_tiles * cin
    packed_load = packed_words
    pw_config = 0  # job configuration is captured on the one-cycle issue
    activation_tokens = row_lines * cout_tiles * cin
    pw_job = cin + PW_JOB_FIXED_OVERHEAD
    pw_issue_drain = row_lines * cout_tiles * pw_job
    pw_floor = packed_load + pw_issue_drain
    pw_service = pw_floor + transfer_cycles

    # overlap_floor assumes transfer is hidden by the PW job; overlap_service
    # charges it explicitly.  Both retain the layer-end fence in the larger
    # side of the max.  serial is a deliberately non-overlapped comparison.
    overlap_floor = max(dw_service, pw_floor)
    overlap_service = max(dw_service, pw_service)
    serial = dw_service + pw_service
    tail = max(0, 8 - (out_w % 8)) if (out_w % 8) else 0
    tail_fence = transfer_commit_fence_cycles
    note = "fixed 4x8 geometry"
    if tail:
        note += "; DS6 masks 4 invalid columns"
    return LayerLedger(
        index=index, layer=name, in_h=in_h, in_w=in_w, cin=cin, cout=cout,
        stride=stride, out_h=out_h, out_w=out_w, output_pixels=pixels,
        pixel_jobs_8=pixel_jobs, producer_tiles_4x8=producer_tiles,
        cin_groups_8=groups8, cin_groups_16=groups16, cout_tiles_8=cout_tiles,
        producer_commands=producer_commands, dw_tokens=producer_commands * DW_TOKENS_PER_JOB,
        dw_stream4_writes=producer_commands * DW_STREAM4_WRITES_PER_JOB,
        footprint_h=footprint_h, footprint_w=footprint_w, source_words=source_words,
        initial_fill_cycles=fill_cycles, source_fill_total_cycles=source_fill_total,
        dw_config_cycles=dw_config, dw_issue_drain_cycles=dw_issue_drain,
        dw_job_cycles=dw_job, dw_service_cycles=dw_service, row_lines=row_lines,
        transfer_reads=transfer_reads, transfer_read_cycles=transfer_read_cycles,
        transfer_commit_fence_cycles=transfer_commit_fence_cycles,
        scratch_transfer_cycles=transfer_cycles,
        packed_weight_words=packed_words, packed_weight_load_cycles=packed_load,
        pw_config_cycles=pw_config,
        pw_activation_tokens=activation_tokens, pw_job_cycles=pw_job,
        pw_issue_drain_cycles=pw_issue_drain,
        pw_floor_cycles=pw_floor, pw_service_cycles=pw_service,
        overlap_floor_cycles=overlap_floor, overlap_service_cycles=overlap_service,
        serial_cycles=serial, tail_pixels=tail, tail_fence_cycles=tail_fence,
        overlap_assumed="yes: max(DW,PW+transfer)", notes=note,
    )


def render(rows: list[LayerLedger], power_w: float, freq_mhz: float) -> str:
    total = {k: sum(getattr(r, k) for r in rows) for k in (
        "output_pixels", "producer_commands", "dw_tokens", "dw_stream4_writes",
        "source_words", "source_fill_total_cycles", "dw_config_cycles",
        "dw_issue_drain_cycles", "dw_service_cycles", "row_lines", "transfer_reads",
        "transfer_read_cycles", "transfer_commit_fence_cycles", "scratch_transfer_cycles",
        "packed_weight_words", "pw_activation_tokens", "pw_issue_drain_cycles",
        "pw_floor_cycles", "pw_service_cycles", "overlap_floor_cycles",
        "overlap_service_cycles", "serial_cycles")}
    ops = 2 * 5_136_896
    overlap_gopsw = ops * (freq_mhz * 1e6) / (total["overlap_service_cycles"] * 1e9 * power_w)
    lines = [
        "# DS 4x8 / paired-scratch / packed-PW cycle ledger",
        "",
        "This is a deterministic accounting model calibrated by real RTL timing probes; it is not full-top evidence.",
        "",
        "## Calibration",
        "",
        "| probe | measured |",
        "|---|---:|",
        "| 4x8 DW job, stride1 (288 tokens/128 writes) | 1767 cycles |",
        "| 4x8 DW job, stride2 (288 tokens/128 writes) | 2232 cycles |",
        "| source fill, 240 words / 3-cycle response | 247 cycles |",
        "| source fill, 612 words / 3-cycle response | 619 cycles |",
        "| packed PW job, Cin=16/48/128 | Cin + 62 cycles |",
        "| packed PW job outputs | 32 two-lane beats, including row2 drain |",
        "",
        "## Reproducible calibration runs",
        "",
        "- `wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && bash scripts/run_ds_word_window_dw_tagless_stream4_4x8_timing.sh'`",
        "  raw PASS: `nonzero_source=1 stride=1 words=240 fill_cycles=247 job_cycles=1767 total_cycles=2038 dw_writes=128 tokens=288`; `nonzero_source=1 stride=2 words=612 fill_cycles=619 job_cycles=2232 total_cycles=2875 dw_writes=128 tokens=288`.",
        "- `wsl.exe bash -lc '/mnt/d/Stuff/Project/build/verilator_dw_pw_pair_scratch_rowbank2_packed_consumer_timing_48/sim_timing'`",
        "  raw PASS: `cin=48 groups=6 words=96 job_cycles=130 total_cycles=370 outputs=32 packed_reads=48 activations=48` (nonzero deterministic source/weight data).",
        "",
        "## Per-layer ledger",
        "",
        "| layer | shape / s | DW cmds | source words / fill(init/work) | DW cfg | DW issue+drain | DW total | row lines | transfer read + commit | PW jobs | PW cfg/load | PW issue+drain | PW total | ideal overlap | overlap+transfer | serial | tail/fence | overlap? |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        pw_jobs = r.row_lines * r.cout_tiles_8
        lines.append(
            f"| {r.layer} | {r.in_h}x{r.in_w}x{r.cin}->{r.out_h}x{r.out_w}x{r.cout} / {r.stride} "
            f"| {r.producer_commands:,} | {r.source_words:,} / {r.initial_fill_cycles:,} init / {r.source_fill_total_cycles:,} work "
            f"| {r.dw_config_cycles:,} | {r.dw_issue_drain_cycles:,} | {r.dw_service_cycles:,} "
            f"| {r.row_lines:,} | {r.transfer_read_cycles:,} + {r.transfer_commit_fence_cycles:,} "
            f"| {pw_jobs:,} | {r.pw_config_cycles:,} / {r.packed_weight_load_cycles:,} "
            f"| {r.pw_issue_drain_cycles:,} | {r.pw_service_cycles:,} "
            f"| {r.overlap_floor_cycles:,} | {r.overlap_service_cycles:,} | {r.serial_cycles:,} "
            f"| {r.tail_pixels} / {r.tail_fence_cycles:,} | {r.overlap_assumed} |"
        )
    lines += [
        "",
        "## Totals and interpretation",
        "",
        f"- True DS MACs: 497,664 DW + 4,194,304 PW = 4,691,968 MACs; the model does not reduce computation.",
        f"- Physical DW traffic: {total['dw_tokens']:,} tokens, {total['dw_stream4_writes']:,} stream4 writes, and {total['source_words']:,} source words.",
        f"- Packed PW load: {total['packed_weight_words']:,} 32-bit words; activation tokens: {total['pw_activation_tokens']:,}.",
        f"- Ideal double-bank overlap: {total['overlap_floor_cycles']:,} cycles; charging every scratch transfer: {total['overlap_service_cycles']:,}; serial comparison: {total['serial_cycles']:,}.",
        "- Overlap flag: yes, but only as a scheduler model (`max(DW service, PW service + transfer)`); no six-layer steady-state RTL measurement exists yet.",
        "- `source_fill_total_cycles` is fill work for all producer commands; DW total charges one 247/619-cycle warm-up fill because subsequent inactive-bank fills are assumed hidden behind DW issue/drain. This is an optimistic lower bound, not an independently measured six-layer schedule.",
        "- `pw_config_cycles=0` means no separate cycle is charged: the packed consumer captures job configuration on the one-cycle issue, and its measured `Cin+62` issue/drain term includes the fixed control/drain overhead.",
        f"- At {freq_mhz:g} MHz and {power_w:g} W, DS-only overlap+transfer is {total['overlap_service_cycles']/(freq_mhz*1000):.3f} ms and would correspond to {overlap_gopsw:.2f} GOPS/W if the full 5,136,896-MAC network finished in that many cycles.",
        "- The max(DW,PW) result is a scheduler assumption, not a proved RTL result. The existing real-producer overlap test proves only a local simultaneous window, not six-layer steady state.",
        "- Source bubbles, output backpressure, layer descriptors, runner fences, and tail-specific address handling add cycles beyond this no-backpressure service floor. The model therefore reports a lower/central estimate, not an acceptance claim.",
        "- DS6 is charged at fixed 4x8 geometry (four invalid columns masked); a future native 4x4 producer can reduce its source traffic, but that optimization is not silently credited here.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--csv", type=Path, default=None)
    parser.add_argument("--power-w", type=float, default=0.27)
    parser.add_argument("--freq-mhz", type=float, default=125.0)
    args = parser.parse_args()
    rows = [make_layer(s) for s in DW_SPECS]
    text = render(rows, args.power_w, args.freq_mhz)
    print(text, end="")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(asdict(rows[0]).keys()))
            writer.writeheader()
            writer.writerows(asdict(r) for r in rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
