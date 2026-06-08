# Quantization

Activation: signed int8 asymmetric.

Weight: signed int8 symmetric, zero point 0.

Bias: signed int32, with input zero point correction folded offline.

Accumulator: signed int32.

The RTL and Python golden use the same first-version requant function documented in `README.md`.
