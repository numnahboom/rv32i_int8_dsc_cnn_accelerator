#!/usr/bin/env python3
"""Build a software-vs-RTL inference accuracy and cycle report.

The hardware side is the Verilated cnn_top full-network SRAM smoke test. The
software side is the Python golden output embedded in the generated test vector.

The RV32I-only cycle estimate is intentionally explicit and configurable. The
default model is an optimistic scalar RV32I implementation without the M
extension: one int8 MAC costs 64 cycles, one requantized output costs 80 cycles,
and one GAP accumulation item costs 3 cycles.
"""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path


DS_SPECS = [
    (32, 32, 16, 32, 1),
    (32, 32, 32, 64, 2),
    (16, 16, 64, 64, 1),
    (16, 16, 64, 128, 2),
    (8, 8, 128, 128, 1),
    (8, 8, 128, 256, 2),
]

REQUIRED_METRIC_KEYS = {
    "case",
    "hw_cycles",
    "checks",
    "errors",
    "status",
    "mem_reads",
    "mem_writes",
    "desc_reads",
    "layer_reads",
    "layer_writes",
    "sram_reads",
    "sram_writes",
}

REQUIRED_LAYER_COLUMNS = {
    "case",
    "layer",
    "cycles",
    "mem_reads",
    "mem_writes",
    "sram_reads",
    "sram_writes",
}


def parse_hex_file(path: Path, bits: int = 8) -> list[int]:
    values: list[int] = []
    mask = (1 << bits) - 1
    sign = 1 << (bits - 1)
    with path.open("r", encoding="ascii") as f:
        for line_no, line in enumerate(f, start=1):
            token = line.split("#", 1)[0].strip()
            if not token:
                continue
            token = token.split()[0]
            if token.lower().startswith("0x"):
                token = token[2:]
            try:
                raw = int(token, 16) & mask
            except ValueError as exc:
                raise ValueError(f"{path}:{line_no}: invalid hex token {token!r}") from exc
            values.append(raw - (1 << bits) if raw & sign else raw)
    return values


