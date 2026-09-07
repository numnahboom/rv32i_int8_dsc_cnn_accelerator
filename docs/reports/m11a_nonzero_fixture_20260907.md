# M1.1-A non-zero DS1/DS2 functional fixture

Status: `NONZERO_FIXTURE_REFERENCE_PASS` (independent software reference; RTL gate is reported by the simulator).

The fixture is generated directly from the checked-in firmware headers. No RTL output is used as an expected value.

## Sources

- `sw/model/model_weights.h` SHA256 `3febd7f6d0baaa3749a7fb3140a76068710c09fd33dc27c0f76905d18bd9f7bf`
- `sw/model/model_quant.h` SHA256 `da0e99811913b9c4a96690060139c4a143175c94f1b06556b031af2fbfc92c91`
- `sw/model/model_desc.h` SHA256 `086fcccb06dee748a82d6766c1ef579462ee4c529c2a031518c43a4467ae0485`

## Descriptor and arithmetic contract

| Layer | Input -> output | Stride | Row stride | Config words | DW vectors/MAC | PW tokens/MAC | Sink words |
|---|---|---:|---:|---:|---:|---:|---:|
| DS1 | 32x32x16 -> 32x32x32 | 1 | 512 | 308 | 1024 / 147456 | 8192 / 524288 | 8192 |
| DS2 | 32x32x32 -> 16x16x64 | 2 | 1024 | 872 | 512 / 73728 | 8192 / 524288 | 4096 |

Quantization uses the header bias/multiplier/shift arrays, Q31 nearest-away-from-zero rounding, arithmetic right shift, header zero-points, INT8 saturation, and ReLU range [0,127].

## Non-zero stream evidence

| Stream | Shape/layout | Non-zero | Min | Max |
|---|---|---:|---:|---:|
| DS1_input | `32x32x16`, NHWC pixel-major signed int8 (stem output) | 7441 | 0 | 42 |
| DS1_DW_expected | `32x32x16`, NHWC pixel-major signed int8 | 9146 | 0 | 84 |
| DS1_PW_expected | `32x32x32`, NHWC pixel-major signed int8 | 16707 | 0 | 75 |
| DS2_input | `32x32x32`, NHWC pixel-major signed int8 (DS1 PW output) | 16707 | 0 | 75 |
| DS2_DW_expected | `16x16x32`, NHWC pixel-major signed int8 | 4948 | 0 | 127 |
| DS2_PW_expected | `16x16x64`, NHWC pixel-major signed int8 | 9416 | 0 | 127 |
| DS1_sink_bytes | `32x32x32`, context/tile/drain-word sink byte order | 16707 | 0 | 75 |
| DS2_sink_bytes | `16x16x64`, context/tile/drain-word sink byte order | 9416 | 0 | 127 |

## Independent spot checks

The four checks below recompute selected DW/PW outputs from scalar terms and compare them with the emitted tensors. Each selected sample has signed products, a non-zero Q31 remainder, and a positive shift; the DS2 PW sample also exercises positive activation saturation to 127. All header zero-points are explicitly applied (and are zero for this export).

| Check | Pixel | Channel | Acc | Product | Rounded | Shift | Pre-clamp | Output |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| DS1_DW | [0, 0] | 0 | 5116 | 6538403773440 | 3045 | 7 | 23 | 23 |
| DS1_PW | [0, 0] | 0 | 1752 | 5051998339584 | 2353 | 8 | 9 | 9 |
| DS2_DW | [0, 0] | 6 | 100 | 3328678172160 | 1550 | 7 | 12 | 12 |
| DS2_PW | [8, 13] | 13 | 17619 | 35614983555200 | 16585 | 7 | 129 | 127 |

The simulator consumes the sink-byte files and sink-word metadata under the fixture directory. This evidence is limited to the standalone M1.1-A core; it is not full-network/full-top evidence.
