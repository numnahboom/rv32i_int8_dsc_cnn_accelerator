# EdgeMBConv hardware-aware candidate: static ablation ledger

Date: 2026-09-02
Schema: `C10-HWQA-v1-edgembconv-hwacandidate-static-ablation`

This report freezes a candidate workload for later training, export, cycle modeling, and RTL integration. It does not claim accuracy, cycle, synthesis, route, power, or energy results. The existing C0 artifacts and paths are untouched and remain the formal baseline.

## Scope and locked principles

- Fixed CIFAR-10 input: 32x32x3, 10 classes; no input or precision reduction.
- MBConv (PW-DW-PW) is the body primitive. Residual adds and expansion are explicit.
- Fused blocks are limited to the current candidate A; they are an ablation variable, not an assumed default.
- No arbitrary width changes or dense 3x3 additions were introduced. D4/D8 only remove one already-defined residual block.
- Every parameter count below means deployed kernel weights plus one folded bias per output channel. The supplied C1 anchor uses its existing weight-only convention; this mismatch is called out rather than hidden.

## Minimum ablation set

| Variant | Definition | Dense 3x3 policy | Primitive set | Training/accuracy status |
| --- | --- | --- | --- | --- |
| A | Current EdgeMBConv-Hybrid | stem + two fused blocks | dense3x3, PW, DW, residual | not run in this static slice |
| B | A with 32x32 residual fused block replaced by MBConv | stem + one 16x16 fused block | same subset, fused count reduced | not run |
| C | Both early fused blocks replaced by MBConv | stem only | DW/PW-oriented body | not run |
| D4 | C minus one 4x4 residual MBConv | stem only | same as C | not run |
| D8 | C minus one 8x8 residual MBConv | stem only | same as C | not run |

## Operator ledger

The three requested operator percentages are shown against both semantic MACs and convolution MACs. FC is reported as `other`, so the semantic percentages reconcile exactly rather than silently assigning FC to a convolution class.

| Variant | Params (weights+bias) | Semantic MAC | Dense 3x3 | PW 1x1 | DW 3x3 | Other | Peak internal int8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 280,122 | 17,211,904 | 6,340,608 (36.84%) | 10,223,616 (59.40%) | 645,120 (3.75%) | 2,560 (0.01%) | 32,768 elems (32,768 B) |
| B | 276,346 | 13,312,512 | 1,622,016 (12.18%) | 10,747,904 (80.74%) | 940,032 (7.06%) | 2,560 (0.02%) | 32,768 elems (32,768 B) |
| C | 272,570 | 12,730,880 | 442,368 (3.47%) | 11,272,192 (88.54%) | 1,013,760 (7.96%) | 2,560 (0.02%) | 32,768 elems (32,768 B) |
| D4 | 204,090 | 11,645,440 | 442,368 (3.80%) | 10,223,616 (87.79%) | 976,896 (8.39%) | 2,560 (0.02%) | 32,768 elems (32,768 B) |
| D8 | 254,714 | 11,608,576 | 442,368 (3.81%) | 10,223,616 (88.07%) | 940,032 (8.10%) | 2,560 (0.02%) | 32,768 elems (32,768 B) |

### DW/PW application-narrative audit

| Variant | Dense 3x3 / convolution MAC | PW+DW / semantic MAC | Assessment |
| --- | ---: | ---: | --- |
| A | 36.84% | 63.15% | MIXED_DENSE_COST_WEAKENS_DW_PW_NARRATIVE |
| B | 12.19% | 87.80% | MOSTLY_DW_PW_WITH_LIMITED_DENSE_OPERATOR |
| C | 3.48% | 96.51% | CONSISTENT_WITH_DW_PW_ACCELERATOR |
| D4 | 3.80% | 96.18% | CONSISTENT_WITH_DW_PW_ACCELERATOR |
| D8 | 3.81% | 96.17% | CONSISTENT_WITH_DW_PW_ACCELERATOR |

### Operator shares (semantic / convolution denominator)

