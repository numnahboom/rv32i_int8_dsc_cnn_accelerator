# Quantization specification

## Shared integer types

- Activation: signed INT8.
- Weight: signed INT8.
- Bias and architectural accumulator: signed INT32.
- Final stored activation/logit: signed INT8 after saturation.

All hardware claims must identify the model manifest and evaluator used. C0 and D4 share integer widths, but they do not share a deployment ABI or automatically share scale/zero-point/requant parameters.

## C0 deployment ABI

C0 uses asymmetric activation quantization, symmetric weights with zero point 0, and bias with input-zero-point correction folded offline. The current C0 RTL/Python reference is:

```text
acc = sum(input_int8 * weight_int8) + corrected_bias
x = round_away_from_zero((acc * multiplier) / 2^31)
x = arithmetic_right_shift(x, shift)
x = x + output_zero_point
x = saturate_int8(x)
x = clamp(x, activation_min, activation_max)
```

Padding uses the layer `input_zero_point`; ReLU6 is expressed by quantized `activation_min`/`activation_max`. FC uses the full signed INT8 output range.

`sw/model/model_quant.h`, `model_desc.h` and the production `cnn_top` path remain the C0 ABI. They must not be used as proof of D4 deployment semantics.

## D4 frozen deployment contract

D4 is fixed by:

- `docs/reports/edgembconv_hwacandidate_d4_promotion_contract_20260909.md`
- `docs/reports/edgembconv_hwacandidate_d4_promotion_source_manifest_20260909.json`
- the hashed deployment manifest/NPZ recorded by those files

D4 requires:

- signed INT8 activation and weight;
- per-output-channel symmetric weight quantization;
- INT32 accumulator and folded bias;
- nearest-away-from-zero requantization;
- signed INT8 saturation;
- explicit source-name normalization from the deployment manifest.

The integer reference may use INT64 temporaries only to audit that the architectural INT32 accumulator bound is not exceeded. The D4 audit covered 2,607 checks, observed maximum absolute accumulator 43,275,427, and reported no INT32 overflow.

## Accuracy and invalidation

The frozen D4 result is FP32 91.63% and deployment INT8 91.46% on official CIFAR-10 test10k. This accuracy belongs only to the frozen network graph, weights, BN folding, quantization and manifest.

Changing any layer shape, stride, channel group, parameter, weight, BN folding, requant rule or class output invalidates the 91.46% claim. The modified model must be retrained as required, exported again, evaluated on official test10k, checked for fake-quant/exported-integer agreement and INT32 overflow, and assigned a new manifest.

## Hardware acceptance

An RTL arithmetic test proves only the tested primitive. D4 deployment requires successively:

1. primitive/vector exactness;
2. standalone block exactness and ledger conservation;
3. full-network ten-logit exactness under required backpressure/response modes;
4. matching-source XC7Z020 full-top implementation.

No C0 header, ten-vector hardware PASS, cycle model, synth-only result or OOC route can substitute for these D4 gates.
