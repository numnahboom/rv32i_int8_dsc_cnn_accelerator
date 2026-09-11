#!/usr/bin/env python3
"""Small deterministic capacity model for shared Stem+DS streaming.

This is deliberately a cycle-accounting model, not an RTL or Vivado model.
The six traffic ledgers are taken from the real C10 DS shape run.  The
macro-direct anchor is forced to the requested measured floor (108618 cycles)
and the streaming estimate retains 40% of the measured sweep residual, so a
bare max(DW,PW,output) lower bound is never reported as the estimate.
"""

from __future__ import annotations

import csv
import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "reports"

LAYERS = [
    # name, input H/W, Cin, Cout, stride, packed config, measured sweep,
    # real-producer traffic: DW beats, PW tokens, output one-word writes
    ("DS1", 32, 16, 32, 1, 308, 14946, 4096, 8192, 8192),
    ("DS2", 32, 32, 64, 2, 872, 12427, 2048, 8192, 4096),
    ("DS3", 16, 64, 64, 1, 1552, 20713, 4096, 16384, 4096),
    ("DS4", 16, 64, 128, 2, 2768, 10474, 1024, 8192, 2048),
    ("DS5", 8, 128, 128, 1, 5152, 18867, 2048, 16384, 2048),
    ("DS6", 8, 128, 256, 2, 9632, 9642, 1024, 8192, 1024),
]

NON_DS = 73233
FENCE = 883
STEM_OLD_WRITEBACK = 32770
STEM_SHARED_WRITEBACK = 4096
MACRO_DIRECT_FLOOR = 108618
RESIDUAL_KEEP = 0.40


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def make_rows() -> list[dict]:
    sweep_total = sum(row[6] for row in LAYERS)
    scale = MACRO_DIRECT_FLOOR / sweep_total
    macro_cycles_list = [round(row[6] * scale) for row in LAYERS]
    # Keep the per-layer ledger exactly anchored at the requested measured
    # baseline despite independent integer rounding.
    macro_cycles_list[-1] += MACRO_DIRECT_FLOOR - sum(macro_cycles_list)
    rows: list[dict] = []
    for i, (name, hw, cin, cout, stride, config, sweep, dw, pw, out) in enumerate(LAYERS):
        # Scale the six measured isolated-sweep values to the known macro
        # direct anchor, preserving each layer's observed shape weighting.
        macro_cycles = macro_cycles_list[i]
        dw_issue = ceil_div(dw, 16)
        pw_issue = ceil_div(pw, 64)
        output_issue = out  # one output word per cycle
        floor = max(dw_issue, pw_issue, output_issue)
        macro_residual = max(0, macro_cycles - floor)
        retained_control = math.ceil(RESIDUAL_KEEP * macro_residual)
        # One-cycle synchronous BRAM response: one startup and one drain
        # guard per layer.  No guard is shared between layers/inferences.
        bram_guard = 2
        peak_context = min(4, max(ceil_div(cin, 16), ceil_div(cout, 64)))
        context_guard = 8 * peak_context
        # A double config bank can hide later-layer loads under the preceding
        # layer.  The first layer has no prior compute window, so its packed
        # load is exposed.  Config demand is still listed for every layer.
        config_exposed = config if i == 0 else 0
        cycles = floor + retained_control + bram_guard + context_guard + config_exposed
        rows.append({
            "layer": name,
            "shape": f"{hw}x{hw}x{cin}->{ceil_div(hw, stride)}x{ceil_div(hw, stride)}x{cout}",
            "stride": stride,
            "cin": cin,
            "cout": cout,
            "packed_config": config,
            "measured_sweep_cycles": sweep,
            "macro_direct_calibrated_cycles": macro_cycles,
            "dw_beats": dw,
            "pw_tokens": pw,
            "output_words": out,
            "dw_issue_cycles": dw_issue,
            "pw_issue_cycles": pw_issue,
            "output_issue_cycles": output_issue,
            "stream_floor_cycles": floor,
            "retained_control_cycles": retained_control,
            "sync_bram_guard_cycles": bram_guard,
            "peak_context": peak_context,
            "context_guard_cycles": context_guard,
            "config_demand_cycles": config,
            "config_exposed_cycles": config_exposed,
            "stream_cycles": cycles,
            "dw_busy_pct": round(100.0 * dw_issue / cycles, 3),
            "pw_busy_pct": round(100.0 * pw_issue / cycles, 3),
            "output_busy_pct": round(100.0 * output_issue / cycles, 3),
            "config_demand_pct": round(100.0 * config / cycles, 3),
            "config_busy_pct": round(100.0 * config_exposed / cycles, 3),
        })
    return rows