| Variant | Dense 3x3 | PW 1x1 | DW 3x3 | Other | Conv MAC total |
| --- | ---: | ---: | ---: | ---: | ---: |
| A | 36.84% / 36.84% | 59.40% / 59.41% | 3.75% / 3.75% | 0.01% / - | 17,209,344 |
| B | 12.18% / 12.19% | 80.74% / 80.75% | 7.06% / 7.06% | 0.02% / - | 13,309,952 |
| C | 3.47% / 3.48% | 88.54% / 88.56% | 7.96% / 7.96% | 0.02% / - | 12,728,320 |
| D4 | 3.80% / 3.80% | 87.79% / 87.81% | 8.39% / 8.39% | 0.02% / - | 11,642,880 |
| D8 | 3.81% / 3.81% | 88.07% / 88.09% | 8.10% / 8.10% | 0.02% / - | 11,606,016 |

## Block ledger

Each row includes MAC and parameter shares over the variant's full semantic graph. A fused anomaly threshold is 25% of total semantic MACs.

### A — A_current_edgembconv_hybrid

| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `stem` | stem | 32x32x3 -> 32x32x16 | 442,368 | 2.57% | 448 | 0.16% | 16,384 elems | no |
| `fused32.residual` | fused_mbconv **FUSED-MAC-ANOMALY** | 32x32x16 -> 32x32x16 | 5,242,880 | 30.46% | 5,168 | 1.84% | 32,768 elems | yes |
| `fused16.down` | fused_mbconv | 32x32x16 -> 16x16x32 | 1,441,792 | 8.38% | 5,696 | 2.03% | 16,384 elems | no |
| `mb16.1` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 6.95% | 4,832 | 1.72% | 16,384 elems | yes |
| `mb16.2` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 6.95% | 4,832 | 1.72% | 16,384 elems | yes |
| `mb8.down` | mbconv | 16x16x32 -> 8x8x64 | 823,296 | 4.78% | 6,912 | 2.47% | 16,384 elems | no |
| `mb8.1` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 6.52% | 17,856 | 6.37% | 8,192 elems | yes |
| `mb8.2` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 6.52% | 17,856 | 6.37% | 8,192 elems | yes |
| `mb8.3` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 6.52% | 17,856 | 6.37% | 8,192 elems | yes |
| `mb4.down` | mbconv | 8x8x64 -> 4x4x128 | 804,864 | 4.68% | 26,112 | 9.32% | 8,192 elems | no |
| `mb4.1` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 6.31% | 68,480 | 24.45% | 4,096 elems | yes |
| `mb4.2` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 6.31% | 68,480 | 24.45% | 4,096 elems | yes |
| `head` | head | 4x4x128 -> 4x4x256 | 524,288 | 3.05% | 33,024 | 11.79% | 4,096 elems | no |
| `classifier` | classifier | 1x1x256 -> 1x1x10 | 2,560 | 0.01% | 2,570 | 0.92% | 256 elems | no |

Fused audit: **ANOMALY** — `fused32.residual` exceeds 25% of semantic MACs.

### B — B_mb32_replaces_fused32

| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `stem` | stem | 32x32x3 -> 32x32x16 | 442,368 | 3.32% | 448 | 0.16% | 16,384 elems | no |
| `mb32.replacement_fused32` | mbconv | 32x32x16 -> 32x32x16 | 1,343,488 | 10.09% | 1,392 | 0.50% | 32,768 elems | yes |
| `fused16.down` | fused_mbconv | 32x32x16 -> 16x16x32 | 1,441,792 | 10.83% | 5,696 | 2.06% | 16,384 elems | no |
| `mb16.1` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 8.98% | 4,832 | 1.75% | 16,384 elems | yes |
| `mb16.2` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 8.98% | 4,832 | 1.75% | 16,384 elems | yes |
| `mb8.down` | mbconv | 16x16x32 -> 8x8x64 | 823,296 | 6.18% | 6,912 | 2.50% | 16,384 elems | no |
| `mb8.1` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.43% | 17,856 | 6.46% | 8,192 elems | yes |
| `mb8.2` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.43% | 17,856 | 6.46% | 8,192 elems | yes |
| `mb8.3` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.43% | 17,856 | 6.46% | 8,192 elems | yes |
| `mb4.down` | mbconv | 8x8x64 -> 4x4x128 | 804,864 | 6.05% | 26,112 | 9.45% | 8,192 elems | no |
| `mb4.1` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 8.15% | 68,480 | 24.78% | 4,096 elems | yes |
| `mb4.2` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 8.15% | 68,480 | 24.78% | 4,096 elems | yes |
| `head` | head | 4x4x128 -> 4x4x256 | 524,288 | 3.94% | 33,024 | 11.95% | 4,096 elems | no |
| `classifier` | classifier | 1x1x256 -> 1x1x10 | 2,560 | 0.02% | 2,570 | 0.93% | 256 elems | no |