def parse_metrics(path: Path) -> dict[str, int | str]:
    metrics: dict[str, int | str] = {}
    with path.open("r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            for item in line.split():
                if "=" not in item:
                    continue
                key, value = item.split("=", 1)
                if key == "status":
                    metrics[key] = value
                else:
                    metrics[key] = int(value, 0)
    missing = REQUIRED_METRIC_KEYS - metrics.keys()
    if missing:
        raise ValueError(f"{path}: missing required metrics: {sorted(missing)}")
    return metrics


def parse_layer_metrics(path: Path) -> dict[int, dict[str, int]]:
    if not path.exists():
        raise FileNotFoundError(f"required per-layer metrics not found: {path}")

    rows: dict[int, dict[str, int]] = {}
    cases: set[int] = set()
    with path.open("r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        missing = REQUIRED_LAYER_COLUMNS - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path}: missing required columns: {sorted(missing)}")
        for line_no, row in enumerate(reader, start=2):
            case = int(row["case"])
            layer = int(row["layer"])
            if layer in rows:
                raise ValueError(f"{path}:{line_no}: duplicate layer index {layer}")
            cases.add(case)
            rows[layer] = {
                "cycles": int(row["cycles"]),
                "mem_reads": int(row["mem_reads"]),
                "mem_writes": int(row["mem_writes"]),
                "sram_reads": int(row["sram_reads"]),
                "sram_writes": int(row["sram_writes"]),
            }
    if not rows:
        raise ValueError(f"{path}: per-layer metrics are empty")
    if len(cases) != 1:
        raise ValueError(f"{path}: expected one fullnet case, found cases={sorted(cases)}")
    return rows


def argmax(values: list[int]) -> int:
    if not values:
        raise ValueError("cannot argmax empty logits")
    best_idx = 0
    best_val = values[0]
    for idx, value in enumerate(values[1:], start=1):
        if value > best_val:
            best_idx = idx
            best_val = value
    return best_idx


def network_operation_counts() -> tuple[list[dict[str, int | str]], dict[str, int]]:
    rows: list[dict[str, int | str]] = []

    stem_macs = 32 * 32 * 16 * 3 * 3 * 3
    stem_outputs = 32 * 32 * 16
    rows.append(
        {
            "layer_idx": 0,
            "layer": "Stem Conv3x3",
            "stem_macs": stem_macs,
            "dw_macs": 0,
            "pw_macs": 0,
            "fc_macs": 0,
            "requant_outputs": stem_outputs,
            "gap_adds": 0,
            "pw_min_issue_cycles": 0,
        }
    )

    for idx, (in_h, in_w, in_c, out_c, stride) in enumerate(DS_SPECS, start=1):
        out_h = (in_h + stride - 1) // stride
        out_w = (in_w + stride - 1) // stride
        dw_macs = out_h * out_w * in_c * 9
        pw_macs = out_h * out_w * out_c * in_c
        pw_min_issue_cycles = math.ceil((out_h * out_w) / 8) * math.ceil(out_c / 8) * in_c
        rows.append(
            {
                "layer_idx": idx,
                "layer": f"DSBlock{idx}",
                "stem_macs": 0,
                "dw_macs": dw_macs,
                "pw_macs": pw_macs,
                "fc_macs": 0,
                "requant_outputs": out_h * out_w * (in_c + out_c),
                "gap_adds": 0,
                "pw_min_issue_cycles": pw_min_issue_cycles,
            }
        )

    gap_adds = 4 * 4 * 256
    rows.append(
        {
            "layer_idx": 7,
            "layer": "GAP",
            "stem_macs": 0,
            "dw_macs": 0,
            "pw_macs": 0,
            "fc_macs": 0,
            "requant_outputs": 0,
            "gap_adds": gap_adds,
            "pw_min_issue_cycles": 0,
        }
    )

    fc_macs = 10 * 256
    rows.append(
        {
            "layer_idx": 8,
            "layer": "FC",
            "stem_macs": 0,
            "dw_macs": 0,
            "pw_macs": 0,
            "fc_macs": fc_macs,
            "requant_outputs": 10,
            "gap_adds": 0,
            "pw_min_issue_cycles": 0,
        }
    )

    totals = {
        "stem_macs": sum(int(row["stem_macs"]) for row in rows),
        "dw_macs": sum(int(row["dw_macs"]) for row in rows),
        "pw_macs": sum(int(row["pw_macs"]) for row in rows),
        "fc_macs": sum(int(row["fc_macs"]) for row in rows),
        "requant_outputs": sum(int(row["requant_outputs"]) for row in rows),
        "gap_adds": sum(int(row["gap_adds"]) for row in rows),
        "pw_min_issue_cycles": sum(int(row["pw_min_issue_cycles"]) for row in rows),
    }
    totals["total_macs"] = (
        totals["stem_macs"] + totals["dw_macs"] + totals["pw_macs"] + totals["fc_macs"]
    )
    return rows, totals


def make_report(args: argparse.Namespace) -> str:
    metrics = parse_metrics(args.hw_metrics)
    layer_metrics = parse_layer_metrics(args.layer_metrics)
    expected = parse_hex_file(args.expected_logits, 8)
    actual = parse_hex_file(args.hw_logits, 8)
    rows, totals = network_operation_counts()

    if int(metrics.get("errors", 0)) != 0:
        raise ValueError(f"hardware metrics report errors={metrics['errors']}")

    status = int(str(metrics["status"]), 16)
    if (status & 0x7) != 0x2:
        raise ValueError(
            "hardware status is not cleanly done: "
            f"status=0x{status:08x} busy={status & 1} done={(status >> 1) & 1} "
            f"error={(status >> 2) & 1}"
        )

    if len(expected) != len(actual):
        raise ValueError(f"logit length mismatch expected={len(expected)} actual={len(actual)}")
    if not expected:
        raise ValueError("logit files are empty")
    if "checks" in metrics and int(metrics["checks"]) != len(expected):
        raise ValueError(
            f"hardware check count mismatch metrics={metrics['checks']} logits={len(expected)}"
        )

    diffs = [abs(a - b) for a, b in zip(actual, expected)]
    exact = sum(1 for diff in diffs if diff == 0)
    mismatches = len(diffs) - exact
    if mismatches:
        raise ValueError(
            f"hardware logits are not bit-exact: mismatches={mismatches} max_abs_diff={max(diffs)}"
        )
    max_abs_diff = max(diffs) if diffs else 0
    mean_abs_diff = sum(diffs) / len(diffs) if diffs else 0.0
    rmse = math.sqrt(sum(diff * diff for diff in diffs) / len(diffs)) if diffs else 0.0
    expected_top1 = argmax(expected)
    actual_top1 = argmax(actual)

    cpu_cycles = (
        totals["total_macs"] * args.cycles_per_mac
        + totals["requant_outputs"] * args.cycles_per_requant
        + totals["gap_adds"] * args.cycles_per_gap_add
    )
    cpu_ideal_lower_bound = totals["total_macs"] + totals["requant_outputs"] + totals["gap_adds"]
    hw_cycles = int(metrics["hw_cycles"])
    if hw_cycles <= 0:
        raise ValueError(f"invalid hardware cycle count: {hw_cycles}")
    if ((status >> 8) & 0x00FF_FFFF) != hw_cycles:
        raise ValueError(
            "status/metric cycle mismatch: "
            f"status_cycles={(status >> 8) & 0x00FF_FFFF} metrics={hw_cycles}"
        )
    if args.max_hw_cycles > 0 and hw_cycles > args.max_hw_cycles:
        raise ValueError(
            f"hardware cycle budget exceeded: actual={hw_cycles} max={args.max_hw_cycles}"
        )
    layer_cycle_sum = sum(item["cycles"] for item in layer_metrics.values())
    if layer_metrics:
        expected_layers = set(range(len(rows)))
        actual_layers = set(layer_metrics)
        if actual_layers != expected_layers:
            raise ValueError(
                f"layer metrics indices mismatch expected={sorted(expected_layers)} "
                f"actual={sorted(actual_layers)}"
            )
        if layer_cycle_sum > hw_cycles:
            raise ValueError(
                f"layer cycles exceed full inference: layers={layer_cycle_sum} full={hw_cycles}"
            )
        layer_mem_read_sum = sum(item["mem_reads"] for item in layer_metrics.values())
        layer_mem_write_sum = sum(item["mem_writes"] for item in layer_metrics.values())
        layer_sram_read_sum = sum(item["sram_reads"] for item in layer_metrics.values())
        layer_sram_write_sum = sum(item["sram_writes"] for item in layer_metrics.values())
        if layer_mem_read_sum != int(metrics["layer_reads"]):
            raise ValueError(
                "layer/full external read mismatch: "
                f"layers={layer_mem_read_sum} full={metrics['layer_reads']}"
            )
        if layer_mem_write_sum != int(metrics["layer_writes"]):
            raise ValueError(
                "layer/full external write mismatch: "
                f"layers={layer_mem_write_sum} full={metrics['layer_writes']}"
            )
        if layer_sram_read_sum != int(metrics["sram_reads"]):
            raise ValueError(
                "layer/full SRAM read mismatch: "
                f"layers={layer_sram_read_sum} full={metrics['sram_reads']}"
            )
        if layer_sram_write_sum != int(metrics["sram_writes"]):
            raise ValueError(
                "layer/full SRAM write mismatch: "
                f"layers={layer_sram_write_sum} full={metrics['sram_writes']}"
            )
        if int(metrics["mem_reads"]) != (
            int(metrics["desc_reads"]) + int(metrics["layer_reads"])
        ):
            raise ValueError(
                "external read accounting mismatch: "
                f"all={metrics['mem_reads']} descriptors={metrics['desc_reads']} "
                f"layers={metrics['layer_reads']}"
            )
        if int(metrics["mem_writes"]) != int(metrics["layer_writes"]):
            raise ValueError(
                "external write accounting mismatch: "
                f"all={metrics['mem_writes']} layers={metrics['layer_writes']}"
            )
        allowed_overhead = max(10_000, hw_cycles // 100)
        if (hw_cycles - layer_cycle_sum) > allowed_overhead:
            raise ValueError(
                f"layer/full cycle gap too large: layers={layer_cycle_sum} full={hw_cycles}"
            )
        stem_min_cycles = math.ceil(totals["stem_macs"] / args.stem_mac_lanes)
        if layer_metrics[0]["cycles"] < stem_min_cycles:
            raise ValueError(
                "stem layer cycles violate MAC-lane lower bound: "
                f"cycles={layer_metrics[0]['cycles']} minimum={stem_min_cycles}"
            )
        for row in rows:
            layer_idx = int(row["layer_idx"])
            pw_min_issue = int(row["pw_min_issue_cycles"])
            if layer_metrics[layer_idx]["cycles"] < pw_min_issue:
                raise ValueError(
                    "layer cycles violate PW theoretical issue lower bound: "
                    f"layer={layer_idx} cycles={layer_metrics[layer_idx]['cycles']} "
                    f"minimum={pw_min_issue}"
                )
    speedup = cpu_cycles / hw_cycles if hw_cycles else 0.0
    ideal_speedup = cpu_ideal_lower_bound / hw_cycles if hw_cycles else 0.0
    aggregate_macs_per_cycle = totals["total_macs"] / hw_cycles if hw_cycles else 0.0

    lines: list[str] = []
    lines.append("# Inference Accuracy and Cycle Report")
    lines.append("")
    lines.append("## Accuracy")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("| --- | ---: |")
    lines.append(f"| Logits compared | {len(expected)} |")
    lines.append(f"| Exact element matches | {exact} |")
    lines.append(f"| Mismatches | {mismatches} |")
    lines.append(f"| Exact element accuracy | {100.0 * exact / len(expected):.2f}% |")
    lines.append(f"| Max absolute diff | {max_abs_diff} |")
    lines.append(f"| Mean absolute diff | {mean_abs_diff:.4f} |")
    lines.append(f"| RMSE | {rmse:.4f} |")
    lines.append(f"| Software golden argmax | {expected_top1} |")
    lines.append(f"| Hardware RTL argmax | {actual_top1} |")
    lines.append(f"| Argmax match | {'yes' if expected_top1 == actual_top1 else 'no'} |")
    lines.append("")
    lines.append("Software golden logits:")
    lines.append("")
    lines.append("```text")
    lines.append(" ".join(str(v) for v in expected))
    lines.append("```")
    lines.append("")
    lines.append("Hardware RTL logits:")
    lines.append("")
    lines.append("```text")
    lines.append(" ".join(str(v) for v in actual))
    lines.append("```")
    lines.append("")
    lines.append("## Cycle Estimate")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("| --- | ---: |")
    lines.append(f"| Hardware RTL full inference | {hw_cycles} |")
    if args.max_hw_cycles > 0:
        lines.append(f"| Regression cycle ceiling | {args.max_hw_cycles} |")
    if layer_metrics:
        lines.append(f"| Sum of per-layer cycles | {layer_cycle_sum} |")
        lines.append(f"| Network control/descriptor overhead | {hw_cycles - layer_cycle_sum} |")
    lines.append(f"| RV32I-only theoretical estimate | {cpu_cycles} |")
    lines.append(f"| RV32I ideal 1-op lower bound | {cpu_ideal_lower_bound} |")
    if "mem_reads" in metrics:
        lines.append(f"| External memory reads | {int(metrics['mem_reads'])} |")
    if "mem_writes" in metrics:
        lines.append(f"| External memory writes | {int(metrics['mem_writes'])} |")
    if "desc_reads" in metrics:
        lines.append(f"| Descriptor reads | {int(metrics['desc_reads'])} |")
    if "sram_reads" in metrics:
        lines.append(f"| Feature SRAM reads | {int(metrics['sram_reads'])} |")
    if "sram_writes" in metrics:
        lines.append(f"| Feature SRAM writes | {int(metrics['sram_writes'])} |")
    lines.append("")
    lines.append("| Comparison | Value |")
    lines.append("| --- | ---: |")
    lines.append(f"| Estimated RV32I / RTL speedup | {speedup:.2f}x |")
    lines.append(f"| Ideal lower-bound / RTL ratio | {ideal_speedup:.2f}x |")
    lines.append(f"| Aggregate network MACs / RTL cycle | {aggregate_macs_per_cycle:.3f} |")
    lines.append("")
    lines.append("Default RV32I model:")
    lines.append("")
    lines.append("```text")
    lines.append(f"cycles_per_mac={args.cycles_per_mac}")
    lines.append(f"cycles_per_requant={args.cycles_per_requant}")
    lines.append(f"cycles_per_gap_add={args.cycles_per_gap_add}")
    lines.append(f"stem_mac_lanes={args.stem_mac_lanes}")
    lines.append("single-cycle memory and no pipeline stalls are assumed")
    lines.append("```")
    lines.append("")
    if layer_metrics:
        lines.append("## Per-Layer Hardware Metrics")
        lines.append("")
        lines.append(
            "| Layer | HW cycles | Ext reads | Ext writes | SRAM reads | SRAM writes | PW theoretical minimum issue cycles | Minimum-issue/layer ratio |"
        )
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for row in rows:
            layer_idx = int(row["layer_idx"])
            hw = layer_metrics.get(layer_idx, {"cycles": 0, "mem_reads": 0, "mem_writes": 0})
            pw_min_issue = int(row["pw_min_issue_cycles"])
            issue_ratio = (100.0 * pw_min_issue / hw["cycles"]) if hw["cycles"] else 0.0
            lines.append(
                f"| {row['layer']} | {hw['cycles']} | {hw['mem_reads']} | "
                f"{hw['mem_writes']} | {hw['sram_reads']} | {hw['sram_writes']} | "
                f"{pw_min_issue} | {issue_ratio:.2f}% |"
            )
        lines.append("")
    lines.append("## Operation Counts")
    lines.append("")
    lines.append("| Layer | Stem MAC | DW MAC | PW MAC | FC MAC | Requant outputs | GAP adds |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in rows:
        lines.append(
            "| {layer} | {stem_macs} | {dw_macs} | {pw_macs} | {fc_macs} | "
            "{requant_outputs} | {gap_adds} |".format(**row)
        )
    lines.append(
        f"| Total | {totals['stem_macs']} | {totals['dw_macs']} | "
        f"{totals['pw_macs']} | {totals['fc_macs']} | "
        f"{totals['requant_outputs']} | {totals['gap_adds']} |"
    )
    lines.append("")
    lines.append(f"Total MACs: {totals['total_macs']}")
    lines.append("")
    lines.append("## Source Files")
    lines.append("")
    lines.append(f"- Hardware metrics: `{args.hw_metrics}`")
    lines.append(f"- Per-layer metrics: `{args.layer_metrics}`")
    lines.append(f"- Software golden logits: `{args.expected_logits}`")
    lines.append(f"- Hardware logits: `{args.hw_logits}`")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hw-metrics",
        type=Path,
        default=Path("build/reports/tb_cnn_top_fullnet_sram_datapath_metrics.txt"),
    )
    parser.add_argument(
        "--expected-logits",
        type=Path,
        default=Path("build/reports/fullnet_expected_logits.hex"),
    )
    parser.add_argument(
        "--layer-metrics",
        type=Path,
        default=Path("build/reports/fullnet_layer_metrics.csv"),
    )
    parser.add_argument(
        "--hw-logits",
        type=Path,
        default=Path("build/reports/fullnet_hw_logits.hex"),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("build/reports/inference_accuracy_perf.md"),
    )
    parser.add_argument("--cycles-per-mac", type=int, default=64)
    parser.add_argument("--cycles-per-requant", type=int, default=80)
    parser.add_argument("--cycles-per-gap-add", type=int, default=3)
    parser.add_argument("--stem-mac-lanes", type=int, default=3)
    parser.add_argument(
        "--max-hw-cycles",
        type=int,
        # The bit-exact Stem and FC pipeline drains raise the measured fullnet
        # latency from 944,568 to 960,953 cycles.  Keep a finite regression
        # guard with enough headroom for those intentional stages.
        default=1_000_000,
        help="fail if fullnet exceeds this deterministic cycle budget; use 0 to disable",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = make_report(args)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report, encoding="utf-8")

    metrics = parse_metrics(args.hw_metrics)
    _, totals = network_operation_counts()
    cpu_cycles = (
        totals["total_macs"] * args.cycles_per_mac
        + totals["requant_outputs"] * args.cycles_per_requant
        + totals["gap_adds"] * args.cycles_per_gap_add
    )
    speedup = cpu_cycles / int(metrics["hw_cycles"])
    print(f"wrote {args.out}")
    print(
        "SUMMARY hw_cycles={hw} rv32i_est_cycles={cpu} speedup={speedup:.2f}x "
        "total_macs={macs} mem_reads={reads} mem_writes={writes}".format(
            hw=int(metrics["hw_cycles"]),
            cpu=cpu_cycles,
            speedup=speedup,
            macs=totals["total_macs"],
            reads=int(metrics.get("mem_reads", 0)),
            writes=int(metrics.get("mem_writes", 0)),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
