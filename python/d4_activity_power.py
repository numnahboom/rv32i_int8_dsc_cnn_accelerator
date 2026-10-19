#!/usr/bin/env python3
"""Convert a scoped D4 simulation VCD to SAIF without loading the VCD in memory."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


PORT_NAMES = frozenset(
    {
        "clk",
        "rst_n",
        "start_valid",
        "start_ready",
        "input_valid",
        "input_ready",
        "input_data",
        "logit_valid",
        "logit_ready",
        "logit_index",
        "logit_acc",
        "done_valid",
        "done_ready",
        "busy",
        "error",
        "cycle_count",
        "semantic_mac_count",
        "trace_valid",
        "trace_op",
        "trace_index",
        "trace_data",
    }
)
TIME_UNITS = {"s", "ms", "us", "ns", "ps", "fs"}
SAIF_SAFE_ATOM = re.compile(r"^[A-Za-z_][A-Za-z0-9_$\[\]:-]*$")


class VcdError(ValueError):
    """Raised when the input VCD is malformed or outside the supported subset."""


@dataclass(frozen=True)
class Declaration:
    code: str
    width: int
    scope: tuple[str, ...]
    name: str
    indices: tuple[int, ...] | None
    kind: str


@dataclass
class Activity:
    width: int
    states: list[str] = field(init=False)
    # Per bit: T0, T1, TX, TZ, TC.
    counts: list[list[int]] = field(init=False)
    last_tick: int = 0

    def __post_init__(self) -> None:
        self.states = ["x"] * self.width
        self.counts = [[0, 0, 0, 0, 0] for _ in range(self.width)]

    def update(self, value: str, tick: int, code: str, line_number: int) -> None:
        if tick < self.last_tick:
            raise VcdError(
                f"line {line_number}: time moved backward for VCD identifier {code!r}"
            )
        if len(value) != self.width:
            raise VcdError(
                f"line {line_number}: identifier {code!r} has width {len(value)}, "
                f"expected {self.width}"
            )
        elapsed = tick - self.last_tick
        for bit, old in enumerate(self.states):
            if old == "0":
                self.counts[bit][0] += elapsed
            elif old == "1":
                self.counts[bit][1] += elapsed
            elif old == "x":
                self.counts[bit][2] += elapsed
            else:
                self.counts[bit][3] += elapsed
        for bit, new in enumerate(value):
            old = self.states[bit]
            if old in "01" and new in "01" and old != new:
                self.counts[bit][4] += 1
        self.states = list(value)
        self.last_tick = tick

    def finish(self, duration: int, code: str) -> None:
        if duration < self.last_tick:
            raise VcdError(
                f"duration {duration} precedes last event for VCD identifier {code!r}"
            )
        elapsed = duration - self.last_tick
        for bit, state in enumerate(self.states):
            index = {"0": 0, "1": 1, "x": 2, "z": 3}[state]
            self.counts[bit][index] += elapsed
        self.last_tick = duration


@dataclass
class ParsedVcd:
    declarations: list[Declaration]
    activity_by_code: dict[str, Activity]
    timescale_multiplier: int
    timescale_unit: str
    final_tick: int
    vcd_sha256: str


@dataclass
class SaifNode:
    instances: dict[str, "SaifNode"] = field(default_factory=dict)
    signals: list[tuple[str, str, list[int]]] = field(default_factory=list)


def _unescape_vcd_identifier(token: str) -> str:
    # A leading backslash marks a VCD escaped identifier; its terminating
    # whitespace is not part of the identifier.
    return token[1:] if token.startswith("\\") else token


def _scope_prefix(arg: str, field_name: str) -> tuple[str, ...]:
    parts = tuple(_unescape_vcd_identifier(part) for part in arg.split("."))
    if not parts or any(not part for part in parts):
        raise ValueError(f"{field_name} must be a dot-separated non-empty scope path")
    return parts


def _parse_timescale(line: str, line_number: int) -> tuple[int, str]:
    match = re.fullmatch(r"\$timescale\s+(\d+)\s*([A-Za-z]+)\s+\$end", line)
    if not match:
        raise VcdError(
            f"line {line_number}: unsupported $timescale declaration {line!r}; "
            "expected a single-line '$timescale <integer> <unit> $end'"
        )
    multiplier, unit = int(match.group(1)), match.group(2).lower()
    if multiplier <= 0 or unit not in TIME_UNITS:
        raise VcdError(f"line {line_number}: invalid VCD timescale {multiplier} {unit}")
    return multiplier, unit


def _parse_var(line: str, scopes: tuple[str, ...], line_number: int) -> Declaration:
    match = re.fullmatch(r"\$var\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+?)\s+\$end", line)
    if not match:
        raise VcdError(
            f"line {line_number}: unsupported $var declaration; expected one-line VCD $var"
        )
    kind, width_text, code, tail = match.groups()
    width = int(width_text)
    if width <= 0:
        raise VcdError(f"line {line_number}: VCD variable width must be positive")
    if kind.lower() in {"real", "realtime", "string"}:
        raise VcdError(
            f"line {line_number}: unsupported VCD variable kind {kind!r}; "
            "SAIF activity requires four-state logic variables"
        )
    parts = tail.split()
    if len(parts) not in (1, 2):
        raise VcdError(f"line {line_number}: unsupported escaped $var reference {tail!r}")
    name = _unescape_vcd_identifier(parts[0])
    indices: tuple[int, ...] | None = None
    if len(parts) == 2:
        range_match = re.fullmatch(r"\[(-?\d+):(-?\d+)\]", parts[1])
        if not range_match:
            raise VcdError(f"line {line_number}: unsupported VCD range {parts[1]!r}")
        left, right = map(int, range_match.groups())
        step = -1 if left >= right else 1
        indices = tuple(range(left, right + step, step))
        if len(indices) != width:
            raise VcdError(
                f"line {line_number}: declared range {parts[1]} has {len(indices)} bits, "
                f"but $var width is {width}"
            )
    elif width != 1:
        # VCD permits a vector reference without an explicit range. Use its
        # conventional [width-1:0] indices for SAIF bit names.
        indices = tuple(range(width - 1, -1, -1))
    return Declaration(code, width, scopes, name, indices, kind.lower())


def _parse_value(line: str, line_number: int) -> tuple[str, str]:
    text = line.strip()
    if not text:
        raise VcdError(f"line {line_number}: empty value change")
    marker = text[0].lower()
    if marker in "01xz":
        code = text[1:].strip()
        if not code:
            raise VcdError(f"line {line_number}: scalar value has no identifier code")
        return marker, code
    if marker in "br" or marker == "s":
        parts = text.split()
        if len(parts) != 2:
            raise VcdError(f"line {line_number}: malformed vector/real/string change {text!r}")
        if marker == "b":
            return parts[0][1:].lower(), parts[1]
        kind = "real" if marker == "r" else "string"
        raise VcdError(
            f"line {line_number}: unsupported VCD {kind} value; only four-state logic is supported"
        )
    if marker == "p":
        raise VcdError(
            f"line {line_number}: unsupported VCD strength value; SAIF conversion needs resolved logic"
        )
    raise VcdError(f"line {line_number}: unsupported VCD value change {text!r}")


def parse_vcd(
    vcd_path: Path,
    vcd_root: tuple[str, ...],
    duration_ticks: int | None = None,
) -> ParsedVcd:
    declarations: list[Declaration] = []
    trackers: dict[str, Activity] = {}
    scope_stack: list[str] = []
    current_tick = 0
    final_tick = 0
    timescale: tuple[int, str] | None = None
    in_definitions = True
    saw_enddefinitions = False
    skipped_block: str | None = None
    included_var_count = 0
    digest = hashlib.sha256()

    with vcd_path.open("rb") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            digest.update(raw_line)
            try:
                line = raw_line.decode("ascii").strip()
            except UnicodeDecodeError as exc:
                raise VcdError(f"line {line_number}: VCD is not ASCII text") from exc
            if not line:
                continue
            if in_definitions:
                if skipped_block:
                    if "$end" in line:
                        skipped_block = None
                    continue
                if line.startswith("$scope"):
                    match = re.fullmatch(r"\$scope\s+\S+\s+(\S+)\s+\$end", line)
                    if not match:
                        raise VcdError(f"line {line_number}: malformed or multiline $scope")
                    scope_stack.append(_unescape_vcd_identifier(match.group(1)))
                elif line.startswith("$upscope"):
                    if not scope_stack:
                        raise VcdError(f"line {line_number}: $upscope without matching $scope")
                    scope_stack.pop()
                elif line.startswith("$timescale"):
                    if timescale is not None:
                        raise VcdError(f"line {line_number}: duplicate $timescale")
                    timescale = _parse_timescale(line, line_number)
                elif line.startswith("$var"):
                    declaration = _parse_var(line, tuple(scope_stack), line_number)
                    if declaration.scope[: len(vcd_root)] == vcd_root:
                        declarations.append(declaration)
                        included_var_count += 1
                        previous = trackers.get(declaration.code)
                        if previous is None:
                            trackers[declaration.code] = Activity(declaration.width)
                        elif previous.width != declaration.width:
                            raise VcdError(
                                f"line {line_number}: aliased identifier {declaration.code!r} "
                                "has inconsistent widths"
                            )
                elif line.startswith("$enddefinitions"):
                    if "$end" not in line:
                        raise VcdError(f"line {line_number}: malformed $enddefinitions")
                    in_definitions = False
                    saw_enddefinitions = True
                elif line.startswith("$") and "$end" not in line:
                    # Date, version, and comment records do not affect logic
                    # activity. Skip their body until their closing marker.
                    skipped_block = line.split(None, 1)[0]
                continue

            if line.startswith("#"):
                tick_text = line[1:].strip()
                if not tick_text.isdigit():
                    raise VcdError(f"line {line_number}: malformed timestamp {line!r}")
                tick = int(tick_text)
                if tick < current_tick:
                    raise VcdError(f"line {line_number}: VCD timestamps moved backward")
                current_tick = tick
                final_tick = tick
                continue
            if line.startswith("$"):
                command = line.split(None, 1)[0]
                if command in {"$end", "$dumpvars", "$dumpall", "$dumpon", "$dumpoff"}:
                    continue
                if command in {"$comment", "$date", "$version"} and "$end" not in line:
                    skipped_block = command
                    continue
                # Standard annotations outside logic changes do not affect
                # the SAIF activity; unknown command families fail clearly.
                if command in {"$dumpflush", "$enddefinitions"}:
                    continue
                raise VcdError(f"line {line_number}: unsupported VCD command {command!r}")
            value, code = _parse_value(line, line_number)
            activity = trackers.get(code)
            if activity is None:
                # Signals outside the selected design scope are deliberately
                # ignored. Their identifiers can share a code with an alias
                # inside the selected scope, which is tracked normally.
                continue
            if any(bit not in "01xz" for bit in value):
                raise VcdError(f"line {line_number}: invalid four-state value {value!r}")
            if len(value) > activity.width:
                raise VcdError(
                    f"line {line_number}: value for {code!r} is wider than its declaration"
                )
            if len(value) < activity.width:
                pad = value[0] if value[0] in "xz" else "0"
                value = pad * (activity.width - len(value)) + value
            activity.update(value, current_tick, code, line_number)

    if not saw_enddefinitions:
        raise VcdError("VCD ended before $enddefinitions")
    if timescale is None:
        raise VcdError("VCD has no $timescale declaration")
    if not included_var_count:
        raise VcdError(
            "VCD contains no variables under requested source scope "
            + ".".join(vcd_root)
        )
    if duration_ticks is not None:
        if duration_ticks < final_tick:
            raise VcdError(
                f"requested duration {duration_ticks} is earlier than final VCD timestamp {final_tick}"
            )
        final_tick = duration_ticks
    if final_tick <= 0:
        raise VcdError("VCD duration is zero; an activity capture must span positive time")
    for code, activity in trackers.items():
        activity.finish(final_tick, code)
    assert timescale is not None
    return ParsedVcd(
        declarations=declarations,
        activity_by_code=trackers,
        timescale_multiplier=timescale[0],
        timescale_unit=timescale[1],
        final_tick=final_tick,
        vcd_sha256=digest.hexdigest(),
    )


def _saif_string(name: str) -> str:
    if not name or any(char in name for char in "\r\n\x00"):
        raise VcdError(f"cannot represent VCD name {name!r} in SAIF")
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _saif_atom(name: str) -> str:
    if not name or any(char in name for char in "\r\n\x00"):
        raise VcdError(f"cannot represent VCD name {name!r} in SAIF")
    if SAIF_SAFE_ATOM.fullmatch(name):
        return name
    # SAIF identifiers accept string tokens. Escaped VCD names therefore
    # remain a single name even when they contain punctuation.
    return _saif_string(name)


def _make_tree(
    parsed: ParsedVcd,
    vcd_root: tuple[str, ...],
    target_root: tuple[str, ...],
) -> tuple[SaifNode, int, int, int]:
    root = SaifNode()
    net_count = port_count = bit_count = 0
    for declaration in parsed.declarations:
        tail = declaration.scope[len(vcd_root) :]
        target_path = target_root + tail
        node = root
        for component in target_path:
            node = node.instances.setdefault(component, SaifNode())
        activity = parsed.activity_by_code[declaration.code]
        for name, counts in _declaration_names_with_activity(declaration, activity):
            is_port = not tail and declaration.name in PORT_NAMES
            node.signals.append(("PORT" if is_port else "NET", name, counts))
            if is_port:
                port_count += 1
            else:
                net_count += 1
            bit_count += 1
    return root, net_count, port_count, bit_count


def _declaration_names_with_activity(
    declaration: Declaration, activity: Activity
) -> list[tuple[str, list[int]]]:
    if declaration.indices is None:
        return [(declaration.name, activity.counts[0])]
    return [
        (f"{declaration.name}[{index}]", activity.counts[position])
        for position, index in enumerate(declaration.indices)
    ]


def _write_instance(stream, name: str, node: SaifNode, indent: int) -> None:
    pad = " " * indent
    stream.write(f"{pad}(INSTANCE {_saif_atom(name)}\n")
    # SAIF PORT/NET clauses contain a list of parenthesized signal entries.
    # They are not themselves individual signal entries.
    for kind in ("PORT", "NET"):
        signals = sorted((s for s in node.signals if s[0] == kind), key=lambda s: s[1])
        if not signals:
            continue
        stream.write(f"{pad}  ({kind}\n")
        for _, signal_name, counts in signals:
            t0, t1, tx, tz, tc = counts
            stream.write(
                f"{pad}    ({_saif_atom(signal_name)} "
                f"(T0 {t0}) (T1 {t1}) (TX {tx}) (TZ {tz}) (TC {tc}))\n"
            )
        stream.write(f"{pad}  )\n")
    for child_name, child in sorted(node.instances.items()):
        _write_instance(stream, child_name, child, indent + 2)
    stream.write(f"{pad})\n")


def _aggregate(parsed: ParsedVcd) -> dict[str, int | float]:
    total = [0, 0, 0, 0, 0]
    bits = 0
    active_bits = 0
    for activity in parsed.activity_by_code.values():
        for counts in activity.counts:
            bits += 1
            for index, count in enumerate(counts):
                total[index] += count
            if counts[4] > 0:
                active_bits += 1
    total_bit_time = bits * parsed.final_tick
    known_bit_time = total[0] + total[1]
    return {
        "tracked_unique_bits": bits,
        "tracked_unique_id_codes": len(parsed.activity_by_code),
        "aliased_variable_declarations": (
            len(parsed.declarations) - len(parsed.activity_by_code)
        ),
        "t0_bit_ticks": total[0],
        "t1_bit_ticks": total[1],
        "tx_bit_ticks": total[2],
        "tz_bit_ticks": total[3],
        "known_logic_residency_percent": (
            100.0 * known_bit_time / total_bit_time if total_bit_time else 0.0
        ),
        "bits_with_known_0_1_toggle": active_bits,
        "known_toggle_count": total[4],
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def convert_vcd_to_saif(
    vcd_path: Path,
    saif_path: Path,
    vcd_root: tuple[str, ...],
    target_root: tuple[str, ...],
    duration_ticks: int | None = None,
) -> dict:
    parsed = parse_vcd(vcd_path, vcd_root, duration_ticks)
    tree, net_count, port_count, bit_count = _make_tree(parsed, vcd_root, target_root)
    saif_path.parent.mkdir(parents=True, exist_ok=True)
    with saif_path.open("w", encoding="ascii", newline="\n") as stream:
        stream.write("(SAIFILE\n")
        stream.write(' (SAIFVERSION "2.0")\n')
        stream.write(' (DIRECTION "backward")\n')
        stream.write(f" (DESIGN {_saif_string(target_root[0])})\n")
        stream.write(' (DATE "generated by d4_activity_power.py")\n')
        stream.write(' (VENDOR "OpenAI Codex local tooling")\n')
        stream.write(' (PROGRAM_NAME "d4_activity_power.py")\n')
        stream.write(' (VERSION "1.0")\n')
        stream.write(" (DIVIDER /)\n")
        stream.write(
            f" (TIMESCALE {parsed.timescale_multiplier} {parsed.timescale_unit})\n"
        )
        stream.write(f" (DURATION {parsed.final_tick})\n")
        for top_name, top_node in sorted(tree.instances.items()):
            _write_instance(stream, top_name, top_node, 1)
        stream.write(")\n")

    summary = _aggregate(parsed)
    result = {
        "schema_version": 1,
        "conversion_status": "complete",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_vcd": str(vcd_path.resolve()),
        "source_vcd_size_bytes": vcd_path.stat().st_size,
        "source_vcd_sha256": parsed.vcd_sha256,
        "saif_path": str(saif_path.resolve()),
        "saif_sha256": _sha256(saif_path),
        "converter_source": str(Path(__file__).resolve()),
        "converter_source_sha256": _sha256(Path(__file__)),
        "source_scope_prefix": list(vcd_root),
        "target_scope_prefix": list(target_root),
        "read_saif_mapping": "read_saif -strip_path implementation_top; nested instance hierarchy retained",
        "timescale": {
            "multiplier": parsed.timescale_multiplier,
            "unit": parsed.timescale_unit,
        },
        "duration_ticks": parsed.final_tick,
        "duration_value": parsed.final_tick * parsed.timescale_multiplier,
        "duration_unit": parsed.timescale_unit,
        "scoped_variable_declarations": len(parsed.declarations),
        "saif_net_entries": net_count,
        "saif_port_entries": port_count,
        "saif_bit_entries": bit_count,
        "activity_summary": summary,
        "toggle_rule": "TC counts only known 0-to-1 or 1-to-0 transitions; X/Z transitions do not count",
        "residency_rule": "T0/T1/TX/TZ record exact VCD tick residency from time zero through the final VCD timestamp",
        "annotation_coverage_note": "Input-scope statistics only; Vivado import coverage is in the SAIF annotation and switching-activity reports.",
    }
    return result


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Stream a scoped D4 VCD into a hierarchy-mapped SAIF file."
    )
    parser.add_argument("--vcd", type=Path, required=True)
    parser.add_argument("--saif", type=Path, required=True)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument(
        "--vcd-root", default="TOP.tb_d4_fullnet.dut",
        help="dot-separated VCD source path to retain (default: %(default)s)",
    )
    parser.add_argument(
        "--target-root", default="d4_fullnet_impl_top.u_core",
        help="dot-separated synthesized hierarchy prefix (default: %(default)s)",
    )
    parser.add_argument(
        "--duration-ticks", type=int,
        help="override the final VCD timestamp when an external exact stop time is available",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        result = convert_vcd_to_saif(
            args.vcd,
            args.saif,
            _scope_prefix(args.vcd_root, "--vcd-root"),
            _scope_prefix(args.target_root, "--target-root"),
            args.duration_ticks,
        )
        if args.metadata:
            args.metadata.parent.mkdir(parents=True, exist_ok=True)
            args.metadata.write_text(
                json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
        print(
            "D4_ACTIVITY_SAIF_READY "
            f"duration={result['duration_value']} {result['duration_unit']} "
            f"vars={result['scoped_variable_declarations']} "
            f"bits={result['saif_bit_entries']} nets={result['saif_net_entries']} "
            f"ports={result['saif_port_entries']} saif={args.saif}"
        )
        return 0
    except (OSError, VcdError, ValueError) as exc:
        print(f"D4_ACTIVITY_SAIF_FAILED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
