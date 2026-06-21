#!/usr/bin/env python3
"""Numpy golden model for EdgeDSCNet-C10 int8 inference.

The functions in this file intentionally mirror the first RTL version.  They
are used both for full-network reference execution and for small deterministic
unit-test vector generation.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Optional

try:
    import numpy as np
except ModuleNotFoundError:
    # Cycle-level control models such as DWLineBufferGolden intentionally use
    # only the Python standard library so RTL vector generation can run in the
    # minimal WSL simulation environment.
    np = None  # type: ignore[assignment]


INT8_MIN = -128
INT8_MAX = 127


@dataclass(frozen=True)
class QuantParams:
    bias: np.ndarray
    multiplier: np.ndarray
    shift: np.ndarray
    output_zero_point: int
    activation_min: int
    activation_max: int


@dataclass(frozen=True)
class DWLineBufferCycle:
    ready_in: bool
    window_valid: bool
    window_x_idx: int
    window_y_idx: int
    window: tuple[Optional[int], ...]


class DWLineBufferGolden:
    """Cycle-accurate model of rtl/cnn/dw_line_buffer.v.

    ``ready_in`` is evaluated from the state before the active clock edge.
    ``window_valid`` and ``window`` describe the registered state after that
    edge. Unknown, not-yet-filled line-memory entries are represented by None.
    """

    COLS = 32
    PIXEL_BITS = 128
    PIXEL_MASK = (1 << PIXEL_BITS) - 1

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        # The RTL resets the output registers, but intentionally does not clear
        # the distributed line memories.
        self.row0: list[Optional[int]] = [None] * self.COLS
        self.row1: list[Optional[int]] = [None] * self.COLS
        self.row0_cols: list[Optional[int]] = [0, 0, 0]
        self.row1_cols: list[Optional[int]] = [0, 0, 0]
        self.row2_cols: list[Optional[int]] = [0, 0, 0]
        self.window_valid = False
        self.window_x_idx = 0
        self.window_y_idx = 0

    def step(
        self,
        *,
        valid_in: bool,
        ready_out: bool,
        x_idx: int,
        y_idx: int,
        pixel_vec_in: int,
    ) -> DWLineBufferCycle:
        """Advance one rising clock edge.

        A transfer occurs only when ``valid_in && ready_in``. If an old output
        is consumed without a replacement input, ``window_valid`` is cleared.
        If the output is stalled, all memory and window state is held.
        """

        x_idx = int(x_idx)
        y_idx = int(y_idx)
        if not 0 <= x_idx < self.COLS:
            raise ValueError(f"x_idx must be in [0, {self.COLS - 1}], got {x_idx}")
        if not 0 <= y_idx < self.COLS:
            raise ValueError(f"y_idx must be in [0, {self.COLS - 1}], got {y_idx}")

        pixel_vec_in = int(pixel_vec_in) & self.PIXEL_MASK
        ready_in = (not self.window_valid) or bool(ready_out)

        if ready_in:
            if valid_in:
                # Read old memory values first to mirror nonblocking RTL
                # assignments at the active edge.
                old_row0 = self.row0[x_idx]
                old_row1 = self.row1[x_idx]

                self.row0[x_idx] = old_row1
                self.row1[x_idx] = pixel_vec_in

                self.row0_cols = [
                    self.row0_cols[1],
                    self.row0_cols[2],
                    old_row0,
                ]
                self.row1_cols = [
                    self.row1_cols[1],
                    self.row1_cols[2],
                    old_row1,
                ]
                self.row2_cols = [
                    self.row2_cols[1],
                    self.row2_cols[2],
                    pixel_vec_in,
                ]
                self.window_valid = y_idx >= 2 and x_idx >= 2
                self.window_x_idx = x_idx
                self.window_y_idx = y_idx
            else:
                self.window_valid = False

        window = tuple(self.row0_cols + self.row1_cols + self.row2_cols)
        return DWLineBufferCycle(
            ready_in=ready_in,
            window_valid=self.window_valid,
            window_x_idx=self.window_x_idx,
            window_y_idx=self.window_y_idx,
            window=window,
        )


def _to_i64(x: int | np.integer) -> int:
    return int(np.int64(x))


def round_shift_away_from_zero(value: int, shift: int) -> int:
    """Signed right shift with round-half-away-from-zero."""

    value = int(value)
    shift = int(shift)
    if shift <= 0:
        return value
    offset = 1 << (shift - 1)
    if value >= 0:
        return (value + offset) >> shift
    return -(((-value) + offset) >> shift)


def fixed_point_mul_q31(value: int, multiplier: int) -> int:
    product = _to_i64(value) * _to_i64(multiplier)
    return round_shift_away_from_zero(product, 31)


def saturate_int8(value: int) -> int:
    return max(INT8_MIN, min(INT8_MAX, int(value)))


def requantize_scalar(
    acc: int,
    bias: int,
    multiplier: int,
    shift: int,
    output_zero_point: int,
    activation_min: int,
    activation_max: int,
) -> np.int8:
    x = _to_i64(acc) + _to_i64(bias)
    x = fixed_point_mul_q31(x, int(multiplier))
    x = int(x) >> int(shift)
    x = x + int(output_zero_point)
    x = saturate_int8(x)
    x = max(int(activation_min), min(int(activation_max), x))
    return np.int8(x)


def requantize_array(acc: np.ndarray, qp: QuantParams) -> np.ndarray:
    acc64 = acc.astype(np.int64)
    out = np.empty(acc64.shape, dtype=np.int8)
    channels = acc64.shape[-1] if acc64.ndim > 0 else 1
    for index in np.ndindex(acc64.shape):
        c = index[-1] if acc64.ndim > 0 else 0
        q_index = c % channels
        out[index] = requantize_scalar(
            int(acc64[index]),
            int(qp.bias[q_index]),
            int(qp.multiplier[q_index]),
            int(qp.shift[q_index]),
            qp.output_zero_point,
            qp.activation_min,
            qp.activation_max,
        )
    return out


def relu6_bounds(scale: float, zero_point: int) -> tuple[int, int]:
    q0 = int(round(0.0 / scale)) + int(zero_point)
    q6 = int(round(6.0 / scale)) + int(zero_point)
    return saturate_int8(q0), saturate_int8(q6)


def pad_nhwc(x: np.ndarray, pad: int, input_zero_point: int) -> np.ndarray:
    if pad == 0:
        return x
    return np.pad(
        x,
        ((pad, pad), (pad, pad), (0, 0)),
        mode="constant",
        constant_values=int(input_zero_point),
    ).astype(np.int8)


def conv3x3_stem(
    x: np.ndarray,
    weight: np.ndarray,
    qp: QuantParams,
    input_zero_point: int,
    stride: int = 1,
    pad: int = 1,
) -> np.ndarray:
    """3x3 NHWC convolution, expected weight shape [Cout, 3, 3, Cin]."""

    assert x.ndim == 3 and x.shape[-1] == 3
    cout = weight.shape[0]
    xp = pad_nhwc(x, pad, input_zero_point).astype(np.int32)
    w = weight.astype(np.int32)
    out_h = (x.shape[0] + 2 * pad - 3) // stride + 1
    out_w = (x.shape[1] + 2 * pad - 3) // stride + 1
    acc = np.zeros((out_h, out_w, cout), dtype=np.int32)
    for oh in range(out_h):
        for ow in range(out_w):
            ih = oh * stride
            iw = ow * stride
            window = xp[ih : ih + 3, iw : iw + 3, :]
            for co in range(cout):
                acc[oh, ow, co] = int(np.sum(window * w[co]))
    return requantize_array(acc, qp)


def depthwise_conv3x3(
    x: np.ndarray,
    weight: np.ndarray,
    qp: QuantParams,
    input_zero_point: int,
    stride: int,
    pad: int = 1,
) -> np.ndarray:
    """3x3 NHWC depthwise convolution, weight shape [Cin, 3, 3]."""

    cin = x.shape[-1]
    assert weight.shape == (cin, 3, 3)
    xp = pad_nhwc(x, pad, input_zero_point).astype(np.int32)
    w = weight.astype(np.int32)
    out_h = (x.shape[0] + 2 * pad - 3) // stride + 1
    out_w = (x.shape[1] + 2 * pad - 3) // stride + 1
    acc = np.zeros((out_h, out_w, cin), dtype=np.int32)
    for oh in range(out_h):
        for ow in range(out_w):
            ih = oh * stride
            iw = ow * stride
            window = xp[ih : ih + 3, iw : iw + 3, :]
            for c in range(cin):
                acc[oh, ow, c] = int(np.sum(window[:, :, c] * w[c]))
    return requantize_array(acc, qp)


def pointwise_conv1x1(x: np.ndarray, weight: np.ndarray, qp: QuantParams) -> np.ndarray:
    """1x1 NHWC pointwise convolution, weight shape [Cout, Cin]."""

    h, w_in, cin = x.shape
    cout = weight.shape[0]
    assert weight.shape[1] == cin
    x32 = x.astype(np.int32).reshape(h * w_in, cin)
    w32 = weight.astype(np.int32).T
    acc = (x32 @ w32).reshape(h, w_in, cout).astype(np.int32)
    return requantize_array(acc, qp)


def matmul_8xk_kx8_int8(a: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Golden matrix multiply for the PW 8x8 array.

    a shape is [8, K], w shape is [K, 8], output is signed int32 [8, 8].
    """

    assert a.ndim == 2 and w.ndim == 2
    assert a.shape[0] == 8 and w.shape[1] == 8 and a.shape[1] == w.shape[0]
    return (a.astype(np.int32) @ w.astype(np.int32)).astype(np.int32)


