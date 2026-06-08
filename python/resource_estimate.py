#!/usr/bin/env python3
"""Static resource estimate for the v1 CNN accelerator RTL.

This report is intentionally not a replacement for FPGA synthesis. It captures
the architectural resource footprint implied by RTL parameters and highlights
which packed buffers should be forced into SRAM/BRAM in a production pass.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path


BRAM36_BITS = 36 * 1024


@dataclass(frozen=True)
class MemoryItem:
    name: str
    bytes: int
    kind: str
    implementation: str
    note: str

    @property
    def bits(self) -> int:
        return self.bytes * 8

    @property
    def bram36(self) -> int:
        return math.ceil(self.bits / BRAM36_BITS)


@dataclass(frozen=True)
class ArithmeticItem:
    name: str
    count: int
    kind: str
    conservative_dsp: int
    note: str


def memory_items() -> list[MemoryItem]:
    return [
        MemoryItem("Feature SRAM A", 32 * 1024, "activation", "BRAM/SRAM intended", "1RW bank"),
        MemoryItem("Feature SRAM B", 32 * 1024, "activation", "BRAM/SRAM intended", "1RW bank"),
        MemoryItem("DW tile buffer", 64 * 128, "activation", "banked BRAM/LUTRAM intended", "16 channel banks, 512 B each"),
        MemoryItem("Runner DS input tile", 17 * 17 * 128, "activation", "packed reg today", "largest halo tile"),
        MemoryItem("Runner PW weight cache", 256 * 128, "weight", "packed reg today", "max full PW layer cache"),
        MemoryItem("Runner output tile buffer", 64 * 256, "activation", "reg array today", "8x8 spatial tile x max Cout"),
        MemoryItem("Runner GAP feature", 4 * 4 * 256, "activation", "packed reg today", "GAP input staging"),
        MemoryItem("Runner FC weight", 10 * 256, "weight", "packed reg today", "FC weight staging"),
        MemoryItem("Runner FC input vector", 256, "activation", "packed reg today", "GAP output / FC input"),
        MemoryItem("Stem input tile", 10 * 10 * 3, "activation", "packed reg today", "stem tiled halo buffer"),
        MemoryItem("Stem weight", 16 * 27, "weight", "packed reg today", "3x3x3x16"),
        MemoryItem("DW weight", 128 * 9, "weight", "packed reg today", "max depthwise layer"),
        MemoryItem("Stem qparams", 16 * 4 * 2 + 16, "quant", "packed reg today", "bias/mul/shift"),
        MemoryItem("DW qparams", 128 * 4 * 2 + 128, "quant", "packed reg today", "bias/mul/shift"),
        MemoryItem("PW qparams", 256 * 4 * 2 + 256, "quant", "packed reg today", "bias/mul/shift"),
        MemoryItem("FC qparams", 10 * 4 * 2 + 10, "quant", "packed reg today", "bias/mul/shift"),
    ]


def arithmetic_items() -> list[ArithmeticItem]:
    return [
        ArithmeticItem(
            "PW systolic array",
            64,
            "int8xint8 MAC",
            64,
            "8x8 PEs, conservative one DSP per PE before packing",
        ),
        ArithmeticItem(
            "DW MAC lanes",
            16 * 3,
            "int8xint8 multiply",
            48,
            "16 lanes x 3 multipliers per row cycle",
        ),
        ArithmeticItem(
            "Stem serial MAC",
            1,
            "int8xint8 multiply",
            1,
            "serial/small-parallel stem engine path",
        ),
        ArithmeticItem(
            "FC serial MAC",
            1,
            "int8xint8 multiply",
            1,
            "simple FC engine path",
        ),
        ArithmeticItem(
            "Module-local requant multipliers",
            4,
            "wide signed multiply",
            64,
            "stem, DW, PW writeback, FC; current RTL uses 64x64-style expression, conservatively 16 DSP each",
        ),
    ]


def format_bytes(value: int) -> str:
    if value >= 1024:
        return f"{value / 1024:.1f} KiB"
    return f"{value} B"


def make_report() -> str:
    memories = memory_items()
    arith = arithmetic_items()

    total_bits = sum(item.bits for item in memories)
    total_bytes = sum(item.bytes for item in memories)
    bram_individual = sum(item.bram36 for item in memories)
    bram_packed_lower_bound = math.ceil(total_bits / BRAM36_BITS)
    intended_bram_items = [item for item in memories if "BRAM" in item.implementation or "SRAM" in item.implementation]
    intended_bram36 = sum(item.bram36 for item in intended_bram_items)

    packed_reg_items = [item for item in memories if "reg" in item.implementation]
    packed_reg_bits = sum(item.bits for item in packed_reg_items)

    int8_mults = sum(item.count for item in arith if "int8" in item.kind)
    wide_mults = sum(item.count for item in arith if "wide" in item.kind)
    conservative_dsp = sum(item.conservative_dsp for item in arith)

    lines: list[str] = []
    lines.append("# Static Resource Estimate")
    lines.append("")
    lines.append("This is a static RTL-parameter estimate, not a post-synthesis report.")
    lines.append("Use it to track resource scale and synthesis risk before running an FPGA tool.")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | Estimate |")
    lines.append("| --- | ---: |")
    lines.append(f"| Total modeled local storage | {format_bytes(total_bytes)} |")
    lines.append(f"| Total modeled local storage bits | {total_bits} |")
    lines.append(f"| BRAM36 lower bound if perfectly packed | {bram_packed_lower_bound} |")
    lines.append(f"| BRAM36 estimate if each buffer is separate | {bram_individual} |")
    lines.append(f"| Intended SRAM/BRAM buffers only | {intended_bram36} BRAM36 |")
    lines.append(f"| Packed-reg storage risk | {packed_reg_bits} FF bits if not memory-inferred |")
    lines.append(f"| Logical int8 multipliers | {int8_mults} |")
    lines.append(f"| Wide requant multipliers | {wide_mults} |")
    lines.append(f"| Conservative DSP risk estimate | {conservative_dsp} DSPs |")
    lines.append("")
    lines.append("## Memory Footprint")
    lines.append("")
    lines.append("| Block | Kind | Bytes | Bits | BRAM36 | Current implementation | Note |")
    lines.append("| --- | --- | ---: | ---: | ---: | --- | --- |")
    for item in memories:
        lines.append(
            f"| {item.name} | {item.kind} | {item.bytes} | {item.bits} | "
            f"{item.bram36} | {item.implementation} | {item.note} |"
        )
    lines.append("")
    lines.append("## Arithmetic Footprint")
    lines.append("")
    lines.append("| Block | Count | Kind | Conservative DSP | Note |")
    lines.append("| --- | ---: | --- | ---: | --- |")
    for item in arith:
        lines.append(
            f"| {item.name} | {item.count} | {item.kind} | "
            f"{item.conservative_dsp} | {item.note} |"
        )
    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append("- Feature SRAM A/B is the main intentional on-chip SRAM cost: 64 KiB, about 16 BRAM36.")
    lines.append("- The largest synthesis risk is not the feature SRAM; it is packed-reg staging in `cnn_layer_runner.v`.")
    lines.append("- If those packed buffers do not infer memory, they can turn into roughly "
                 f"{packed_reg_bits} FF bits plus routing/LUT overhead.")
    lines.append("- Current wide requant expressions are counted conservatively because the RTL uses 64-bit operands.")
    lines.append("- A real Vivado/Yosys report is still required for final LUT, FF, BRAM, DSP numbers.")
    lines.append("")
    lines.append("## Optimization Targets Kept On Hold")
    lines.append("")
    lines.append("Per the current project direction, this report records but does not modify:")
    lines.append("")
    lines.append("- width reduction / pipelining of requant multipliers")
    lines.append("- vendor-specific BRAM mapping pragmas for the banked DW tile buffer")
    lines.append("- PW weight tile cache reduction")
    lines.append("- channel-tiled DS input buffering")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/reports/resource_estimate.md"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = make_report()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report, encoding="utf-8")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