def render_markdown(rows: list[dict], totals: dict) -> str:
    lines = [
        "# Full-layer shared Stem+DS streaming capacity model",
        "",
        "Deterministic read-only arithmetic model (2026-09-05); no RTL/Vivado was changed and no timing, power, logits, or full-top closure is claimed.",
        "",
        "## Inputs and conservative assumptions",
        "",
        "- Shapes and traffic are the six real C10 DS ledgers: DW beats `14336`, PW tokens `65536`, output words `21504`.",
        "- Packed configuration demand is exactly `308/872/1552/2768/5152/9632` per layer; all demand is listed, but only DS1's load is exposed because two banks hide later loads under the preceding layer. This is overlap, not cross-inference amortization.",
        "- Two config banks, four context slots, one-cycle synchronous BRAM, DW rate 16 beats/cycle, PW rate 64 tokens/cycle, and output rate one word/cycle.",
        "- Per-layer floor is `max(DW/16, PW/64, output_words)`. It is not the estimate: retain 40% of each layer's measured sweep residual after calibrating the sweep total to the macro-direct anchor `>=108618`; add two BRAM guard cycles and 8 cycles/context.",
        "- No residual, context, config, or fence cost is shared across layers or inferences. `config_demand` is traffic; `config_exposed` is the part on the critical path.",
        "",
        "## Per-layer result",
        "",
        "| layer | shape | cycles | config demand/exposed | peak ctx | DW/PW/out/cfg busy |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for r in rows:
        lines.append(
            f"| {r['layer']} | {r['shape']} s{r['stride']} | {r['stream_cycles']:,} | "
            f"{r['config_demand_cycles']:,}/{r['config_exposed_cycles']:,} | {r['peak_context']} | "
            f"{r['dw_busy_pct']:.1f}%/{r['pw_busy_pct']:.1f}%/{r['output_busy_pct']:.1f}%/{r['config_busy_pct']:.1f}% |"
        )
    lines += [
        "| **DS total** | — | **%s** | **%s/%s** | **%s max** | — |" % (
            f"{totals['ds_stream_cycles']:,}", f"{totals['config_demand_cycles']:,}",
            f"{totals['config_exposed_cycles']:,}", totals["peak_context"]),
        "",
        "## Network ledger and gates",
        "",
        "| scenario | cycles | gate | result |",
        "|---|---:|---:|---|",
        f"| calibrated macro-direct baseline (anchor) | {MACRO_DIRECT_FLOOR:,} | >=108,618 | PASS |",
        f"| shared DS stream total | {totals['ds_stream_cycles']:,} | <=85,000 | {'PASS' if totals['ds_stream_cycles'] <= 85000 else 'FAIL'} |",
        f"| full network: Stem old writeback 32,770 + nonDS/fence + DS | {totals['full_old_cycles']:,} | informational | {'PASS' if totals['full_old_cycles'] <= 130000 else 'FAIL'} |",
        f"| full network: Stem shared writeback 4,096 + nonDS/fence + DS | {totals['full_shared_cycles']:,} | <=130,000 | {'PASS' if totals['full_shared_cycles'] <= 130000 else 'FAIL'} |",
        "",
        "The shared-writeback scenario is the requested full-layer admission screen and is not passed by this conservative estimate. Even a passing arithmetic screen would not establish implementation feasibility; the stream ports, bank ownership/fences, timing, power, and exact full-network behavior still require RTL evidence.",
        "",
        "Reproduce with `python scripts/model_full_layer_stream_capacity_20260905.py`.",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rows = make_rows()
    totals = {
        "ds_stream_cycles": sum(r["stream_cycles"] for r in rows),
        "macro_direct_calibrated_cycles": sum(r["macro_direct_calibrated_cycles"] for r in rows),
        "stream_floor_cycles": sum(r["stream_floor_cycles"] for r in rows),
        "config_demand_cycles": sum(r["config_demand_cycles"] for r in rows),
        "config_exposed_cycles": sum(r["config_exposed_cycles"] for r in rows),
        "dw_beats": sum(r["dw_beats"] for r in rows),
        "pw_tokens": sum(r["pw_tokens"] for r in rows),
        "output_words": sum(r["output_words"] for r in rows),
        "peak_context": max(r["peak_context"] for r in rows),
    }
    totals["full_old_cycles"] = NON_DS + FENCE + STEM_OLD_WRITEBACK + totals["ds_stream_cycles"]
    totals["full_shared_cycles"] = NON_DS + FENCE + STEM_SHARED_WRITEBACK + totals["ds_stream_cycles"]
    payload = {
        "model": "full_layer_shared_stem_ds_stream_capacity",
        "date": "2026-09-05",
        "assumptions": {
            "non_ds_cycles": NON_DS,
            "fence_cycles": FENCE,
            "stem_old_writeback_cycles": STEM_OLD_WRITEBACK,
            "stem_shared_writeback_cycles": STEM_SHARED_WRITEBACK,
            "macro_direct_baseline_floor": MACRO_DIRECT_FLOOR,
            "config_words": [308, 872, 1552, 2768, 5152, 9632],
            "dw_rate_beats_per_cycle": 16,
            "pw_rate_tokens_per_cycle": 64,
            "output_rate_words_per_cycle": 1,
            "config_banks": 2,
            "contexts": 4,
            "bram_response_latency_cycles": 1,
            "retained_sweep_residual": RESIDUAL_KEEP,
            "no_cross_inference_amortization": True,
        },
        "totals": totals,
        "layers": rows,
        "gates": {
            "ds_le_85000": totals["ds_stream_cycles"] <= 85000,
            "shared_fullnet_le_130000": totals["full_shared_cycles"] <= 130000,
        },
        "decision": "NO_GO" if not (totals["ds_stream_cycles"] <= 85000 and totals["full_shared_cycles"] <= 130000) else "CONDITIONAL_GO",
    }
    json_path = OUT / "full_layer_stream_capacity_20260905.json"
    csv_path = OUT / "full_layer_stream_capacity_20260905.csv"
    md_path = OUT / "full_layer_stream_capacity_20260905.md"
    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    fields = list(rows[0])
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    md_path.write_text(render_markdown(rows, totals), encoding="utf-8")
    print(json.dumps({"json": str(json_path), "csv": str(csv_path), "md": str(md_path), "totals": totals}, separators=(",", ":")))


if __name__ == "__main__":
    main()
