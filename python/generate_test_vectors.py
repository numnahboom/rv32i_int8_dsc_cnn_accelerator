#!/usr/bin/env python3
"""Generate deterministic vectors for RTL unit tests."""

from __future__ import annotations

import argparse
import random
from pathlib import Path

from golden_int8 import DWLineBufferGolden


ROOT = Path(__file__).resolve().parents[1]

FLAG_INPUT_FROM_SRAM = 1 << 1
FLAG_OUTPUT_TO_SRAM = 1 << 2
FLAG_SRAM_SWAP_ON_DONE = 1 << 4
FLAG_TILED_DS_BLOCK = 1 << 5


def hex_width(value: int, bits: int) -> str:
    mask = (1 << bits) - 1
    width = bits // 4
    return f"{int(value) & mask:0{width}x}"


def as_signed(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value = int(value) & mask
    return value - (1 << bits) if value & sign else value


def pack_i8(values: list[int]) -> int:
    packed = 0
    for idx, value in enumerate(values):
        packed |= (int(value) & 0xff) << (8 * idx)
    return packed


def round_shift_away_from_zero(value: int, shift: int) -> int:
    if shift <= 0:
        return int(value)
    offset = 1 << (shift - 1)
    if value >= 0:
        return (int(value) + offset) >> shift
    return -(((-int(value)) + offset) >> shift)


def saturate_int8(value: int) -> int:
    return max(-128, min(127, int(value)))


def requantize_scalar(
    acc: int,
    bias: int,
    multiplier: int,
    shift: int,
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> int:
    x = int(acc) + int(bias)
    x = round_shift_away_from_zero(x * int(multiplier), 31)
    x = x >> int(shift)
    x = x + int(output_zero_point)
    x = saturate_int8(x)
    return max(int(activation_min), min(int(activation_max), x))


def generate_requant_cases(out_dir: Path) -> Path:
    rng = random.Random(12345)
    cases: list[tuple[int, int, int, int, int, int, int]] = [
        (0, 0, 1 << 30, 0, 0, -128, 127),
        (100, 0, 1 << 30, 0, 0, -128, 127),
        (-100, 0, 1 << 30, 0, 0, -128, 127),
        (300000, -1000, 1 << 29, 3, 2, -128, 127),
        (-300000, 1000, 1 << 29, 3, -2, -128, 127),
        (2_000_000_000, 0, 1 << 30, 0, 0, -128, 127),
        (-2_000_000_000, 0, 1 << 30, 0, 0, -128, 127),
        (5000, 0, 1 << 30, 1, 0, 0, 48),
        (-5000, 0, 1 << 30, 1, 0, 0, 48),
        (1234567, -765432, 987654321, 5, -3, -10, 70),
    ]

    for _ in range(90):
        acc = rng.randrange(-(1 << 23), 1 << 23)
        bias = rng.randrange(-(1 << 20), 1 << 20)
        multiplier = rng.randrange(1 << 27, (1 << 30) - 1)
        shift = rng.randrange(0, 8)
        ozp = rng.randrange(-32, 33)
        act_min = rng.randrange(-128, 20)
        act_max = rng.randrange(max(act_min, -20), 128)
        cases.append((acc, bias, multiplier, shift, ozp, act_min, act_max))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "requant_cases.hex"
    with path.open("w", encoding="ascii") as f:
        for case in cases:
            acc, bias, multiplier, shift, ozp, act_min, act_max = case
            expected = requantize_scalar(acc, bias, multiplier, shift, ozp, act_min, act_max)
            f.write(
                " ".join(
                    [
                        hex_width(acc, 32),
                        hex_width(bias, 32),
                        hex_width(multiplier, 32),
                        hex_width(shift, 8),
                        hex_width(ozp, 32),
                        hex_width(act_min, 32),
                        hex_width(act_max, 32),
                        hex_width(expected, 8),
                    ]
                )
                + "\n"
            )
    return path


def matmul_8xk_kx8(a: list[list[int]], w: list[list[int]]) -> list[list[int]]:
    cin = len(w)
    out = [[0 for _ in range(8)] for _ in range(8)]
    for m in range(8):
        for n in range(8):
            total = 0
            for k in range(cin):
                total += int(a[m][k]) * int(w[k][n])
            out[m][n] = total
    return out


def generate_pw_cases(out_dir: Path) -> Path:
    rng = random.Random(67890)
    cin_values = [1, 3, 8, 16, 32]
    cases = []
    for cin in cin_values:
        a = [[rng.randrange(-128, 128) for _ in range(cin)] for _ in range(8)]
        w = [[rng.randrange(-128, 128) for _ in range(8)] for _ in range(cin)]
        cases.append((cin, a, w, matmul_8xk_kx8(a, w)))

    # Deterministic edge-ish case with alternating signs.
    cin = 8
    a = [[as_signed((m * 17 + k * 29), 8) for k in range(cin)] for m in range(8)]
    w = [[as_signed((k * 31 - n * 13), 8) for n in range(8)] for k in range(cin)]
    cases.append((cin, a, w, matmul_8xk_kx8(a, w)))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "pw_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for cin, a, w, out in cases:
            f.write(f"{cin}\n")
            for k in range(cin):
                act_vec = [a[m][k] for m in range(8)]
                wgt_vec = [w[k][n] for n in range(8)]
                f.write(f"{hex_width(pack_i8(act_vec), 64)} {hex_width(pack_i8(wgt_vec), 64)}\n")
            for m in range(8):
                for n in range(8):
                    f.write(f"{hex_width(out[m][n], 32)}\n")
    return path


def line_buffer_pixel(y: int, x: int) -> int:
    """Pack 16 distinguishable int8 channels into one 128-bit pixel."""

    channels = [as_signed(y * 47 + x * 13 + c * 7, 8) for c in range(16)]
    return pack_i8(channels)


def generate_dw_line_buffer_cases(out_dir: Path) -> Path:
    """Generate cycle-level ready/valid vectors for dw_line_buffer."""

    model = DWLineBufferGolden()
    coordinates = [(y, x) for y in range(5) for x in range(8)]
    bubble_before = {5, 13, 25}
    stall_after = {
        (2, 2): 2,
        (3, 5): 3,
    }

    rows: list[tuple[int, ...]] = []
    bubble_done: set[int] = set()
    source_idx = 0
    stall_remaining = 0
    cycle = 0

    while source_idx < len(coordinates) or model.window_valid or stall_remaining:
        ready_out = int(stall_remaining == 0)
        if stall_remaining:
            stall_remaining -= 1

        if source_idx < len(coordinates):
            y_idx, x_idx = coordinates[source_idx]
            if source_idx in bubble_before and source_idx not in bubble_done:
                valid_in = 0
                bubble_done.add(source_idx)
            else:
                valid_in = 1
            pixel_vec = line_buffer_pixel(y_idx, x_idx)
        else:
            valid_in = 0
            x_idx = 0
            y_idx = 0
            pixel_vec = 0

        expected = model.step(
            valid_in=bool(valid_in),
            ready_out=bool(ready_out),
            x_idx=x_idx,
            y_idx=y_idx,
            pixel_vec_in=pixel_vec,
        )

        if valid_in and expected.ready_in:
            accepted_coordinate = (y_idx, x_idx)
            source_idx += 1
            if accepted_coordinate in stall_after:
                stall_remaining = stall_after[accepted_coordinate]

        expected_window = [
            0 if value is None else int(value)
            for value in expected.window
        ]
        if expected.window_valid and any(value is None for value in expected.window):
            raise AssertionError(
                f"valid window contains uninitialized data at cycle {cycle}"
            )

        rows.append(
            (
                valid_in,
                ready_out,
                x_idx,
                y_idx,
                pixel_vec,
                int(expected.ready_in),
                int(expected.window_valid),
                *expected_window,
            )
        )
        cycle += 1
        if cycle > 256:
            raise RuntimeError("line-buffer vector generation did not converge")

    # One final empty cycle verifies that valid stays low once the last window
    # has been consumed.
    expected = model.step(
        valid_in=False,
        ready_out=True,
        x_idx=0,
        y_idx=0,
        pixel_vec_in=0,
    )
    rows.append(
        (
            0,
            1,
            0,
            0,
            0,
            int(expected.ready_in),
            int(expected.window_valid),
            *[0 if value is None else int(value) for value in expected.window],
        )
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "dw_line_buffer_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(rows)}\n")
        for row in rows:
            (
                valid_in,
                ready_out,
                x_idx,
                y_idx,
                pixel_vec,
                expected_ready_in,
                expected_window_valid,
                *expected_window,
            ) = row
            fields = [
                str(valid_in),
                str(ready_out),
                str(x_idx),
                str(y_idx),
                hex_width(pixel_vec, 128),
                str(expected_ready_in),
                str(expected_window_valid),
            ]
            fields.extend(hex_width(value, 128) for value in expected_window)
            f.write(" ".join(fields) + "\n")
    return path


def generate_dw_input(
    rng: random.Random,
    in_h: int,
    in_w: int,
    channels: int,
    input_zero_point: int,
    padded_border: bool,
) -> list[list[list[int]]]:
    tile = [
        [[input_zero_point for _ in range(channels)] for _ in range(17)]
        for _ in range(17)
    ]
    for y in range(in_h):
        for x in range(in_w):
            for c in range(channels):
                if padded_border and (y == 0 or x == 0 or y == in_h - 1 or x == in_w - 1):
                    tile[y][x][c] = input_zero_point
                else:
                    tile[y][x][c] = rng.randrange(-64, 64)
    return tile


def depthwise_tile_golden(
    tile: list[list[list[int]]],
    weight: list[list[int]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    out_h: int,
    out_w: int,
    channels: int,
    stride: int,
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> list[list[int]]:
    out_pixels = out_h * out_w
    out = [[0 for _ in range(channels)] for _ in range(out_pixels)]
    for oh in range(out_h):
        for ow in range(out_w):
            pixel = oh * out_w + ow
            for c in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy = oh * stride + kh
                        ix = ow * stride + kw
                        acc += int(tile[iy][ix][c]) * int(weight[c][kh * 3 + kw])
                out[pixel][c] = requantize_scalar(
                    acc,
                    bias[c],
                    multiplier[c],
                    shift[c],
                    output_zero_point,
                    activation_min,
                    activation_max,
                )
    return out


def generate_dw_cases(out_dir: Path) -> Path:
    rng = random.Random(24680)
    specs = [
        # out_h, out_w, in_h, in_w, channels, stride, padded_border, relu6-ish
        (8, 8, 10, 10, 3, 1, True, False),
        (8, 8, 17, 17, 5, 2, True, True),
        (4, 5, 6, 7, 16, 1, False, False),
    ]
    cases = []
    for out_h, out_w, in_h, in_w, channels, stride, padded_border, relu6 in specs:
        input_zero_point = rng.randrange(-9, 10)
        output_zero_point = rng.randrange(-7, 8)
        activation_min = 0 if relu6 else -128
        activation_max = 48 if relu6 else 127
        tile = generate_dw_input(rng, in_h, in_w, channels, input_zero_point, padded_border)
        weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(channels)]
        bias = [rng.randrange(-2048, 2049) for _ in range(channels)]
        multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(channels)]
        shift = [rng.randrange(5, 10) for _ in range(channels)]
        expected = depthwise_tile_golden(
            tile,
            weight,
            bias,
            multiplier,
            shift,
            out_h,
            out_w,
            channels,
            stride,
            output_zero_point,
            activation_min,
            activation_max,
        )
        cases.append(
            (
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                stride,
                input_zero_point,
                output_zero_point,
                activation_min,
                activation_max,
                tile,
                weight,
                bias,
                multiplier,
                shift,
                expected,
            )
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "dw_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for case in cases:
            (
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                stride,
                input_zero_point,
                output_zero_point,
                activation_min,
                activation_max,
                tile,
                weight,
                bias,
                multiplier,
                shift,
                expected,
            ) = case
            f.write(
                " ".join(
                    [
                        str(out_h),
                        str(out_w),
                        str(in_h),
                        str(in_w),
                        str(channels),
                        str(stride),
                        hex_width(input_zero_point, 8),
                        hex_width(output_zero_point, 32),
                        hex_width(activation_min, 32),
                        hex_width(activation_max, 32),
                    ]
                )
                + "\n"
            )
            for y in range(17):
                for x in range(17):
                    for c in range(channels):
                        f.write(f"{hex_width(tile[y][x][c], 8)}\n")
            for c in range(channels):
                for k in range(9):
                    f.write(f"{hex_width(weight[c][k], 8)}\n")
            for c in range(channels):
                f.write(f"{hex_width(bias[c], 32)}\n")
            for c in range(channels):
                f.write(f"{hex_width(multiplier[c], 32)}\n")
            for c in range(channels):
                f.write(f"{hex_width(shift[c], 8)}\n")
            for p in range(out_h * out_w):
                for c in range(channels):
                    f.write(f"{hex_width(expected[p][c], 8)}\n")
    return path


def stem_tile_golden(
    tile: list[list[list[int]]],
    weight: list[list[int]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    out_h: int,
    out_w: int,
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> list[list[int]]:
    out = [[0 for _ in range(16)] for _ in range(out_h * out_w)]
    for oh in range(out_h):
        for ow in range(out_w):
            pixel = oh * out_w + ow
            for co in range(16):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        for ci in range(3):
                            acc += int(tile[oh + kh][ow + kw][ci]) * int(weight[co][(kh * 3 + kw) * 3 + ci])
                out[pixel][co] = requantize_scalar(
                    acc,
                    bias[co],
                    multiplier[co],
                    shift[co],
                    output_zero_point,
                    activation_min,
                    activation_max,
                )
    return out


def stem_same_golden(
    feature: list[list[list[int]]],
    input_zero_point: int,
    weight: list[list[int]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> tuple[int, int, list[list[int]]]:
    in_h = len(feature)
    in_w = len(feature[0])
    out_h = in_h
    out_w = in_w
    out = [[0 for _ in range(16)] for _ in range(out_h * out_w)]
    for oh in range(out_h):
        for ow in range(out_w):
            pixel = oh * out_w + ow
            for co in range(16):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        src_y = oh + kh - 1
                        src_x = ow + kw - 1
                        for ci in range(3):
                            if src_y < 0 or src_x < 0 or src_y >= in_h or src_x >= in_w:
                                act = input_zero_point
                            else:
                                act = feature[src_y][src_x][ci]
                            acc += int(act) * int(weight[co][(kh * 3 + kw) * 3 + ci])
                out[pixel][co] = requantize_scalar(
                    acc,
                    bias[co],
                    multiplier[co],
                    shift[co],
                    output_zero_point,
                    activation_min,
                    activation_max,
                )
    return out_h, out_w, out


def generate_stem_cases(out_dir: Path) -> Path:
    rng = random.Random(13579)
    specs = [
        (8, 8, True),
        (3, 5, False),
    ]
    cases = []
    for out_h, out_w, padded_border in specs:
        input_zero_point = rng.randrange(-8, 9)
        output_zero_point = rng.randrange(-5, 6)
        activation_min = 0
        activation_max = 48
        tile = [
            [[input_zero_point for _ in range(3)] for _ in range(10)]
            for _ in range(10)
        ]
        for y in range(out_h + 2):
            for x in range(out_w + 2):
                for ci in range(3):
                    if padded_border and (y == 0 or x == 0 or y == out_h + 1 or x == out_w + 1):
                        tile[y][x][ci] = input_zero_point
                    else:
                        tile[y][x][ci] = rng.randrange(-64, 64)
        weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
        bias = [rng.randrange(-2048, 2049) for _ in range(16)]
        multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
        shift = [rng.randrange(5, 10) for _ in range(16)]
        expected = stem_tile_golden(
            tile,
            weight,
            bias,
            multiplier,
            shift,
            out_h,
            out_w,
            output_zero_point,
            activation_min,
            activation_max,
        )
        cases.append(
            (
                out_h,
                out_w,
                input_zero_point,
                output_zero_point,
                activation_min,
                activation_max,
                tile,
                weight,
                bias,
                multiplier,
                shift,
                expected,
            )
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "stem_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for case in cases:
            (
                out_h,
                out_w,
                input_zero_point,
                output_zero_point,
                activation_min,
                activation_max,
                tile,
                weight,
                bias,
                multiplier,
                shift,
                expected,
            ) = case
            f.write(
                " ".join(
                    [
                        str(out_h),
                        str(out_w),
                        hex_width(input_zero_point, 8),
                        hex_width(output_zero_point, 32),
                        hex_width(activation_min, 32),
                        hex_width(activation_max, 32),
                    ]
                )
                + "\n"
            )
            for y in range(10):
                for x in range(10):
                    for ci in range(3):
                        f.write(f"{hex_width(tile[y][x][ci], 8)}\n")
            for co in range(16):
                for k in range(27):
                    f.write(f"{hex_width(weight[co][k], 8)}\n")
            for co in range(16):
                f.write(f"{hex_width(bias[co], 32)}\n")
            for co in range(16):
                f.write(f"{hex_width(multiplier[co], 32)}\n")
            for co in range(16):
                f.write(f"{hex_width(shift[co], 8)}\n")
            for p in range(out_h * out_w):
                for co in range(16):
                    f.write(f"{hex_width(expected[p][co], 8)}\n")
    return path


def generate_gap_cases(out_dir: Path) -> Path:
    rng = random.Random(11223)
    cases = []
    for _ in range(2):
        feature = [
            [[rng.randrange(-128, 128) for _ in range(256)] for _ in range(4)]
            for _ in range(4)
        ]
        expected = []
        for c in range(256):
            total = 0
            for y in range(4):
                for x in range(4):
                    total += feature[y][x][c]
            expected.append(saturate_int8(total >> 4))
        cases.append((feature, expected))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "gap_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for feature, expected in cases:
            for y in range(4):
                for x in range(4):
                    for c in range(256):
                        f.write(f"{hex_width(feature[y][x][c], 8)}\n")
            for c in range(256):
                f.write(f"{hex_width(expected[c], 8)}\n")
    return path


def fc_golden(
    input_vec: list[int],
    weight: list[list[int]],
    bias: list[int],
    multiplier: list[int],
    shift: list[int],
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> list[int]:
    out = []
    for co in range(10):
        acc = 0
        for ci in range(256):
            acc += input_vec[ci] * weight[co][ci]
        out.append(
            requantize_scalar(
                acc,
                bias[co],
                multiplier[co],
                shift[co],
                output_zero_point,
                activation_min,
                activation_max,
            )
        )
    return out


def generate_fc_cases(out_dir: Path) -> Path:
    rng = random.Random(44556)
    cases = []
    for _ in range(2):
        input_vec = [rng.randrange(-64, 64) for _ in range(256)]
        weight = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
        bias = [rng.randrange(-4096, 4097) for _ in range(10)]
        multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
        shift = [rng.randrange(6, 11) for _ in range(10)]
        output_zero_point = rng.randrange(-4, 5)
        activation_min = -128
        activation_max = 127
        expected = fc_golden(
            input_vec,
            weight,
            bias,
            multiplier,
            shift,
            output_zero_point,
            activation_min,
            activation_max,
        )
        cases.append(
            (
                input_vec,
                weight,
                bias,
                multiplier,
                shift,
                output_zero_point,
                activation_min,
                activation_max,
                expected,
            )
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "fc_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for case in cases:
            (
                input_vec,
                weight,
                bias,
                multiplier,
                shift,
                output_zero_point,
                activation_min,
                activation_max,
                expected,
            ) = case
            f.write(
                f"{hex_width(output_zero_point, 32)} {hex_width(activation_min, 32)} {hex_width(activation_max, 32)}\n"
            )
            for ci in range(256):
                f.write(f"{hex_width(input_vec[ci], 8)}\n")
            for co in range(10):
                for ci in range(256):
                    f.write(f"{hex_width(weight[co][ci], 8)}\n")
            for co in range(10):
                f.write(f"{hex_width(bias[co], 32)}\n")
            for co in range(10):
                f.write(f"{hex_width(multiplier[co], 32)}\n")
            for co in range(10):
                f.write(f"{hex_width(shift[co], 8)}\n")
            for co in range(10):
                f.write(f"{hex_width(expected[co], 8)}\n")
    return path


def tile_sequence(out_h: int, out_w: int, stride: int) -> list[tuple[int, int, int, int, int, int, int]]:
    seq = []
    h = 0
    while h < out_h:
        w = 0
        tile_h = min(8, out_h - h)
        while w < out_w:
            tile_w = min(8, out_w - w)
            input_h = (tile_h + 2) if stride == 1 else ((tile_h - 1) * 2 + 3)
            input_w = (tile_w + 2) if stride == 1 else ((tile_w - 1) * 2 + 3)
            is_last = int((h + tile_h >= out_h) and (w + tile_w >= out_w))
            seq.append((h, w, tile_h, tile_w, input_h, input_w, is_last))
            w += 8
        h += 8
    return seq


def generate_tile_scheduler_cases(out_dir: Path) -> Path:
    specs = [(8, 8, 1), (16, 16, 2), (17, 9, 1)]
    cases = [(out_h, out_w, stride, tile_sequence(out_h, out_w, stride)) for out_h, out_w, stride in specs]
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "tile_scheduler_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for out_h, out_w, stride, seq in cases:
            f.write(f"{out_h} {out_w} {stride} {len(seq)}\n")
            for item in seq:
                f.write(" ".join(str(v) for v in item) + "\n")
    return path


def generate_feature_sram_bank_cases(out_dir: Path) -> Path:
    rng = random.Random(314159)
    ops: list[tuple[int, int, int, int]] = []
    mirror: dict[int, int] = {}

    for i in range(64):
        addr = (i * 37 + 11) & 0x7FFF
        value = rng.randrange(-128, 128)
        mirror[addr] = value
        ops.append((0, addr, value, 0))

    for addr, value in sorted(mirror.items()):
        ops.append((1, addr, 0, value))

    for i in range(16):
        addr = (i * 211 + 5) & 0x7FFF
        value = rng.randrange(-128, 128)
        mirror[addr] = value
        ops.append((2, addr, value, value))
        ops.append((1, addr, 0, value))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "feature_sram_bank_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(ops)}\n")
        for op, addr, data, expected in ops:
            f.write(f"{op} {addr:04x} {hex_width(data, 8)} {hex_width(expected, 8)}\n")
    return path


def generate_feature_sram_pingpong_cases(out_dir: Path) -> Path:
    rng = random.Random(271828)
    ops: list[tuple[int, int, int, int, int, int]] = []
    banks = [{}, {}]
    active_input_bank = 0

    # op, bank, addr, data, expected_data, expected_input_bank
    # 0 host_write, 1 host_read, 2 input_read, 3 output_write, 4 layer_done, 5 reset_to_a
    for i in range(24):
        addr = (i * 19 + 3) & 0x7FFF
        value = rng.randrange(-128, 128)
        banks[0][addr] = value
        ops.append((0, 0, addr, value, 0, active_input_bank))

    for i in range(24):
        addr = (i * 23 + 7) & 0x7FFF
        value = rng.randrange(-128, 128)
        banks[1][addr] = value
        ops.append((0, 1, addr, value, 0, active_input_bank))

    for addr, value in sorted(banks[0].items())[:8]:
        ops.append((2, 0, addr, 0, value, active_input_bank))

    output_bank = 1 - active_input_bank
    for i in range(16):
        addr = (i * 31 + 9) & 0x7FFF
        value = rng.randrange(-128, 128)
        banks[output_bank][addr] = value
        ops.append((3, output_bank, addr, value, 0, active_input_bank))

    active_input_bank = 1 - active_input_bank
    ops.append((4, 0, 0, 0, 0, active_input_bank))

    for addr, value in sorted(banks[active_input_bank].items())[:16]:
        ops.append((2, active_input_bank, addr, 0, value, active_input_bank))

    output_bank = 1 - active_input_bank
    for i in range(12):
        addr = (i * 43 + 13) & 0x7FFF
        value = rng.randrange(-128, 128)
        banks[output_bank][addr] = value
        ops.append((3, output_bank, addr, value, 0, active_input_bank))

    active_input_bank = 1 - active_input_bank
    ops.append((4, 0, 0, 0, 0, active_input_bank))

    for addr, value in sorted(banks[active_input_bank].items())[:12]:
        ops.append((2, active_input_bank, addr, 0, value, active_input_bank))

    active_input_bank = 0
    ops.append((5, 0, 0, 0, 0, active_input_bank))
    for addr, value in sorted(banks[0].items())[:10]:
        ops.append((1, 0, addr, 0, value, active_input_bank))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "feature_sram_pingpong_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(ops)}\n")
        for op, bank, addr, data, expected, expected_input_bank in ops:
            f.write(
                f"{op} {bank} {addr:04x} {hex_width(data, 8)} "
                f"{hex_width(expected, 8)} {expected_input_bank}\n"
            )
    return path


def dsblock_tile_golden(
    tile: list[list[list[int]]],
    dw_weight: list[list[int]],
    dw_bias: list[int],
    dw_multiplier: list[int],
    dw_shift: list[int],
    pw_weight: list[list[int]],
    pw_bias: list[int],
    pw_multiplier: list[int],
    pw_shift: list[int],
    out_h: int,
    out_w: int,
    channels: int,
    out_c: int,
    stride: int,
    dw_output_zero_point: int,
    dw_activation_min: int,
    dw_activation_max: int,
    pw_output_zero_point: int,
    pw_activation_min: int,
    pw_activation_max: int,
) -> tuple[list[list[int]], list[list[int]]]:
    dw_out = depthwise_tile_golden(
        tile,
        dw_weight,
        dw_bias,
        dw_multiplier,
        dw_shift,
        out_h,
        out_w,
        channels,
        stride,
        dw_output_zero_point,
        dw_activation_min,
        dw_activation_max,
    )
    out_pixels = out_h * out_w
    pw_out = [[0 for _ in range(out_c)] for _ in range(out_pixels)]
    for p in range(out_pixels):
        for co in range(out_c):
            acc = 0
            for ci in range(channels):
                acc += int(dw_out[p][ci]) * int(pw_weight[co][ci])
            pw_out[p][co] = requantize_scalar(
                acc,
                pw_bias[co],
                pw_multiplier[co],
                pw_shift[co],
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max,
            )
    return dw_out, pw_out


def dsblock_same_golden(
    feature: list[list[list[int]]],
    input_zero_point: int,
    dw_weight: list[list[int]],
    dw_bias: list[int],
    dw_multiplier: list[int],
    dw_shift: list[int],
    pw_weight: list[list[int]],
    pw_bias: list[int],
    pw_multiplier: list[int],
    pw_shift: list[int],
    stride: int,
    dw_output_zero_point: int,
    dw_activation_min: int,
    dw_activation_max: int,
    pw_output_zero_point: int,
    pw_activation_min: int,
    pw_activation_max: int,
) -> tuple[int, int, list[list[int]]]:
    in_h = len(feature)
    in_w = len(feature[0])
    channels = len(feature[0][0])
    out_c = len(pw_weight)
    out_h = ((in_h - 1) // stride) + 1
    out_w = ((in_w - 1) // stride) + 1
    dw_out = [[0 for _ in range(channels)] for _ in range(out_h * out_w)]
    pw_out = [[0 for _ in range(out_c)] for _ in range(out_h * out_w)]

    for oh in range(out_h):
        for ow in range(out_w):
            pixel = oh * out_w + ow
            for c in range(channels):
                acc = 0
                for kh in range(3):
                    for kw in range(3):
                        iy = oh * stride + kh - 1
                        ix = ow * stride + kw - 1
                        if 0 <= iy < in_h and 0 <= ix < in_w:
                            act = feature[iy][ix][c]
                        else:
                            act = input_zero_point
                        acc += int(act) * int(dw_weight[c][kh * 3 + kw])
                dw_out[pixel][c] = requantize_scalar(
                    acc,
                    dw_bias[c],
                    dw_multiplier[c],
                    dw_shift[c],
                    dw_output_zero_point,
                    dw_activation_min,
                    dw_activation_max,
                )

            for co in range(out_c):
                acc = 0
                for ci in range(channels):
                    acc += int(dw_out[pixel][ci]) * int(pw_weight[co][ci])
                pw_out[pixel][co] = requantize_scalar(
                    acc,
                    pw_bias[co],
                    pw_multiplier[co],
                    pw_shift[co],
                    pw_output_zero_point,
                    pw_activation_min,
                    pw_activation_max,
                )

    return out_h, out_w, pw_out


def generate_dsblock_cases(out_dir: Path) -> Path:
    rng = random.Random(97531)
    specs = [
        # out_h, out_w, in_h, in_w, cin, cout, stride, padded_border
        (8, 8, 10, 10, 8, 8, 1, True),
        (4, 4, 9, 9, 16, 16, 2, True),
        (2, 2, 4, 4, 8, 256, 1, False),
    ]
    cases = []
    for out_h, out_w, in_h, in_w, channels, out_c, stride, padded_border in specs:
        input_zero_point = rng.randrange(-8, 9)
        dw_output_zero_point = rng.randrange(-6, 7)
        pw_output_zero_point = rng.randrange(-6, 7)
        dw_activation_min = 0
        dw_activation_max = 48
        pw_activation_min = 0
        pw_activation_max = 48
        tile = generate_dw_input(rng, in_h, in_w, channels, input_zero_point, padded_border)
        dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(channels)]
        dw_bias = [rng.randrange(-2048, 2049) for _ in range(channels)]
        dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(channels)]
        dw_shift = [rng.randrange(5, 10) for _ in range(channels)]
        pw_weight = [[rng.randrange(-8, 9) for _ in range(channels)] for _ in range(out_c)]
        pw_bias = [rng.randrange(-4096, 4097) for _ in range(out_c)]
        pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(out_c)]
        pw_shift = [rng.randrange(5, 10) for _ in range(out_c)]
        _, expected = dsblock_tile_golden(
            tile,
            dw_weight,
            dw_bias,
            dw_multiplier,
            dw_shift,
            pw_weight,
            pw_bias,
            pw_multiplier,
            pw_shift,
            out_h,
            out_w,
            channels,
            out_c,
            stride,
            dw_output_zero_point,
            dw_activation_min,
            dw_activation_max,
            pw_output_zero_point,
            pw_activation_min,
            pw_activation_max,
        )
        cases.append(
            (
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                out_c,
                stride,
                input_zero_point,
                dw_output_zero_point,
                dw_activation_min,
                dw_activation_max,
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max,
                tile,
                dw_weight,
                dw_bias,
                dw_multiplier,
                dw_shift,
                pw_weight,
                pw_bias,
                pw_multiplier,
                pw_shift,
                expected,
            )
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "dsblock_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for case in cases:
            (
                out_h,
                out_w,
                in_h,
                in_w,
                channels,
                out_c,
                stride,
                input_zero_point,
                dw_output_zero_point,
                dw_activation_min,
                dw_activation_max,
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max,
                tile,
                dw_weight,
                dw_bias,
                dw_multiplier,
                dw_shift,
                pw_weight,
                pw_bias,
                pw_multiplier,
                pw_shift,
                expected,
            ) = case
            f.write(
                " ".join(
                    [
                        str(out_h),
                        str(out_w),
                        str(in_h),
                        str(in_w),
                        str(channels),
                        str(out_c),
                        str(stride),
                        hex_width(input_zero_point, 8),
                        hex_width(dw_output_zero_point, 32),
                        hex_width(dw_activation_min, 32),
                        hex_width(dw_activation_max, 32),
                        hex_width(pw_output_zero_point, 32),
                        hex_width(pw_activation_min, 32),
                        hex_width(pw_activation_max, 32),
                    ]
                )
                + "\n"
            )
            for y in range(17):
                for x in range(17):
                    for c in range(channels):
                        f.write(f"{hex_width(tile[y][x][c], 8)}\n")
            for c in range(channels):
                for k in range(9):
                    f.write(f"{hex_width(dw_weight[c][k], 8)}\n")
            for c in range(channels):
                f.write(f"{hex_width(dw_bias[c], 32)}\n")
            for c in range(channels):
                f.write(f"{hex_width(dw_multiplier[c], 32)}\n")
            for c in range(channels):
                f.write(f"{hex_width(dw_shift[c], 8)}\n")
            for co in range(out_c):
                for ci in range(channels):
                    f.write(f"{hex_width(pw_weight[co][ci], 8)}\n")
            for co in range(out_c):
                f.write(f"{hex_width(pw_bias[co], 32)}\n")
            for co in range(out_c):
                f.write(f"{hex_width(pw_multiplier[co], 32)}\n")
            for co in range(out_c):
                f.write(f"{hex_width(pw_shift[co], 8)}\n")
            for p in range(out_h * out_w):
                for co in range(out_c):
                    f.write(f"{hex_width(expected[p][co], 8)}\n")
    return path


def generate_cnn_top_dsblock_cases(out_dir: Path) -> Path:
    rng = random.Random(86420)
    specs = [
        # in_h, in_w, cin, cout, stride, padded_border
        (10, 10, 8, 8, 1, True),
        (9, 9, 16, 16, 2, True),
    ]
    cases = []
    for in_h, in_w, channels, out_c, stride, padded_border in specs:
        out_h = ((in_h - 3) // stride) + 1
        out_w = ((in_w - 3) // stride) + 1
        input_zero_point = rng.randrange(-8, 9)
        dw_output_zero_point = rng.randrange(-6, 7)
        pw_output_zero_point = rng.randrange(-6, 7)
        dw_activation_min = 0
        dw_activation_max = 48
        pw_activation_min = 0
        pw_activation_max = 48
        tile = generate_dw_input(rng, in_h, in_w, channels, input_zero_point, padded_border)
        dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(channels)]
        dw_bias = [rng.randrange(-2048, 2049) for _ in range(channels)]
        dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(channels)]
        dw_shift = [rng.randrange(5, 10) for _ in range(channels)]
        pw_weight = [[rng.randrange(-8, 9) for _ in range(channels)] for _ in range(out_c)]
        pw_bias = [rng.randrange(-4096, 4097) for _ in range(out_c)]
        pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(out_c)]
        pw_shift = [rng.randrange(5, 10) for _ in range(out_c)]
        _, expected = dsblock_tile_golden(
            tile,
            dw_weight,
            dw_bias,
            dw_multiplier,
            dw_shift,
            pw_weight,
            pw_bias,
            pw_multiplier,
            pw_shift,
            out_h,
            out_w,
            channels,
            out_c,
            stride,
            dw_output_zero_point,
            dw_activation_min,
            dw_activation_max,
            pw_output_zero_point,
            pw_activation_min,
            pw_activation_max,
        )
        cases.append(
            (
                in_h,
                in_w,
                out_h,
                out_w,
                channels,
                out_c,
                stride,
                input_zero_point,
                dw_output_zero_point,
                dw_activation_min,
                dw_activation_max,
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max,
                tile,
                dw_weight,
                dw_bias,
                dw_multiplier,
                dw_shift,
                pw_weight,
                pw_bias,
                pw_multiplier,
                pw_shift,
                expected,
            )
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_dsblock_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for case_idx, case in enumerate(cases):
            (
                in_h,
                in_w,
                out_h,
                out_w,
                channels,
                out_c,
                stride,
                input_zero_point,
                dw_output_zero_point,
                dw_activation_min,
                dw_activation_max,
                pw_output_zero_point,
                pw_activation_min,
                pw_activation_max,
                tile,
                dw_weight,
                dw_bias,
                dw_multiplier,
                dw_shift,
                pw_weight,
                pw_bias,
                pw_multiplier,
                pw_shift,
                expected,
            ) = case

            base = case_idx * 0x20000
            desc_base = base + 0x0000
            input_addr = base + 0x1000
            dw_weight_addr = base + 0x6000
            dw_bias_addr = base + 0x7000
            dw_mul_addr = base + 0x8000
            dw_shift_addr = base + 0x9000
            pw_weight_addr = base + 0xA000
            pw_bias_addr = base + 0xB000
            pw_mul_addr = base + 0xC000
            pw_shift_addr = base + 0xD000
            output_addr = base + 0xE000

            entries: list[tuple[int, int]] = []
            expected_entries: list[tuple[int, int]] = []

            def add(addr: int, value: int) -> None:
                entries.append((addr, value))

            desc = [0 for _ in range(32)]
            desc[0] = 1
            desc[1] = input_addr
            desc[2] = output_addr
            desc[3] = dw_weight_addr
            desc[4] = dw_bias_addr
            desc[5] = dw_mul_addr
            desc[6] = dw_shift_addr
            desc[7] = pw_weight_addr
            desc[8] = pw_bias_addr
            desc[9] = pw_mul_addr
            desc[10] = pw_shift_addr
            desc[11] = (in_w << 16) | in_h
            desc[12] = (out_c << 16) | channels
            desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | stride
            desc[14] = input_zero_point
            desc[15] = dw_output_zero_point
            desc[16] = pw_output_zero_point
            desc[17] = (
                ((pw_activation_max & 0xFF) << 24)
                | ((pw_activation_min & 0xFF) << 16)
                | ((dw_activation_max & 0xFF) << 8)
                | (dw_activation_min & 0xFF)
            )
            desc[18] = 0
            for i, value in enumerate(desc):
                add(desc_base + i * 4, value)

            idx = 0
            for y in range(in_h):
                for x in range(in_w):
                    for c in range(channels):
                        add(input_addr + idx * 4, tile[y][x][c])
                        idx += 1

            idx = 0
            for c in range(channels):
                for k in range(9):
                    add(dw_weight_addr + idx * 4, dw_weight[c][k])
                    idx += 1
            for c, value in enumerate(dw_bias):
                add(dw_bias_addr + c * 4, value)
            for c, value in enumerate(dw_multiplier):
                add(dw_mul_addr + c * 4, value)
            for c, value in enumerate(dw_shift):
                add(dw_shift_addr + c * 4, value)

            idx = 0
            for co in range(out_c):
                for ci in range(channels):
                    add(pw_weight_addr + idx * 4, pw_weight[co][ci])
                    idx += 1
            for co, value in enumerate(pw_bias):
                add(pw_bias_addr + co * 4, value)
            for co, value in enumerate(pw_multiplier):
                add(pw_mul_addr + co * 4, value)
            for co, value in enumerate(pw_shift):
                add(pw_shift_addr + co * 4, value)

            idx = 0
            for p in range(out_h * out_w):
                for co in range(out_c):
                    expected_entries.append((output_addr + idx * 4, expected[p][co]))
                    idx += 1

            f.write(f"{desc_base:08x} 1 {len(entries)} {len(expected_entries)}\n")
            for addr, value in entries:
                f.write(f"{addr:08x} {hex_width(value, 32)}\n")
            for addr, value in expected_entries:
                f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_ops_cases(out_dir: Path) -> Path:
    rng = random.Random(556677)
    cases: list[tuple[int, list[tuple[int, int]], list[tuple[int, int]]]] = []

    def build_common(case_idx: int) -> tuple[int, int, int, int, int, int, int]:
        base = case_idx * 0x10000
        return (
            base + 0x0000,  # desc_base
            base + 0x1000,  # input_addr
            base + 0x6000,  # weight_addr
            base + 0x9000,  # bias_addr
            base + 0xA000,  # mul_addr
            base + 0xB000,  # shift_addr
            base + 0xC000,  # output_addr
        )

    def add_desc(entries: list[tuple[int, int]], desc_base: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + i * 4, value))

    def add_linear(entries: list[tuple[int, int]], base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    # OP_CONV3X3_STEM
    desc_base, input_addr, weight_addr, bias_addr, mul_addr, shift_addr, output_addr = build_common(0)
    out_h = 8
    out_w = 8
    in_h = 10
    in_w = 10
    input_zero_point = rng.randrange(-8, 9)
    output_zero_point = rng.randrange(-5, 6)
    activation_min = 0
    activation_max = 48
    tile = [[[input_zero_point for _ in range(3)] for _ in range(10)] for _ in range(10)]
    for y in range(in_h):
        for x in range(in_w):
            for c in range(3):
                if y == 0 or x == 0 or y == in_h - 1 or x == in_w - 1:
                    tile[y][x][c] = input_zero_point
                else:
                    tile[y][x][c] = rng.randrange(-64, 64)
    weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
    bias = [rng.randrange(-2048, 2049) for _ in range(16)]
    multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
    shift = [rng.randrange(5, 10) for _ in range(16)]
    expected_stem = stem_tile_golden(
        tile,
        weight,
        bias,
        multiplier,
        shift,
        out_h,
        out_w,
        output_zero_point,
        activation_min,
        activation_max,
    )
    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []
    desc = [0 for _ in range(32)]
    desc[0] = 0
    desc[1] = input_addr
    desc[2] = output_addr
    desc[3] = weight_addr
    desc[4] = bias_addr
    desc[5] = mul_addr
    desc[6] = shift_addr
    desc[11] = (in_w << 16) | in_h
    desc[12] = (16 << 16) | 3
    desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | 1
    desc[14] = input_zero_point
    desc[15] = output_zero_point
    desc[17] = ((activation_max & 0xFF) << 8) | (activation_min & 0xFF)
    add_desc(entries, desc_base, desc)
    add_linear(entries, input_addr, [tile[y][x][c] for y in range(10) for x in range(10) for c in range(3)])
    add_linear(entries, weight_addr, [weight[co][k] for co in range(16) for k in range(27)])
    add_linear(entries, bias_addr, bias)
    add_linear(entries, mul_addr, multiplier)
    add_linear(entries, shift_addr, shift)
    idx = 0
    for p in range(out_h * out_w):
        for co in range(16):
            expected_entries.append((output_addr + idx * 4, expected_stem[p][co]))
            idx += 1
    cases.append((desc_base, entries, expected_entries))

    # OP_GAP
    desc_base, input_addr, _weight_addr, _bias_addr, _mul_addr, _shift_addr, output_addr = build_common(1)
    feature = [[[rng.randrange(-128, 128) for _ in range(256)] for _ in range(4)] for _ in range(4)]
    expected_gap = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        expected_gap.append(saturate_int8(total >> 4))
    entries = []
    expected_entries = []
    desc = [0 for _ in range(32)]
    desc[0] = 2
    desc[1] = input_addr
    desc[2] = output_addr
    desc[11] = (4 << 16) | 4
    desc[12] = (256 << 16) | 256
    add_desc(entries, desc_base, desc)
    add_linear(entries, input_addr, [feature[y][x][c] for y in range(4) for x in range(4) for c in range(256)])
    for c, value in enumerate(expected_gap):
        expected_entries.append((output_addr + c * 4, value))
    cases.append((desc_base, entries, expected_entries))

    # OP_FC
    desc_base, input_addr, weight_addr, bias_addr, mul_addr, shift_addr, output_addr = build_common(2)
    input_vec = [rng.randrange(-64, 64) for _ in range(256)]
    weight_fc = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    bias_fc = [rng.randrange(-4096, 4097) for _ in range(10)]
    multiplier_fc = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    shift_fc = [rng.randrange(6, 11) for _ in range(10)]
    output_zero_point = rng.randrange(-4, 5)
    activation_min = -128
    activation_max = 127
    expected_fc = fc_golden(
        input_vec,
        weight_fc,
        bias_fc,
        multiplier_fc,
        shift_fc,
        output_zero_point,
        activation_min,
        activation_max,
    )
    entries = []
    expected_entries = []
    desc = [0 for _ in range(32)]
    desc[0] = 3
    desc[1] = input_addr
    desc[2] = output_addr
    desc[7] = weight_addr
    desc[8] = bias_addr
    desc[9] = mul_addr
    desc[10] = shift_addr
    desc[11] = (1 << 16) | 1
    desc[12] = (10 << 16) | 256
    desc[16] = output_zero_point
    desc[17] = ((activation_max & 0xFF) << 24) | ((activation_min & 0xFF) << 16)
    add_desc(entries, desc_base, desc)
    add_linear(entries, input_addr, input_vec)
    add_linear(entries, weight_addr, [weight_fc[co][ci] for co in range(10) for ci in range(256)])
    add_linear(entries, bias_addr, bias_fc)
    add_linear(entries, mul_addr, multiplier_fc)
    add_linear(entries, shift_addr, shift_fc)
    for co, value in enumerate(expected_fc):
        expected_entries.append((output_addr + co * 4, int(value)))
    cases.append((desc_base, entries, expected_entries))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_ops_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for desc_base, entries, expected_entries in cases:
            f.write(f"{desc_base:08x} 1 {len(entries)} {len(expected_entries)}\n")
            for addr, value in entries:
                f.write(f"{addr:08x} {hex_width(value, 32)}\n")
            for addr, value in expected_entries:
                f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_multilayer_cases(out_dir: Path) -> Path:
    rng = random.Random(778899)
    cases: list[tuple[int, int, list[tuple[int, int]], list[tuple[int, int]]]] = []

    def add_desc(entries: list[tuple[int, int]], desc_base: int, layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(entries: list[tuple[int, int]], base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    # Case 0: Stem output is consumed directly by a DSBlock.
    desc_base = 0x00000
    stem_input_addr = 0x02000
    stem_weight_addr = 0x04000
    stem_bias_addr = 0x05000
    stem_mul_addr = 0x05100
    stem_shift_addr = 0x05200
    stem_out_addr = 0x06000
    ds_dw_weight_addr = 0x08000
    ds_dw_bias_addr = 0x09000
    ds_dw_mul_addr = 0x0A000
    ds_dw_shift_addr = 0x0B000
    ds_pw_weight_addr = 0x0C000
    ds_pw_bias_addr = 0x0D000
    ds_pw_mul_addr = 0x0D100
    ds_pw_shift_addr = 0x0D200
    ds_out_addr = 0x0E000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    stem_in_h = 10
    stem_in_w = 10
    stem_out_h = 8
    stem_out_w = 8
    stem_input_zero_point = rng.randrange(-8, 9)
    stem_output_zero_point = rng.randrange(-5, 6)
    relu_min = 0
    relu_max = 48
    stem_tile = [[[stem_input_zero_point for _ in range(3)] for _ in range(10)] for _ in range(10)]
    for y in range(stem_in_h):
        for x in range(stem_in_w):
            for c in range(3):
                if y == 0 or x == 0 or y == stem_in_h - 1 or x == stem_in_w - 1:
                    stem_tile[y][x][c] = stem_input_zero_point
                else:
                    stem_tile[y][x][c] = rng.randrange(-64, 64)
    stem_weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
    stem_bias = [rng.randrange(-2048, 2049) for _ in range(16)]
    stem_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
    stem_shift = [rng.randrange(5, 10) for _ in range(16)]
    stem_expected = stem_tile_golden(
        stem_tile,
        stem_weight,
        stem_bias,
        stem_multiplier,
        stem_shift,
        stem_out_h,
        stem_out_w,
        stem_output_zero_point,
        relu_min,
        relu_max,
    )

    ds_in_h = 8
    ds_in_w = 8
    ds_channels = 16
    ds_out_c = 16
    ds_stride = 1
    ds_out_h = 6
    ds_out_w = 6
    ds_dw_output_zero_point = rng.randrange(-6, 7)
    ds_pw_output_zero_point = rng.randrange(-6, 7)
    ds_tile = [
        [[stem_expected[y * stem_out_w + x][c] for c in range(ds_channels)] for x in range(ds_in_w)]
        for y in range(ds_in_h)
    ]
    ds_dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(ds_channels)]
    ds_dw_bias = [rng.randrange(-2048, 2049) for _ in range(ds_channels)]
    ds_dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds_channels)]
    ds_dw_shift = [rng.randrange(5, 10) for _ in range(ds_channels)]
    ds_pw_weight = [[rng.randrange(-8, 9) for _ in range(ds_channels)] for _ in range(ds_out_c)]
    ds_pw_bias = [rng.randrange(-4096, 4097) for _ in range(ds_out_c)]
    ds_pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds_out_c)]
    ds_pw_shift = [rng.randrange(5, 10) for _ in range(ds_out_c)]
    _, ds_expected = dsblock_tile_golden(
        ds_tile,
        ds_dw_weight,
        ds_dw_bias,
        ds_dw_multiplier,
        ds_dw_shift,
        ds_pw_weight,
        ds_pw_bias,
        ds_pw_multiplier,
        ds_pw_shift,
        ds_out_h,
        ds_out_w,
        ds_channels,
        ds_out_c,
        ds_stride,
        ds_dw_output_zero_point,
        relu_min,
        relu_max,
        ds_pw_output_zero_point,
        relu_min,
        relu_max,
    )

    stem_desc = [0 for _ in range(32)]
    stem_desc[0] = 0
    stem_desc[1] = stem_input_addr
    stem_desc[2] = stem_out_addr
    stem_desc[3] = stem_weight_addr
    stem_desc[4] = stem_bias_addr
    stem_desc[5] = stem_mul_addr
    stem_desc[6] = stem_shift_addr
    stem_desc[11] = (stem_in_w << 16) | stem_in_h
    stem_desc[12] = (16 << 16) | 3
    stem_desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | 1
    stem_desc[14] = stem_input_zero_point
    stem_desc[15] = stem_output_zero_point
    stem_desc[17] = ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    add_desc(entries, desc_base, 0, stem_desc)

    ds_desc = [0 for _ in range(32)]
    ds_desc[0] = 1
    ds_desc[1] = stem_out_addr
    ds_desc[2] = ds_out_addr
    ds_desc[3] = ds_dw_weight_addr
    ds_desc[4] = ds_dw_bias_addr
    ds_desc[5] = ds_dw_mul_addr
    ds_desc[6] = ds_dw_shift_addr
    ds_desc[7] = ds_pw_weight_addr
    ds_desc[8] = ds_pw_bias_addr
    ds_desc[9] = ds_pw_mul_addr
    ds_desc[10] = ds_pw_shift_addr
    ds_desc[11] = (ds_in_w << 16) | ds_in_h
    ds_desc[12] = (ds_out_c << 16) | ds_channels
    ds_desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | ds_stride
    ds_desc[14] = stem_output_zero_point
    ds_desc[15] = ds_dw_output_zero_point
    ds_desc[16] = ds_pw_output_zero_point
    ds_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    add_desc(entries, desc_base, 1, ds_desc)

    add_linear(entries, stem_input_addr, [stem_tile[y][x][c] for y in range(10) for x in range(10) for c in range(3)])
    add_linear(entries, stem_weight_addr, [stem_weight[co][k] for co in range(16) for k in range(27)])
    add_linear(entries, stem_bias_addr, stem_bias)
    add_linear(entries, stem_mul_addr, stem_multiplier)
    add_linear(entries, stem_shift_addr, stem_shift)
    add_linear(entries, ds_dw_weight_addr, [ds_dw_weight[c][k] for c in range(ds_channels) for k in range(9)])
    add_linear(entries, ds_dw_bias_addr, ds_dw_bias)
    add_linear(entries, ds_dw_mul_addr, ds_dw_multiplier)
    add_linear(entries, ds_dw_shift_addr, ds_dw_shift)
    add_linear(entries, ds_pw_weight_addr, [ds_pw_weight[co][ci] for co in range(ds_out_c) for ci in range(ds_channels)])
    add_linear(entries, ds_pw_bias_addr, ds_pw_bias)
    add_linear(entries, ds_pw_mul_addr, ds_pw_multiplier)
    add_linear(entries, ds_pw_shift_addr, ds_pw_shift)

    idx = 0
    for p in range(stem_out_h * stem_out_w):
        for co in range(16):
            expected_entries.append((stem_out_addr + idx * 4, stem_expected[p][co]))
            idx += 1
    idx = 0
    for p in range(ds_out_h * ds_out_w):
        for co in range(ds_out_c):
            expected_entries.append((ds_out_addr + idx * 4, ds_expected[p][co]))
            idx += 1
    cases.append((desc_base, 2, entries, expected_entries))

    # Case 1: GAP output is consumed directly by FC.
    desc_base = 0x20000
    gap_input_addr = 0x21000
    gap_out_addr = 0x26000
    fc_weight_addr = 0x27000
    fc_bias_addr = 0x2A000
    fc_mul_addr = 0x2A100
    fc_shift_addr = 0x2A200
    logits_addr = 0x2B000
    entries = []
    expected_entries = []

    feature = [[[rng.randrange(-128, 128) for _ in range(256)] for _ in range(4)] for _ in range(4)]
    gap_expected = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        gap_expected.append(saturate_int8(total >> 4))
    fc_weight_data = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    fc_bias_data = [rng.randrange(-4096, 4097) for _ in range(10)]
    fc_multiplier_data = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    fc_shift_data = [rng.randrange(6, 11) for _ in range(10)]
    fc_output_zero_point = rng.randrange(-4, 5)
    fc_activation_min = -128
    fc_activation_max = 127
    logits_expected = fc_golden(
        gap_expected,
        fc_weight_data,
        fc_bias_data,
        fc_multiplier_data,
        fc_shift_data,
        fc_output_zero_point,
        fc_activation_min,
        fc_activation_max,
    )

    gap_desc = [0 for _ in range(32)]
    gap_desc[0] = 2
    gap_desc[1] = gap_input_addr
    gap_desc[2] = gap_out_addr
    gap_desc[11] = (4 << 16) | 4
    gap_desc[12] = (256 << 16) | 256
    add_desc(entries, desc_base, 0, gap_desc)

    fc_desc = [0 for _ in range(32)]
    fc_desc[0] = 3
    fc_desc[1] = gap_out_addr
    fc_desc[2] = logits_addr
    fc_desc[7] = fc_weight_addr
    fc_desc[8] = fc_bias_addr
    fc_desc[9] = fc_mul_addr
    fc_desc[10] = fc_shift_addr
    fc_desc[11] = (1 << 16) | 1
    fc_desc[12] = (10 << 16) | 256
    fc_desc[16] = fc_output_zero_point
    fc_desc[17] = ((fc_activation_max & 0xFF) << 24) | ((fc_activation_min & 0xFF) << 16)
    add_desc(entries, desc_base, 1, fc_desc)

    add_linear(entries, gap_input_addr, [feature[y][x][c] for y in range(4) for x in range(4) for c in range(256)])
    add_linear(entries, fc_weight_addr, [fc_weight_data[co][ci] for co in range(10) for ci in range(256)])
    add_linear(entries, fc_bias_addr, fc_bias_data)
    add_linear(entries, fc_mul_addr, fc_multiplier_data)
    add_linear(entries, fc_shift_addr, fc_shift_data)
    for c, value in enumerate(gap_expected):
        expected_entries.append((gap_out_addr + c * 4, value))
    for co, value in enumerate(logits_expected):
        expected_entries.append((logits_addr + co * 4, int(value)))
    cases.append((desc_base, 2, entries, expected_entries))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_multilayer_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for desc_base_value, layer_count, entries_value, expected_value in cases:
            f.write(f"{desc_base_value:08x} {layer_count} {len(entries_value)} {len(expected_value)}\n")
            for addr, value in entries_value:
                f.write(f"{addr:08x} {hex_width(value, 32)}\n")
            for addr, value in expected_value:
                f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_tiled_dsblock_cases(out_dir: Path) -> Path:
    rng = random.Random(123321)
    specs = [
        # in_h, in_w, cin, cout, stride
        (12, 10, 8, 8, 1),
        (17, 17, 8, 16, 2),
    ]
    cases: list[tuple[int, list[tuple[int, int]], list[tuple[int, int]]]] = []

    def add_desc(entries: list[tuple[int, int]], desc_base: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + i * 4, value))

    def add_linear(entries: list[tuple[int, int]], base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    for case_idx, (in_h, in_w, channels, out_c, stride) in enumerate(specs):
        base = case_idx * 0x20000
        desc_base = base + 0x0000
        input_addr = base + 0x2000
        dw_weight_addr = base + 0x6000
        dw_bias_addr = base + 0x7000
        dw_mul_addr = base + 0x8000
        dw_shift_addr = base + 0x9000
        pw_weight_addr = base + 0xA000
        pw_bias_addr = base + 0xB000
        pw_mul_addr = base + 0xB100
        pw_shift_addr = base + 0xB200
        output_addr = base + 0xC000

        input_zero_point = rng.randrange(-8, 9)
        dw_output_zero_point = rng.randrange(-6, 7)
        pw_output_zero_point = rng.randrange(-6, 7)
        relu_min = 0
        relu_max = 48
        feature = [
            [[rng.randrange(-64, 64) for _ in range(channels)] for _ in range(in_w)]
            for _ in range(in_h)
        ]
        dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(channels)]
        dw_bias = [rng.randrange(-2048, 2049) for _ in range(channels)]
        dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(channels)]
        dw_shift = [rng.randrange(5, 10) for _ in range(channels)]
        pw_weight = [[rng.randrange(-8, 9) for _ in range(channels)] for _ in range(out_c)]
        pw_bias = [rng.randrange(-4096, 4097) for _ in range(out_c)]
        pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(out_c)]
        pw_shift = [rng.randrange(5, 10) for _ in range(out_c)]
        out_h, out_w, expected = dsblock_same_golden(
            feature,
            input_zero_point,
            dw_weight,
            dw_bias,
            dw_multiplier,
            dw_shift,
            pw_weight,
            pw_bias,
            pw_multiplier,
            pw_shift,
            stride,
            dw_output_zero_point,
            relu_min,
            relu_max,
            pw_output_zero_point,
            relu_min,
            relu_max,
        )

        entries: list[tuple[int, int]] = []
        expected_entries: list[tuple[int, int]] = []
        desc = [0 for _ in range(32)]
        desc[0] = 1
        desc[1] = input_addr
        desc[2] = output_addr
        desc[3] = dw_weight_addr
        desc[4] = dw_bias_addr
        desc[5] = dw_mul_addr
        desc[6] = dw_shift_addr
        desc[7] = pw_weight_addr
        desc[8] = pw_bias_addr
        desc[9] = pw_mul_addr
        desc[10] = pw_shift_addr
        desc[11] = (in_w << 16) | in_h
        desc[12] = (out_c << 16) | channels
        desc[13] = (1 << 8) | stride
        desc[14] = input_zero_point
        desc[15] = dw_output_zero_point
        desc[16] = pw_output_zero_point
        desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
        desc[18] = FLAG_TILED_DS_BLOCK
        add_desc(entries, desc_base, desc)

        add_linear(entries, input_addr, [feature[y][x][c] for y in range(in_h) for x in range(in_w) for c in range(channels)])
        add_linear(entries, dw_weight_addr, [dw_weight[c][k] for c in range(channels) for k in range(9)])
        add_linear(entries, dw_bias_addr, dw_bias)
        add_linear(entries, dw_mul_addr, dw_multiplier)
        add_linear(entries, dw_shift_addr, dw_shift)
        add_linear(entries, pw_weight_addr, [pw_weight[co][ci] for co in range(out_c) for ci in range(channels)])
        add_linear(entries, pw_bias_addr, pw_bias)
        add_linear(entries, pw_mul_addr, pw_multiplier)
        add_linear(entries, pw_shift_addr, pw_shift)

        idx = 0
        for p in range(out_h * out_w):
            for co in range(out_c):
                expected_entries.append((output_addr + idx * 4, expected[p][co]))
                idx += 1
        cases.append((desc_base, entries, expected_entries))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_tiled_dsblock_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write(f"{len(cases)}\n")
        for desc_base, entries, expected_entries in cases:
            f.write(f"{desc_base:08x} 1 {len(entries)} {len(expected_entries)}\n")
            for addr, value in entries:
                f.write(f"{addr:08x} {hex_width(value, 32)}\n")
            for addr, value in expected_entries:
                f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_sram_tiled_dsblock_cases(out_dir: Path) -> Path:
    rng = random.Random(990033)
    desc_base = 0x00000
    input_addr = 0x02000
    sram_mid_addr = 0x00000
    ds1_dw_weight_addr = 0x06000
    ds1_dw_bias_addr = 0x07000
    ds1_dw_mul_addr = 0x08000
    ds1_dw_shift_addr = 0x09000
    ds1_pw_weight_addr = 0x0A000
    ds1_pw_bias_addr = 0x0B000
    ds1_pw_mul_addr = 0x0B100
    ds1_pw_shift_addr = 0x0B200
    ds2_dw_weight_addr = 0x0C000
    ds2_dw_bias_addr = 0x0D000
    ds2_dw_mul_addr = 0x0E000
    ds2_dw_shift_addr = 0x0F000
    ds2_pw_weight_addr = 0x10000
    ds2_pw_bias_addr = 0x11000
    ds2_pw_mul_addr = 0x11100
    ds2_pw_shift_addr = 0x11200
    output_addr = 0x13000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    def flat_to_feature(flat: list[list[int]], h: int, w: int, channels: int) -> list[list[list[int]]]:
        return [
            [[flat[y * w + x][c] for c in range(channels)] for x in range(w)]
            for y in range(h)
        ]

    in_h = 12
    in_w = 10
    cin = 8
    ds1_out_c = 8
    ds2_out_c = 16
    stride1 = 1
    stride2 = 2
    relu_min = 0
    relu_max = 48

    input_zero_point = rng.randrange(-8, 9)
    feature0 = [
        [[rng.randrange(-64, 64) for _ in range(cin)] for _ in range(in_w)]
        for _ in range(in_h)
    ]

    ds1_dw_output_zero_point = rng.randrange(-6, 7)
    ds1_pw_output_zero_point = rng.randrange(-6, 7)
    ds1_dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(cin)]
    ds1_dw_bias = [rng.randrange(-2048, 2049) for _ in range(cin)]
    ds1_dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(cin)]
    ds1_dw_shift = [rng.randrange(5, 10) for _ in range(cin)]
    ds1_pw_weight = [[rng.randrange(-8, 9) for _ in range(cin)] for _ in range(ds1_out_c)]
    ds1_pw_bias = [rng.randrange(-4096, 4097) for _ in range(ds1_out_c)]
    ds1_pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds1_out_c)]
    ds1_pw_shift = [rng.randrange(5, 10) for _ in range(ds1_out_c)]
    ds1_out_h, ds1_out_w, ds1_expected = dsblock_same_golden(
        feature0,
        input_zero_point,
        ds1_dw_weight,
        ds1_dw_bias,
        ds1_dw_multiplier,
        ds1_dw_shift,
        ds1_pw_weight,
        ds1_pw_bias,
        ds1_pw_multiplier,
        ds1_pw_shift,
        stride1,
        ds1_dw_output_zero_point,
        relu_min,
        relu_max,
        ds1_pw_output_zero_point,
        relu_min,
        relu_max,
    )
    feature1 = flat_to_feature(ds1_expected, ds1_out_h, ds1_out_w, ds1_out_c)

    ds2_dw_output_zero_point = rng.randrange(-6, 7)
    ds2_pw_output_zero_point = rng.randrange(-6, 7)
    ds2_dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(ds1_out_c)]
    ds2_dw_bias = [rng.randrange(-2048, 2049) for _ in range(ds1_out_c)]
    ds2_dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds1_out_c)]
    ds2_dw_shift = [rng.randrange(5, 10) for _ in range(ds1_out_c)]
    ds2_pw_weight = [[rng.randrange(-8, 9) for _ in range(ds1_out_c)] for _ in range(ds2_out_c)]
    ds2_pw_bias = [rng.randrange(-4096, 4097) for _ in range(ds2_out_c)]
    ds2_pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds2_out_c)]
    ds2_pw_shift = [rng.randrange(5, 10) for _ in range(ds2_out_c)]
    ds2_out_h, ds2_out_w, ds2_expected = dsblock_same_golden(
        feature1,
        ds1_pw_output_zero_point,
        ds2_dw_weight,
        ds2_dw_bias,
        ds2_dw_multiplier,
        ds2_dw_shift,
        ds2_pw_weight,
        ds2_pw_bias,
        ds2_pw_multiplier,
        ds2_pw_shift,
        stride2,
        ds2_dw_output_zero_point,
        relu_min,
        relu_max,
        ds2_pw_output_zero_point,
        relu_min,
        relu_max,
    )

    ds1_desc = [0 for _ in range(32)]
    ds1_desc[0] = 1
    ds1_desc[1] = input_addr
    ds1_desc[2] = sram_mid_addr
    ds1_desc[3] = ds1_dw_weight_addr
    ds1_desc[4] = ds1_dw_bias_addr
    ds1_desc[5] = ds1_dw_mul_addr
    ds1_desc[6] = ds1_dw_shift_addr
    ds1_desc[7] = ds1_pw_weight_addr
    ds1_desc[8] = ds1_pw_bias_addr
    ds1_desc[9] = ds1_pw_mul_addr
    ds1_desc[10] = ds1_pw_shift_addr
    ds1_desc[11] = (in_w << 16) | in_h
    ds1_desc[12] = (ds1_out_c << 16) | cin
    ds1_desc[13] = (1 << 8) | stride1
    ds1_desc[14] = input_zero_point
    ds1_desc[15] = ds1_dw_output_zero_point
    ds1_desc[16] = ds1_pw_output_zero_point
    ds1_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    ds1_desc[18] = FLAG_TILED_DS_BLOCK | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(0, ds1_desc)

    ds2_desc = [0 for _ in range(32)]
    ds2_desc[0] = 1
    ds2_desc[1] = sram_mid_addr
    ds2_desc[2] = output_addr
    ds2_desc[3] = ds2_dw_weight_addr
    ds2_desc[4] = ds2_dw_bias_addr
    ds2_desc[5] = ds2_dw_mul_addr
    ds2_desc[6] = ds2_dw_shift_addr
    ds2_desc[7] = ds2_pw_weight_addr
    ds2_desc[8] = ds2_pw_bias_addr
    ds2_desc[9] = ds2_pw_mul_addr
    ds2_desc[10] = ds2_pw_shift_addr
    ds2_desc[11] = (ds1_out_w << 16) | ds1_out_h
    ds2_desc[12] = (ds2_out_c << 16) | ds1_out_c
    ds2_desc[13] = (1 << 8) | stride2
    ds2_desc[14] = ds1_pw_output_zero_point
    ds2_desc[15] = ds2_dw_output_zero_point
    ds2_desc[16] = ds2_pw_output_zero_point
    ds2_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    ds2_desc[18] = FLAG_TILED_DS_BLOCK | FLAG_INPUT_FROM_SRAM
    add_desc(1, ds2_desc)

    add_linear(input_addr, [feature0[y][x][c] for y in range(in_h) for x in range(in_w) for c in range(cin)])
    add_linear(ds1_dw_weight_addr, [ds1_dw_weight[c][k] for c in range(cin) for k in range(9)])
    add_linear(ds1_dw_bias_addr, ds1_dw_bias)
    add_linear(ds1_dw_mul_addr, ds1_dw_multiplier)
    add_linear(ds1_dw_shift_addr, ds1_dw_shift)
    add_linear(ds1_pw_weight_addr, [ds1_pw_weight[co][ci] for co in range(ds1_out_c) for ci in range(cin)])
    add_linear(ds1_pw_bias_addr, ds1_pw_bias)
    add_linear(ds1_pw_mul_addr, ds1_pw_multiplier)
    add_linear(ds1_pw_shift_addr, ds1_pw_shift)
    add_linear(ds2_dw_weight_addr, [ds2_dw_weight[c][k] for c in range(ds1_out_c) for k in range(9)])
    add_linear(ds2_dw_bias_addr, ds2_dw_bias)
    add_linear(ds2_dw_mul_addr, ds2_dw_multiplier)
    add_linear(ds2_dw_shift_addr, ds2_dw_shift)
    add_linear(ds2_pw_weight_addr, [ds2_pw_weight[co][ci] for co in range(ds2_out_c) for ci in range(ds1_out_c)])
    add_linear(ds2_pw_bias_addr, ds2_pw_bias)
    add_linear(ds2_pw_mul_addr, ds2_pw_multiplier)
    add_linear(ds2_pw_shift_addr, ds2_pw_shift)

    idx = 0
    for p in range(ds2_out_h * ds2_out_w):
        for co in range(ds2_out_c):
            expected_entries.append((output_addr + idx * 4, ds2_expected[p][co]))
            idx += 1

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_sram_tiled_dsblock_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 2 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_tiled_stem_cases(out_dir: Path) -> Path:
    rng = random.Random(990022)
    desc_base = 0x00000
    input_addr = 0x02000
    weight_addr = 0x06000
    bias_addr = 0x07000
    mul_addr = 0x07100
    shift_addr = 0x07200
    output_addr = 0x08000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    in_h = 32
    in_w = 32
    input_zero_point = rng.randrange(-8, 9)
    output_zero_point = rng.randrange(-5, 6)
    relu_min = 0
    relu_max = 48
    feature = [
        [[rng.randrange(-64, 64) for _ in range(3)] for _ in range(in_w)]
        for _ in range(in_h)
    ]
    weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
    bias = [rng.randrange(-2048, 2049) for _ in range(16)]
    multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
    shift = [rng.randrange(5, 10) for _ in range(16)]
    out_h, out_w, expected = stem_same_golden(
        feature,
        input_zero_point,
        weight,
        bias,
        multiplier,
        shift,
        output_zero_point,
        relu_min,
        relu_max,
    )

    desc = [0 for _ in range(32)]
    desc[0] = 0
    desc[1] = input_addr
    desc[2] = output_addr
    desc[3] = weight_addr
    desc[4] = bias_addr
    desc[5] = mul_addr
    desc[6] = shift_addr
    desc[11] = (in_w << 16) | in_h
    desc[12] = (16 << 16) | 3
    desc[13] = (1 << 8) | 1
    desc[14] = input_zero_point
    desc[15] = output_zero_point
    desc[17] = ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    desc[18] = FLAG_TILED_DS_BLOCK
    add_desc(0, desc)

    add_linear(input_addr, [feature[y][x][c] for y in range(in_h) for x in range(in_w) for c in range(3)])
    add_linear(weight_addr, [weight[co][k] for co in range(16) for k in range(27)])
    add_linear(bias_addr, bias)
    add_linear(mul_addr, multiplier)
    add_linear(shift_addr, shift)

    idx = 0
    for p in range(out_h * out_w):
        for co in range(16):
            expected_entries.append((output_addr + idx * 4, expected[p][co]))
            idx += 1

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_tiled_stem_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 1 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_tail_sram_cases(out_dir: Path) -> Path:
    rng = random.Random(990044)
    desc_base = 0x00000
    input_addr = 0x02000
    sram_feature_addr = 0x00000
    sram_vec_addr = 0x00000
    dw_weight_addr = 0x0A000
    dw_bias_addr = 0x0C000
    dw_mul_addr = 0x0D000
    dw_shift_addr = 0x0E000
    pw_weight_addr = 0x10000
    pw_bias_addr = 0x30000
    pw_mul_addr = 0x30400
    pw_shift_addr = 0x30800
    fc_weight_addr = 0x32000
    fc_bias_addr = 0x35000
    fc_mul_addr = 0x35100
    fc_shift_addr = 0x35200
    logits_addr = 0x36000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    in_h = 8
    in_w = 8
    cin = 128
    out_c = 256
    stride = 2
    relu_min = 0
    relu_max = 48

    input_zero_point = rng.randrange(-8, 9)
    dw_output_zero_point = rng.randrange(-6, 7)
    pw_output_zero_point = rng.randrange(-6, 7)
    feature = [
        [[rng.randrange(-64, 64) for _ in range(cin)] for _ in range(in_w)]
        for _ in range(in_h)
    ]
    dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(cin)]
    dw_bias = [rng.randrange(-2048, 2049) for _ in range(cin)]
    dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(cin)]
    dw_shift = [rng.randrange(5, 10) for _ in range(cin)]
    pw_weight = [[rng.randrange(-8, 9) for _ in range(cin)] for _ in range(out_c)]
    pw_bias = [rng.randrange(-4096, 4097) for _ in range(out_c)]
    pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(out_c)]
    pw_shift = [rng.randrange(5, 10) for _ in range(out_c)]
    ds_out_h, ds_out_w, ds_expected = dsblock_same_golden(
        feature,
        input_zero_point,
        dw_weight,
        dw_bias,
        dw_multiplier,
        dw_shift,
        pw_weight,
        pw_bias,
        pw_multiplier,
        pw_shift,
        stride,
        dw_output_zero_point,
        relu_min,
        relu_max,
        pw_output_zero_point,
        relu_min,
        relu_max,
    )

    gap_expected = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += ds_expected[y * ds_out_w + x][c]
        gap_expected.append(saturate_int8(total >> 4))

    fc_weight_data = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    fc_bias_data = [rng.randrange(-4096, 4097) for _ in range(10)]
    fc_multiplier_data = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    fc_shift_data = [rng.randrange(6, 11) for _ in range(10)]
    fc_output_zero_point = rng.randrange(-4, 5)
    fc_activation_min = -128
    fc_activation_max = 127
    logits_expected = fc_golden(
        gap_expected,
        fc_weight_data,
        fc_bias_data,
        fc_multiplier_data,
        fc_shift_data,
        fc_output_zero_point,
        fc_activation_min,
        fc_activation_max,
    )

    ds_desc = [0 for _ in range(32)]
    ds_desc[0] = 1
    ds_desc[1] = input_addr
    ds_desc[2] = sram_feature_addr
    ds_desc[3] = dw_weight_addr
    ds_desc[4] = dw_bias_addr
    ds_desc[5] = dw_mul_addr
    ds_desc[6] = dw_shift_addr
    ds_desc[7] = pw_weight_addr
    ds_desc[8] = pw_bias_addr
    ds_desc[9] = pw_mul_addr
    ds_desc[10] = pw_shift_addr
    ds_desc[11] = (in_w << 16) | in_h
    ds_desc[12] = (out_c << 16) | cin
    ds_desc[13] = (1 << 8) | stride
    ds_desc[14] = input_zero_point
    ds_desc[15] = dw_output_zero_point
    ds_desc[16] = pw_output_zero_point
    ds_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    ds_desc[18] = FLAG_TILED_DS_BLOCK | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(0, ds_desc)

    gap_desc = [0 for _ in range(32)]
    gap_desc[0] = 2
    gap_desc[1] = sram_feature_addr
    gap_desc[2] = sram_vec_addr
    gap_desc[11] = (4 << 16) | 4
    gap_desc[12] = (256 << 16) | 256
    gap_desc[18] = FLAG_INPUT_FROM_SRAM | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(1, gap_desc)

    fc_desc = [0 for _ in range(32)]
    fc_desc[0] = 3
    fc_desc[1] = sram_vec_addr
    fc_desc[2] = logits_addr
    fc_desc[7] = fc_weight_addr
    fc_desc[8] = fc_bias_addr
    fc_desc[9] = fc_mul_addr
    fc_desc[10] = fc_shift_addr
    fc_desc[11] = (1 << 16) | 1
    fc_desc[12] = (10 << 16) | 256
    fc_desc[16] = fc_output_zero_point
    fc_desc[17] = ((fc_activation_max & 0xFF) << 24) | ((fc_activation_min & 0xFF) << 16)
    fc_desc[18] = FLAG_INPUT_FROM_SRAM
    add_desc(2, fc_desc)

    add_linear(input_addr, [feature[y][x][c] for y in range(in_h) for x in range(in_w) for c in range(cin)])
    add_linear(dw_weight_addr, [dw_weight[c][k] for c in range(cin) for k in range(9)])
    add_linear(dw_bias_addr, dw_bias)
    add_linear(dw_mul_addr, dw_multiplier)
    add_linear(dw_shift_addr, dw_shift)
    add_linear(pw_weight_addr, [pw_weight[co][ci] for co in range(out_c) for ci in range(cin)])
    add_linear(pw_bias_addr, pw_bias)
    add_linear(pw_mul_addr, pw_multiplier)
    add_linear(pw_shift_addr, pw_shift)
    add_linear(fc_weight_addr, [fc_weight_data[co][ci] for co in range(10) for ci in range(256)])
    add_linear(fc_bias_addr, fc_bias_data)
    add_linear(fc_mul_addr, fc_multiplier_data)
    add_linear(fc_shift_addr, fc_shift_data)

    for co, value in enumerate(logits_expected):
        expected_entries.append((logits_addr + co * 4, int(value)))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_tail_sram_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 3 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_e2e_sram_cases(out_dir: Path) -> Path:
    rng = random.Random(990055)
    desc_base = 0x00000
    input_addr = 0x02000
    sram_feature_addr = 0x00000
    sram_vec_addr = 0x00000
    stem_weight_addr = 0x04000
    stem_bias_addr = 0x05000
    stem_mul_addr = 0x05100
    stem_shift_addr = 0x05200
    ds_dw_weight_addr = 0x06000
    ds_dw_bias_addr = 0x07000
    ds_dw_mul_addr = 0x07100
    ds_dw_shift_addr = 0x07200
    ds_pw_weight_addr = 0x08000
    ds_pw_bias_addr = 0x0C000
    ds_pw_mul_addr = 0x0C400
    ds_pw_shift_addr = 0x0C800
    fc_weight_addr = 0x10000
    fc_bias_addr = 0x13000
    fc_mul_addr = 0x13100
    fc_shift_addr = 0x13200
    logits_addr = 0x14000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    stem_in_h = 10
    stem_in_w = 10
    stem_out_h = 8
    stem_out_w = 8
    stem_output_c = 16
    ds_out_c = 256
    relu_min = 0
    relu_max = 48

    stem_input_zero_point = rng.randrange(-8, 9)
    stem_output_zero_point = rng.randrange(-5, 6)
    stem_input = [
        [[rng.randrange(-64, 64) for _ in range(3)] for _ in range(stem_in_w)]
        for _ in range(stem_in_h)
    ]
    stem_weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(stem_output_c)]
    stem_bias = [rng.randrange(-2048, 2049) for _ in range(stem_output_c)]
    stem_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(stem_output_c)]
    stem_shift = [rng.randrange(5, 10) for _ in range(stem_output_c)]
    stem_expected = stem_tile_golden(
        stem_input,
        stem_weight,
        stem_bias,
        stem_multiplier,
        stem_shift,
        stem_out_h,
        stem_out_w,
        stem_output_zero_point,
        relu_min,
        relu_max,
    )
    ds_feature = [
        [[stem_expected[y * stem_out_w + x][c] for c in range(stem_output_c)] for x in range(stem_out_w)]
        for y in range(stem_out_h)
    ]

    ds_dw_output_zero_point = rng.randrange(-6, 7)
    ds_pw_output_zero_point = rng.randrange(-6, 7)
    ds_stride = 2
    ds_dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(stem_output_c)]
    ds_dw_bias = [rng.randrange(-2048, 2049) for _ in range(stem_output_c)]
    ds_dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(stem_output_c)]
    ds_dw_shift = [rng.randrange(5, 10) for _ in range(stem_output_c)]
    ds_pw_weight = [[rng.randrange(-8, 9) for _ in range(stem_output_c)] for _ in range(ds_out_c)]
    ds_pw_bias = [rng.randrange(-4096, 4097) for _ in range(ds_out_c)]
    ds_pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds_out_c)]
    ds_pw_shift = [rng.randrange(5, 10) for _ in range(ds_out_c)]
    ds_out_h, ds_out_w, ds_expected = dsblock_same_golden(
        ds_feature,
        stem_output_zero_point,
        ds_dw_weight,
        ds_dw_bias,
        ds_dw_multiplier,
        ds_dw_shift,
        ds_pw_weight,
        ds_pw_bias,
        ds_pw_multiplier,
        ds_pw_shift,
        ds_stride,
        ds_dw_output_zero_point,
        relu_min,
        relu_max,
        ds_pw_output_zero_point,
        relu_min,
        relu_max,
    )

    gap_expected = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += ds_expected[y * ds_out_w + x][c]
        gap_expected.append(saturate_int8(total >> 4))

    fc_weight_data = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    fc_bias_data = [rng.randrange(-4096, 4097) for _ in range(10)]
    fc_multiplier_data = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    fc_shift_data = [rng.randrange(6, 11) for _ in range(10)]
    fc_output_zero_point = rng.randrange(-4, 5)
    fc_activation_min = -128
    fc_activation_max = 127
    logits_expected = fc_golden(
        gap_expected,
        fc_weight_data,
        fc_bias_data,
        fc_multiplier_data,
        fc_shift_data,
        fc_output_zero_point,
        fc_activation_min,
        fc_activation_max,
    )

    stem_desc = [0 for _ in range(32)]
    stem_desc[0] = 0
    stem_desc[1] = input_addr
    stem_desc[2] = sram_feature_addr
    stem_desc[3] = stem_weight_addr
    stem_desc[4] = stem_bias_addr
    stem_desc[5] = stem_mul_addr
    stem_desc[6] = stem_shift_addr
    stem_desc[11] = (stem_in_w << 16) | stem_in_h
    stem_desc[12] = (stem_output_c << 16) | 3
    stem_desc[13] = (1 << 8) | 1
    stem_desc[14] = stem_input_zero_point
    stem_desc[15] = stem_output_zero_point
    stem_desc[17] = ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    stem_desc[18] = FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(0, stem_desc)

    ds_desc = [0 for _ in range(32)]
    ds_desc[0] = 1
    ds_desc[1] = sram_feature_addr
    ds_desc[2] = sram_feature_addr
    ds_desc[3] = ds_dw_weight_addr
    ds_desc[4] = ds_dw_bias_addr
    ds_desc[5] = ds_dw_mul_addr
    ds_desc[6] = ds_dw_shift_addr
    ds_desc[7] = ds_pw_weight_addr
    ds_desc[8] = ds_pw_bias_addr
    ds_desc[9] = ds_pw_mul_addr
    ds_desc[10] = ds_pw_shift_addr
    ds_desc[11] = (stem_out_w << 16) | stem_out_h
    ds_desc[12] = (ds_out_c << 16) | stem_output_c
    ds_desc[13] = (1 << 8) | ds_stride
    ds_desc[14] = stem_output_zero_point
    ds_desc[15] = ds_dw_output_zero_point
    ds_desc[16] = ds_pw_output_zero_point
    ds_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    ds_desc[18] = FLAG_TILED_DS_BLOCK | FLAG_INPUT_FROM_SRAM | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(1, ds_desc)

    gap_desc = [0 for _ in range(32)]
    gap_desc[0] = 2
    gap_desc[1] = sram_feature_addr
    gap_desc[2] = sram_vec_addr
    gap_desc[11] = (4 << 16) | 4
    gap_desc[12] = (256 << 16) | 256
    gap_desc[18] = FLAG_INPUT_FROM_SRAM | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(2, gap_desc)

    fc_desc = [0 for _ in range(32)]
    fc_desc[0] = 3
    fc_desc[1] = sram_vec_addr
    fc_desc[2] = logits_addr
    fc_desc[7] = fc_weight_addr
    fc_desc[8] = fc_bias_addr
    fc_desc[9] = fc_mul_addr
    fc_desc[10] = fc_shift_addr
    fc_desc[11] = (1 << 16) | 1
    fc_desc[12] = (10 << 16) | 256
    fc_desc[16] = fc_output_zero_point
    fc_desc[17] = ((fc_activation_max & 0xFF) << 24) | ((fc_activation_min & 0xFF) << 16)
    fc_desc[18] = FLAG_INPUT_FROM_SRAM
    add_desc(3, fc_desc)

    add_linear(input_addr, [stem_input[y][x][c] for y in range(stem_in_h) for x in range(stem_in_w) for c in range(3)])
    add_linear(stem_weight_addr, [stem_weight[co][k] for co in range(stem_output_c) for k in range(27)])
    add_linear(stem_bias_addr, stem_bias)
    add_linear(stem_mul_addr, stem_multiplier)
    add_linear(stem_shift_addr, stem_shift)
    add_linear(ds_dw_weight_addr, [ds_dw_weight[c][k] for c in range(stem_output_c) for k in range(9)])
    add_linear(ds_dw_bias_addr, ds_dw_bias)
    add_linear(ds_dw_mul_addr, ds_dw_multiplier)
    add_linear(ds_dw_shift_addr, ds_dw_shift)
    add_linear(ds_pw_weight_addr, [ds_pw_weight[co][ci] for co in range(ds_out_c) for ci in range(stem_output_c)])
    add_linear(ds_pw_bias_addr, ds_pw_bias)
    add_linear(ds_pw_mul_addr, ds_pw_multiplier)
    add_linear(ds_pw_shift_addr, ds_pw_shift)
    add_linear(fc_weight_addr, [fc_weight_data[co][ci] for co in range(10) for ci in range(256)])
    add_linear(fc_bias_addr, fc_bias_data)
    add_linear(fc_mul_addr, fc_multiplier_data)
    add_linear(fc_shift_addr, fc_shift_data)

    if (ds_out_h, ds_out_w) != (4, 4):
        raise ValueError(f"unexpected e2e DS output shape {ds_out_h}x{ds_out_w}")

    for co, value in enumerate(logits_expected):
        expected_entries.append((logits_addr + co * 4, int(value)))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_e2e_sram_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 4 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_fullnet_sram_cases(out_dir: Path) -> Path:
    rng = random.Random(990077)
    desc_base = 0x00000
    next_addr = 0x01000
    sram_feature_addr = 0x00000
    sram_vec_addr = 0x00000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def alloc_words(count: int) -> int:
        nonlocal next_addr
        next_addr = (next_addr + 0xFF) & ~0xFF
        base = next_addr
        next_addr = base + count * 4
        return base

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    def flat_to_feature(flat: list[list[int]], h: int, w: int, channels: int) -> list[list[list[int]]]:
        return [
            [[flat[y * w + x][c] for c in range(channels)] for x in range(w)]
            for y in range(h)
        ]

    relu_min = 0
    relu_max = 48
    layer_idx = 0

    input_addr = alloc_words(32 * 32 * 3)
    input_zero_point = rng.randrange(-8, 9)
    feature = [
        [[rng.randrange(-64, 64) for _ in range(3)] for _ in range(32)]
        for _ in range(32)
    ]
    add_linear(input_addr, [feature[y][x][c] for y in range(32) for x in range(32) for c in range(3)])

    stem_weight_addr = alloc_words(16 * 27)
    stem_bias_addr = alloc_words(16)
    stem_mul_addr = alloc_words(16)
    stem_shift_addr = alloc_words(16)
    stem_output_zero_point = rng.randrange(-5, 6)
    stem_weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
    stem_bias = [rng.randrange(-2048, 2049) for _ in range(16)]
    stem_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
    stem_shift = [rng.randrange(5, 10) for _ in range(16)]
    stem_out_h, stem_out_w, stem_expected = stem_same_golden(
        feature,
        input_zero_point,
        stem_weight,
        stem_bias,
        stem_multiplier,
        stem_shift,
        stem_output_zero_point,
        relu_min,
        relu_max,
    )
    stem_desc = [0 for _ in range(32)]
    stem_desc[0] = 0
    stem_desc[1] = input_addr
    stem_desc[2] = sram_feature_addr
    stem_desc[3] = stem_weight_addr
    stem_desc[4] = stem_bias_addr
    stem_desc[5] = stem_mul_addr
    stem_desc[6] = stem_shift_addr
    stem_desc[11] = (32 << 16) | 32
    stem_desc[12] = (16 << 16) | 3
    stem_desc[13] = (1 << 8) | 1
    stem_desc[14] = input_zero_point
    stem_desc[15] = stem_output_zero_point
    stem_desc[17] = ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    stem_desc[18] = FLAG_TILED_DS_BLOCK | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(layer_idx, stem_desc)
    add_linear(stem_weight_addr, [stem_weight[co][k] for co in range(16) for k in range(27)])
    add_linear(stem_bias_addr, stem_bias)
    add_linear(stem_mul_addr, stem_multiplier)
    add_linear(stem_shift_addr, stem_shift)
    feature = flat_to_feature(stem_expected, stem_out_h, stem_out_w, 16)
    prev_zero_point = stem_output_zero_point
    layer_idx += 1

    ds_specs = [
        (32, 32, 16, 32, 1),
        (32, 32, 32, 64, 2),
        (16, 16, 64, 64, 1),
        (16, 16, 64, 128, 2),
        (8, 8, 128, 128, 1),
        (8, 8, 128, 256, 2),
    ]

    for in_h, in_w, in_c, out_c, stride in ds_specs:
        dw_weight_addr = alloc_words(in_c * 9)
        dw_bias_addr = alloc_words(in_c)
        dw_mul_addr = alloc_words(in_c)
        dw_shift_addr = alloc_words(in_c)
        pw_weight_addr = alloc_words(out_c * in_c)
        pw_bias_addr = alloc_words(out_c)
        pw_mul_addr = alloc_words(out_c)
        pw_shift_addr = alloc_words(out_c)

        dw_output_zero_point = rng.randrange(-6, 7)
        pw_output_zero_point = rng.randrange(-6, 7)
        dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(in_c)]
        dw_bias = [rng.randrange(-2048, 2049) for _ in range(in_c)]
        dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(in_c)]
        dw_shift = [rng.randrange(5, 10) for _ in range(in_c)]
        pw_weight = [[rng.randrange(-8, 9) for _ in range(in_c)] for _ in range(out_c)]
        pw_bias = [rng.randrange(-4096, 4097) for _ in range(out_c)]
        pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(out_c)]
        pw_shift = [rng.randrange(5, 10) for _ in range(out_c)]

        out_h, out_w, ds_expected = dsblock_same_golden(
            feature,
            prev_zero_point,
            dw_weight,
            dw_bias,
            dw_multiplier,
            dw_shift,
            pw_weight,
            pw_bias,
            pw_multiplier,
            pw_shift,
            stride,
            dw_output_zero_point,
            relu_min,
            relu_max,
            pw_output_zero_point,
            relu_min,
            relu_max,
        )

        desc = [0 for _ in range(32)]
        desc[0] = 1
        desc[1] = sram_feature_addr
        desc[2] = sram_feature_addr
        desc[3] = dw_weight_addr
        desc[4] = dw_bias_addr
        desc[5] = dw_mul_addr
        desc[6] = dw_shift_addr
        desc[7] = pw_weight_addr
        desc[8] = pw_bias_addr
        desc[9] = pw_mul_addr
        desc[10] = pw_shift_addr
        desc[11] = (in_w << 16) | in_h
        desc[12] = (out_c << 16) | in_c
        desc[13] = (1 << 8) | stride
        desc[14] = prev_zero_point
        desc[15] = dw_output_zero_point
        desc[16] = pw_output_zero_point
        desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
        desc[18] = FLAG_TILED_DS_BLOCK | FLAG_INPUT_FROM_SRAM | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
        add_desc(layer_idx, desc)

        add_linear(dw_weight_addr, [dw_weight[c][k] for c in range(in_c) for k in range(9)])
        add_linear(dw_bias_addr, dw_bias)
        add_linear(dw_mul_addr, dw_multiplier)
        add_linear(dw_shift_addr, dw_shift)
        add_linear(pw_weight_addr, [pw_weight[co][ci] for co in range(out_c) for ci in range(in_c)])
        add_linear(pw_bias_addr, pw_bias)
        add_linear(pw_mul_addr, pw_multiplier)
        add_linear(pw_shift_addr, pw_shift)

        feature = flat_to_feature(ds_expected, out_h, out_w, out_c)
        prev_zero_point = pw_output_zero_point
        layer_idx += 1

    gap_expected = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        gap_expected.append(saturate_int8(total >> 4))

    gap_desc = [0 for _ in range(32)]
    gap_desc[0] = 2
    gap_desc[1] = sram_feature_addr
    gap_desc[2] = sram_vec_addr
    gap_desc[11] = (4 << 16) | 4
    gap_desc[12] = (256 << 16) | 256
    gap_desc[18] = FLAG_INPUT_FROM_SRAM | FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(layer_idx, gap_desc)
    layer_idx += 1

    fc_weight_addr = alloc_words(10 * 256)
    fc_bias_addr = alloc_words(10)
    fc_mul_addr = alloc_words(10)
    fc_shift_addr = alloc_words(10)
    logits_addr = alloc_words(10)
    fc_weight_data = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    fc_bias_data = [rng.randrange(-4096, 4097) for _ in range(10)]
    fc_multiplier_data = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    fc_shift_data = [rng.randrange(6, 11) for _ in range(10)]
    fc_output_zero_point = rng.randrange(-4, 5)
    fc_activation_min = -128
    fc_activation_max = 127
    logits_expected = fc_golden(
        gap_expected,
        fc_weight_data,
        fc_bias_data,
        fc_multiplier_data,
        fc_shift_data,
        fc_output_zero_point,
        fc_activation_min,
        fc_activation_max,
    )

    fc_desc = [0 for _ in range(32)]
    fc_desc[0] = 3
    fc_desc[1] = sram_vec_addr
    fc_desc[2] = logits_addr
    fc_desc[7] = fc_weight_addr
    fc_desc[8] = fc_bias_addr
    fc_desc[9] = fc_mul_addr
    fc_desc[10] = fc_shift_addr
    fc_desc[11] = (1 << 16) | 1
    fc_desc[12] = (10 << 16) | 256
    fc_desc[16] = fc_output_zero_point
    fc_desc[17] = ((fc_activation_max & 0xFF) << 24) | ((fc_activation_min & 0xFF) << 16)
    fc_desc[18] = FLAG_INPUT_FROM_SRAM
    add_desc(layer_idx, fc_desc)

    add_linear(fc_weight_addr, [fc_weight_data[co][ci] for co in range(10) for ci in range(256)])
    add_linear(fc_bias_addr, fc_bias_data)
    add_linear(fc_mul_addr, fc_multiplier_data)
    add_linear(fc_shift_addr, fc_shift_data)

    for co, value in enumerate(logits_expected):
        expected_entries.append((logits_addr + co * 4, int(value)))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_fullnet_sram_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 9 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_sram_gap_fc_cases(out_dir: Path) -> Path:
    rng = random.Random(990011)
    desc_base = 0x00000
    gap_input_addr = 0x02000
    sram_vec_addr = 0x00000
    fc_weight_addr = 0x08000
    fc_bias_addr = 0x0B000
    fc_mul_addr = 0x0B100
    fc_shift_addr = 0x0B200
    logits_addr = 0x0C000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    feature = [[[rng.randrange(-128, 128) for _ in range(256)] for _ in range(4)] for _ in range(4)]
    gap_expected = []
    for c in range(256):
        total = 0
        for y in range(4):
            for x in range(4):
                total += feature[y][x][c]
        gap_expected.append(saturate_int8(total >> 4))

    fc_weight_data = [[rng.randrange(-8, 9) for _ in range(256)] for _ in range(10)]
    fc_bias_data = [rng.randrange(-4096, 4097) for _ in range(10)]
    fc_multiplier_data = [rng.randrange(1 << 28, 1 << 30) for _ in range(10)]
    fc_shift_data = [rng.randrange(6, 11) for _ in range(10)]
    fc_output_zero_point = rng.randrange(-4, 5)
    fc_activation_min = -128
    fc_activation_max = 127
    logits_expected = fc_golden(
        gap_expected,
        fc_weight_data,
        fc_bias_data,
        fc_multiplier_data,
        fc_shift_data,
        fc_output_zero_point,
        fc_activation_min,
        fc_activation_max,
    )

    gap_desc = [0 for _ in range(32)]
    gap_desc[0] = 2
    gap_desc[1] = gap_input_addr
    gap_desc[2] = sram_vec_addr
    gap_desc[11] = (4 << 16) | 4
    gap_desc[12] = (256 << 16) | 256
    gap_desc[18] = FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(0, gap_desc)

    fc_desc = [0 for _ in range(32)]
    fc_desc[0] = 3
    fc_desc[1] = sram_vec_addr
    fc_desc[2] = logits_addr
    fc_desc[7] = fc_weight_addr
    fc_desc[8] = fc_bias_addr
    fc_desc[9] = fc_mul_addr
    fc_desc[10] = fc_shift_addr
    fc_desc[11] = (1 << 16) | 1
    fc_desc[12] = (10 << 16) | 256
    fc_desc[16] = fc_output_zero_point
    fc_desc[17] = ((fc_activation_max & 0xFF) << 24) | ((fc_activation_min & 0xFF) << 16)
    fc_desc[18] = FLAG_INPUT_FROM_SRAM
    add_desc(1, fc_desc)

    add_linear(gap_input_addr, [feature[y][x][c] for y in range(4) for x in range(4) for c in range(256)])
    add_linear(fc_weight_addr, [fc_weight_data[co][ci] for co in range(10) for ci in range(256)])
    add_linear(fc_bias_addr, fc_bias_data)
    add_linear(fc_mul_addr, fc_multiplier_data)
    add_linear(fc_shift_addr, fc_shift_data)
    for co, value in enumerate(logits_expected):
        expected_entries.append((logits_addr + co * 4, int(value)))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_sram_gap_fc_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 2 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def generate_cnn_top_sram_stem_dsblock_cases(out_dir: Path) -> Path:
    rng = random.Random(990022)
    desc_base = 0x00000
    stem_input_addr = 0x02000
    stem_weight_addr = 0x04000
    stem_bias_addr = 0x05000
    stem_mul_addr = 0x05100
    stem_shift_addr = 0x05200
    sram_feature_addr = 0x00000
    ds_dw_weight_addr = 0x08000
    ds_dw_bias_addr = 0x09000
    ds_dw_mul_addr = 0x0A000
    ds_dw_shift_addr = 0x0B000
    ds_pw_weight_addr = 0x0C000
    ds_pw_bias_addr = 0x0D000
    ds_pw_mul_addr = 0x0D100
    ds_pw_shift_addr = 0x0D200
    ds_out_addr = 0x0E000

    entries: list[tuple[int, int]] = []
    expected_entries: list[tuple[int, int]] = []

    def add_desc(layer_idx: int, desc: list[int]) -> None:
        for i, value in enumerate(desc):
            entries.append((desc_base + layer_idx * 128 + i * 4, value))

    def add_linear(base: int, values: list[int]) -> None:
        for i, value in enumerate(values):
            entries.append((base + i * 4, value))

    stem_in_h = 10
    stem_in_w = 10
    stem_out_h = 8
    stem_out_w = 8
    stem_input_zero_point = rng.randrange(-8, 9)
    stem_output_zero_point = rng.randrange(-5, 6)
    relu_min = 0
    relu_max = 48
    stem_tile = [[[stem_input_zero_point for _ in range(3)] for _ in range(10)] for _ in range(10)]
    for y in range(stem_in_h):
        for x in range(stem_in_w):
            for c in range(3):
                if y == 0 or x == 0 or y == stem_in_h - 1 or x == stem_in_w - 1:
                    stem_tile[y][x][c] = stem_input_zero_point
                else:
                    stem_tile[y][x][c] = rng.randrange(-64, 64)

    stem_weight = [[rng.randrange(-8, 9) for _ in range(27)] for _ in range(16)]
    stem_bias = [rng.randrange(-2048, 2049) for _ in range(16)]
    stem_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(16)]
    stem_shift = [rng.randrange(5, 10) for _ in range(16)]
    stem_expected = stem_tile_golden(
        stem_tile,
        stem_weight,
        stem_bias,
        stem_multiplier,
        stem_shift,
        stem_out_h,
        stem_out_w,
        stem_output_zero_point,
        relu_min,
        relu_max,
    )

    ds_channels = 16
    ds_out_c = 16
    ds_stride = 1
    ds_out_h = 6
    ds_out_w = 6
    ds_dw_output_zero_point = rng.randrange(-6, 7)
    ds_pw_output_zero_point = rng.randrange(-6, 7)
    ds_tile = [
        [[stem_expected[y * stem_out_w + x][c] for c in range(ds_channels)] for x in range(stem_out_w)]
        for y in range(stem_out_h)
    ]
    ds_dw_weight = [[rng.randrange(-8, 9) for _ in range(9)] for _ in range(ds_channels)]
    ds_dw_bias = [rng.randrange(-2048, 2049) for _ in range(ds_channels)]
    ds_dw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds_channels)]
    ds_dw_shift = [rng.randrange(5, 10) for _ in range(ds_channels)]
    ds_pw_weight = [[rng.randrange(-8, 9) for _ in range(ds_channels)] for _ in range(ds_out_c)]
    ds_pw_bias = [rng.randrange(-4096, 4097) for _ in range(ds_out_c)]
    ds_pw_multiplier = [rng.randrange(1 << 28, 1 << 30) for _ in range(ds_out_c)]
    ds_pw_shift = [rng.randrange(5, 10) for _ in range(ds_out_c)]
    _, ds_expected = dsblock_tile_golden(
        ds_tile,
        ds_dw_weight,
        ds_dw_bias,
        ds_dw_multiplier,
        ds_dw_shift,
        ds_pw_weight,
        ds_pw_bias,
        ds_pw_multiplier,
        ds_pw_shift,
        ds_out_h,
        ds_out_w,
        ds_channels,
        ds_out_c,
        ds_stride,
        ds_dw_output_zero_point,
        relu_min,
        relu_max,
        ds_pw_output_zero_point,
        relu_min,
        relu_max,
    )

    stem_desc = [0 for _ in range(32)]
    stem_desc[0] = 0
    stem_desc[1] = stem_input_addr
    stem_desc[2] = sram_feature_addr
    stem_desc[3] = stem_weight_addr
    stem_desc[4] = stem_bias_addr
    stem_desc[5] = stem_mul_addr
    stem_desc[6] = stem_shift_addr
    stem_desc[11] = (stem_in_w << 16) | stem_in_h
    stem_desc[12] = (16 << 16) | 3
    stem_desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | 1
    stem_desc[14] = stem_input_zero_point
    stem_desc[15] = stem_output_zero_point
    stem_desc[17] = ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    stem_desc[18] = FLAG_OUTPUT_TO_SRAM | FLAG_SRAM_SWAP_ON_DONE
    add_desc(0, stem_desc)

    ds_desc = [0 for _ in range(32)]
    ds_desc[0] = 1
    ds_desc[1] = sram_feature_addr
    ds_desc[2] = ds_out_addr
    ds_desc[3] = ds_dw_weight_addr
    ds_desc[4] = ds_dw_bias_addr
    ds_desc[5] = ds_dw_mul_addr
    ds_desc[6] = ds_dw_shift_addr
    ds_desc[7] = ds_pw_weight_addr
    ds_desc[8] = ds_pw_bias_addr
    ds_desc[9] = ds_pw_mul_addr
    ds_desc[10] = ds_pw_shift_addr
    ds_desc[11] = (stem_out_w << 16) | stem_out_h
    ds_desc[12] = (ds_out_c << 16) | ds_channels
    ds_desc[13] = (1 << 24) | (1 << 16) | (1 << 8) | ds_stride
    ds_desc[14] = stem_output_zero_point
    ds_desc[15] = ds_dw_output_zero_point
    ds_desc[16] = ds_pw_output_zero_point
    ds_desc[17] = ((relu_max & 0xFF) << 24) | ((relu_min & 0xFF) << 16) | ((relu_max & 0xFF) << 8) | (relu_min & 0xFF)
    ds_desc[18] = FLAG_INPUT_FROM_SRAM
    add_desc(1, ds_desc)

    add_linear(stem_input_addr, [stem_tile[y][x][c] for y in range(10) for x in range(10) for c in range(3)])
    add_linear(stem_weight_addr, [stem_weight[co][k] for co in range(16) for k in range(27)])
    add_linear(stem_bias_addr, stem_bias)
    add_linear(stem_mul_addr, stem_multiplier)
    add_linear(stem_shift_addr, stem_shift)
    add_linear(ds_dw_weight_addr, [ds_dw_weight[c][k] for c in range(ds_channels) for k in range(9)])
    add_linear(ds_dw_bias_addr, ds_dw_bias)
    add_linear(ds_dw_mul_addr, ds_dw_multiplier)
    add_linear(ds_dw_shift_addr, ds_dw_shift)
    add_linear(ds_pw_weight_addr, [ds_pw_weight[co][ci] for co in range(ds_out_c) for ci in range(ds_channels)])
    add_linear(ds_pw_bias_addr, ds_pw_bias)
    add_linear(ds_pw_mul_addr, ds_pw_multiplier)
    add_linear(ds_pw_shift_addr, ds_pw_shift)

    idx = 0
    for p in range(ds_out_h * ds_out_w):
        for co in range(ds_out_c):
            expected_entries.append((ds_out_addr + idx * 4, ds_expected[p][co]))
            idx += 1

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "cnn_top_sram_stem_dsblock_cases.hex"
    with path.open("w", encoding="ascii") as f:
        f.write("1\n")
        f.write(f"{desc_base:08x} 2 {len(entries)} {len(expected_entries)}\n")
        for addr, value in entries:
            f.write(f"{addr:08x} {hex_width(value, 32)}\n")
        for addr, value in expected_entries:
            f.write(f"{addr:08x} {hex_width(value, 8)}\n")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=str(ROOT / "tests" / "vectors"))
    args = parser.parse_args()
    out_dir = Path(args.out_dir)
    print(f"wrote {generate_requant_cases(out_dir)}")
    print(f"wrote {generate_pw_cases(out_dir)}")
    print(f"wrote {generate_dw_line_buffer_cases(out_dir)}")
    print(f"wrote {generate_dw_cases(out_dir)}")
    print(f"wrote {generate_stem_cases(out_dir)}")
    print(f"wrote {generate_gap_cases(out_dir)}")
    print(f"wrote {generate_fc_cases(out_dir)}")
    print(f"wrote {generate_tile_scheduler_cases(out_dir)}")
    print(f"wrote {generate_feature_sram_bank_cases(out_dir)}")
    print(f"wrote {generate_feature_sram_pingpong_cases(out_dir)}")
    print(f"wrote {generate_dsblock_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_dsblock_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_ops_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_multilayer_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_tiled_dsblock_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_sram_tiled_dsblock_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_tiled_stem_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_tail_sram_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_e2e_sram_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_fullnet_sram_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_sram_gap_fc_cases(out_dir)}")
    print(f"wrote {generate_cnn_top_sram_stem_dsblock_cases(out_dir)}")


if __name__ == "__main__":
    main()