Fused audit: no single fused block exceeds the 25% semantic-MAC threshold.

### C — C_all_mbconv_early

| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `stem` | stem | 32x32x3 -> 32x32x16 | 442,368 | 3.47% | 448 | 0.16% | 16,384 elems | no |
| `mb32.replacement_fused32` | mbconv | 32x32x16 -> 32x32x16 | 1,343,488 | 10.55% | 1,392 | 0.51% | 32,768 elems | yes |
| `mb16.replacement_fused16_down` | mbconv | 32x32x16 -> 16x16x32 | 860,160 | 6.76% | 1,920 | 0.70% | 32,768 elems | no |
| `mb16.1` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 9.39% | 4,832 | 1.77% | 16,384 elems | yes |
| `mb16.2` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 9.39% | 4,832 | 1.77% | 16,384 elems | yes |
| `mb8.down` | mbconv | 16x16x32 -> 8x8x64 | 823,296 | 6.47% | 6,912 | 2.54% | 16,384 elems | no |
| `mb8.1` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.82% | 17,856 | 6.55% | 8,192 elems | yes |
| `mb8.2` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.82% | 17,856 | 6.55% | 8,192 elems | yes |
| `mb8.3` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 8.82% | 17,856 | 6.55% | 8,192 elems | yes |
| `mb4.down` | mbconv | 8x8x64 -> 4x4x128 | 804,864 | 6.32% | 26,112 | 9.58% | 8,192 elems | no |
| `mb4.1` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 8.53% | 68,480 | 25.12% | 4,096 elems | yes |
| `mb4.2` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 8.53% | 68,480 | 25.12% | 4,096 elems | yes |
| `head` | head | 4x4x128 -> 4x4x256 | 524,288 | 4.12% | 33,024 | 12.12% | 4,096 elems | no |
| `classifier` | classifier | 1x1x256 -> 1x1x10 | 2,560 | 0.02% | 2,570 | 0.94% | 256 elems | no |

Fused audit: no single fused block exceeds the 25% semantic-MAC threshold.

### D4 — D4_C_minus_one_mb4

| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `stem` | stem | 32x32x3 -> 32x32x16 | 442,368 | 3.80% | 448 | 0.22% | 16,384 elems | no |
| `mb32.replacement_fused32` | mbconv | 32x32x16 -> 32x32x16 | 1,343,488 | 11.54% | 1,392 | 0.68% | 32,768 elems | yes |
| `mb16.replacement_fused16_down` | mbconv | 32x32x16 -> 16x16x32 | 860,160 | 7.39% | 1,920 | 0.94% | 32,768 elems | no |
| `mb16.1` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 10.27% | 4,832 | 2.37% | 16,384 elems | yes |
| `mb16.2` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 10.27% | 4,832 | 2.37% | 16,384 elems | yes |
| `mb8.down` | mbconv | 16x16x32 -> 8x8x64 | 823,296 | 7.07% | 6,912 | 3.39% | 16,384 elems | no |
| `mb8.1` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 8,192 elems | yes |
| `mb8.2` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 8,192 elems | yes |
| `mb8.3` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 8,192 elems | yes |
| `mb4.down` | mbconv | 8x8x64 -> 4x4x128 | 804,864 | 6.91% | 26,112 | 12.79% | 8,192 elems | no |
| `mb4.1` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 9.32% | 68,480 | 33.55% | 4,096 elems | yes |
| `head` | head | 4x4x128 -> 4x4x256 | 524,288 | 4.50% | 33,024 | 16.18% | 4,096 elems | no |
| `classifier` | classifier | 1x1x256 -> 1x1x10 | 2,560 | 0.02% | 2,570 | 1.26% | 256 elems | no |

Fused audit: no single fused block exceeds the 25% semantic-MAC threshold.

### D8 — D8_C_minus_one_mb8