def gap_int8(x: np.ndarray) -> np.ndarray:
    assert x.ndim == 3
    summed = np.sum(x.astype(np.int32), axis=(0, 1))
    avg = summed >> int(np.log2(x.shape[0] * x.shape[1]))
    return np.clip(avg, INT8_MIN, INT8_MAX).astype(np.int8)


def fc_int8(x: np.ndarray, weight: np.ndarray, qp: QuantParams) -> np.ndarray:
    assert x.ndim == 1
    assert weight.shape[1] == x.shape[0]
    acc = weight.astype(np.int32) @ x.astype(np.int32)
    return requantize_array(acc.reshape(1, -1), qp).reshape(-1)


def argmax_int8(logits: Iterable[int]) -> int:
    best_idx = 0
    best_val = -129
    for idx, value in enumerate(logits):
        value = int(value)
        if value > best_val:
            best_idx = idx
            best_val = value
    return best_idx


def write_hex_i8(path: str, data: np.ndarray) -> None:
    flat = data.astype(np.int8).reshape(-1)
    with open(path, "w", encoding="ascii") as f:
        for value in flat:
            f.write(f"{int(value) & 0xff:02x}\n")


def write_hex_i32(path: str, data: np.ndarray) -> None:
    flat = data.astype(np.int32).reshape(-1)
    with open(path, "w", encoding="ascii") as f:
        for value in flat:
            f.write(f"{int(value) & 0xffffffff:08x}\n")


def random_qparams(channels: int, rng: Optional[np.random.Generator] = None) -> QuantParams:
    rng = rng or np.random.default_rng(1)
    return QuantParams(
        bias=rng.integers(-20000, 20001, size=channels, dtype=np.int32),
        multiplier=rng.integers(1 << 28, (1 << 30), size=channels, dtype=np.int32),
        shift=rng.integers(0, 4, size=channels, dtype=np.int32),
        output_zero_point=int(rng.integers(-8, 9)),
        activation_min=-128,
        activation_max=127,
    )


if __name__ == "__main__":
    rng = np.random.default_rng(7)
    logits = rng.integers(-128, 128, size=10, dtype=np.int16).astype(np.int8)
    print("golden_int8.py self-check logits:", logits.tolist())
    print("argmax:", argmax_int8(logits))