| Block | Type | Input -> output | MAC | MAC share | Params | Param share | Peak internal activation | Residual |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `stem` | stem | 32x32x3 -> 32x32x16 | 442,368 | 3.81% | 448 | 0.18% | 16,384 elems | no |
| `mb32.replacement_fused32` | mbconv | 32x32x16 -> 32x32x16 | 1,343,488 | 11.57% | 1,392 | 0.55% | 32,768 elems | yes |
| `mb16.replacement_fused16_down` | mbconv | 32x32x16 -> 16x16x32 | 860,160 | 7.41% | 1,920 | 0.75% | 32,768 elems | no |
| `mb16.1` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 10.30% | 4,832 | 1.90% | 16,384 elems | yes |
| `mb16.2` | mbconv | 16x16x32 -> 16x16x32 | 1,196,032 | 10.30% | 4,832 | 1.90% | 16,384 elems | yes |
| `mb8.down` | mbconv | 16x16x32 -> 8x8x64 | 823,296 | 7.09% | 6,912 | 2.71% | 16,384 elems | no |
| `mb8.1` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 9.67% | 17,856 | 7.01% | 8,192 elems | yes |
| `mb8.2` | mbconv | 8x8x64 -> 8x8x64 | 1,122,304 | 9.67% | 17,856 | 7.01% | 8,192 elems | yes |
| `mb4.down` | mbconv | 8x8x64 -> 4x4x128 | 804,864 | 6.93% | 26,112 | 10.25% | 8,192 elems | no |
| `mb4.1` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 9.35% | 68,480 | 26.89% | 4,096 elems | yes |
| `mb4.2` | mbconv | 4x4x128 -> 4x4x128 | 1,085,440 | 9.35% | 68,480 | 26.89% | 4,096 elems | yes |
| `head` | head | 4x4x128 -> 4x4x256 | 524,288 | 4.52% | 33,024 | 12.97% | 4,096 elems | no |
| `classifier` | classifier | 1x1x256 -> 1x1x10 | 2,560 | 0.02% | 2,570 | 1.01% | 256 elems | no |

Fused audit: no single fused block exceeds the 25% semantic-MAC threshold.

## Baseline comparison anchors

These are comparison anchors only. No accuracy/cycle/synthesis evidence is inferred for any candidate from this static ledger.

| ID | Architecture | Reported semantic MAC | Reported params | Candidate A MAC delta | Candidate A param delta | Note |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| C0 | EdgeDSCNet-C10 control | 5,136,896 | 72,010 | +12,075,008 (235.06%) | +208,112 (289.00%) | C0 report: 70,880 weights + 1,130 biases |
| C1 | CIFAR ResNet-20 quality anchor | 40,813,184 | 270,896 | -23,601,280 (-57.83%) | +9,226 (3.41%) | C1 profile's published params field is kernel-weight count (biases are not included) |

C0's published 70.05% FP32 result is retained as formal baseline evidence, not treated as its architecture ceiling; its training protocol lacked augmentation, BN, and a scheduler. C1 ResNet-20 remains a quality anchor, not an automatic replacement target.

## Hardware mapping audit

- PW 1x1 maps directly to the existing DW/PW accelerator and tagged partial-K/scratch-bank path.
- DW 3x3 maps to the existing retained DW window/tile producer and commit fence.
- Dense 3x3 does not map directly to the DW/PW path. The minimum candidate mechanism is the separately-prototyped 128-MAC output-stationary tile plus a SAME-halo/window feeder and dense weight layout. A's stem and fused blocks therefore must be counted explicitly; they cannot be called DW/PW work.
- Residual adds require scale alignment and a block-boundary add, but no new multiply primitive.
- GAP/FC remain a small tail and are not hidden in the three convolution categories.

## Decision boundary

This evidence only locks the candidates and their arithmetic. The next gate is to train A/B/C/D4/D8 under the same fixed protocol, evaluate FP32 and deployment INT8 on the full test set, and then run a real cycle model before selecting any graph for RTL integration. No candidate is declared better than C0 here.

## Generated artifacts

- Manifest: `build/edgembconv_hwacandidate/edgembconv_hwacandidate_manifest.json`
- Per-variant profiles: `build/edgembconv_hwacandidate/profile_<variant>.json`
- Generator: `python/profile_edgembconv_hwacandidate.py`
