# EdgeMBConv hardware-aware candidate D4 — cycle/memory model

This independent D4 report freezes the validated deployment graph and does not modify C0, training artifacts, checkpoints, or production RTL. It is a traceable cycle projection, not full-top synthesis, post-route, power, or energy evidence.

## Frozen source and acceptance boundary

- Profile: `build/edgembconv_hwacandidate/profile_D4.json` (SHA256 `6143b2d3c79e3452a687f6a20892d817c0a6388088a5933af282e3b2a89993b9`)
- Deployment manifest: `build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_deploy/edgembconv_hwacandidate_d4_deploy_manifest.json` (SHA256 `36ddce98e8e6da6ff69054993492f7c9de569624dbc15209c3e0c48e4e38d06c`)
- Guard: PASS — params=204,090, semantic MAC=11,645,440, dense3x3=442,368, PW=10,223,616, DW=976,896
- Network shape/counts are read from those files only; no hand-written D4 layer list is used.

## Mapping provenance

| Item | Mapping | Evidence class |
|---|---|---|
| PW / dense tile | 8 pixels × 16 Cout, one K token/cycle, 128 products/token | validated dense128 RTL contract + exact tile formula |
| Dense stem halo | 1×8 output tile, SAME 3×10 footprint, packed 32-bit source words | exact shape/halo formula; feeder integration pending |
| DW service | 4×8 command, 16-channel group, 288 vector tap tokens, 128 stream4 writes | measured 4x8 RTL probe |
| DW source fill | footprint words + 7 cycles; first fill exposed, later fills double-bank hidden | measured fill contract + scheduler assumption |
| Requant/writeback | explicit vector4 writes; physical tail commits retained | exact packing formula, requant RTL still to integrate |
| Residual | shortcut scratch read plus vector add, words+1 pipeline | model assumption; exact RTL validation pending |

## Operator totals

| Operator | Semantic MAC | Share |
|---|---:|---:|
| dense3x3 | 442,368 | 3.80% |
| pw1x1 | 10,223,616 | 87.79% |
| dw3x3 | 976,896 | 8.39% |
| other | 2,560 | 0.02% |
| **total** | **11,645,440** | **100.00%** |

The D4 convolution narrative remains DW/PW-oriented: dense 3×3 is 3.80% of semantic MACs; PW+DW are 96.18%. There is no fused block in D4, so no single fused block anomaly is present.

## Per-operation schedule

Columns distinguish semantic work from physical tile issue and memory/overlap accounting.

| Op | Type | Shape | K/M | semantic MAC | tiles | issue | DW/source service | weight words/refills | activation words | vector4 writes | selected cycles | serial cycles |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `stem.dense3x3` | dense3x3 | 32x32x3→32x32x16 | 3/16 | 442,368 | 128 | 3,456 | 2,944 | 144/1 | 6,912 | 4,096 | 7,553 | 11,009 |
| `mb32.replacement_fused32.expand.1x1` | pw1x1 | 32x32x16→32x32x32 | 16/32 | 524,288 | 256 | 4,096 | 0 | 200/2 | 8,192 | 8,192 | 12,289 | 16,385 |
| `mb32.replacement_fused32.spatial.dw3x3` | dw3x3 | 32x32x32→32x32x32 | 32/32 | 294,912 | 64 | 113,106 | 15,808 | 144/2 | 0 | 8,192 | 113,353 | 128,914 |
| `mb32.replacement_fused32.project.1x1` | pw1x1 | 32x32x32→32x32x16 | 32/16 | 524,288 | 128 | 4,096 | 0 | 164/1 | 8,192 | 4,096 | 8,193 | 12,289 |
| `mb16.replacement_fused16_down.expand.1x1` | pw1x1 | 32x32x16→32x32x32 | 16/32 | 524,288 | 256 | 4,096 | 0 | 200/2 | 8,192 | 8,192 | 12,289 | 16,385 |
| `mb16.replacement_fused16_down.spatial.dw3x3` | dw3x3 | 32x32x32→16x16x32 | 32/32 | 73,728 | 16 | 35,730 | 9,904 | 144/2 | 0 | 2,048 | 36,349 | 45,634 |
| `mb16.replacement_fused16_down.project.1x1` | pw1x1 | 16x16x32→16x16x32 | 32/32 | 262,144 | 64 | 2,048 | 0 | 328/2 | 4,096 | 2,048 | 4,097 | 6,145 |
| `mb16.1.expand.1x1` | pw1x1 | 16x16x32→16x16x64 | 32/64 | 524,288 | 128 | 4,096 | 0 | 656/4 | 8,192 | 4,096 | 8,193 | 12,289 |
| `mb16.1.spatial.dw3x3` | dw3x3 | 16x16x64→16x16x64 | 64/64 | 147,456 | 32 | 56,580 | 7,904 | 288/4 | 0 | 4,096 | 56,827 | 64,484 |
| `mb16.1.project.1x1` | pw1x1 | 16x16x64→16x16x32 | 64/32 | 524,288 | 64 | 4,096 | 0 | 584/2 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb16.2.expand.1x1` | pw1x1 | 16x16x32→16x16x64 | 32/64 | 524,288 | 128 | 4,096 | 0 | 656/4 | 8,192 | 4,096 | 8,193 | 12,289 |
| `mb16.2.spatial.dw3x3` | dw3x3 | 16x16x64→16x16x64 | 64/64 | 147,456 | 32 | 56,580 | 7,904 | 288/4 | 0 | 4,096 | 56,827 | 64,484 |
| `mb16.2.project.1x1` | pw1x1 | 16x16x64→16x16x32 | 64/32 | 524,288 | 64 | 4,096 | 0 | 584/2 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb8.down.expand.1x1` | pw1x1 | 16x16x32→16x16x64 | 32/64 | 524,288 | 128 | 4,096 | 0 | 656/4 | 8,192 | 4,096 | 8,193 | 12,289 |
| `mb8.down.spatial.dw3x3` | dw3x3 | 16x16x64→8x8x64 | 64/64 | 36,864 | 8 | 17,892 | 4,952 | 288/4 | 0 | 1,024 | 18,511 | 22,844 |
| `mb8.down.project.1x1` | pw1x1 | 8x8x64→8x8x64 | 64/64 | 262,144 | 32 | 2,048 | 0 | 1,168/4 | 4,096 | 1,024 | 3,073 | 5,121 |
| `mb8.1.expand.1x1` | pw1x1 | 8x8x64→8x8x128 | 64/128 | 524,288 | 64 | 4,096 | 0 | 2,336/8 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb8.1.spatial.dw3x3` | dw3x3 | 8x8x128→8x8x128 | 128/128 | 73,728 | 16 | 28,344 | 3,952 | 576/8 | 0 | 2,048 | 28,591 | 32,296 |
| `mb8.1.project.1x1` | pw1x1 | 8x8x128→8x8x64 | 128/64 | 524,288 | 32 | 4,096 | 0 | 2,192/4 | 8,192 | 1,024 | 5,121 | 9,217 |
| `mb8.2.expand.1x1` | pw1x1 | 8x8x64→8x8x128 | 64/128 | 524,288 | 64 | 4,096 | 0 | 2,336/8 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb8.2.spatial.dw3x3` | dw3x3 | 8x8x128→8x8x128 | 128/128 | 73,728 | 16 | 28,344 | 3,952 | 576/8 | 0 | 2,048 | 28,591 | 32,296 |
| `mb8.2.project.1x1` | pw1x1 | 8x8x128→8x8x64 | 128/64 | 524,288 | 32 | 4,096 | 0 | 2,192/4 | 8,192 | 1,024 | 5,121 | 9,217 |
| `mb8.3.expand.1x1` | pw1x1 | 8x8x64→8x8x128 | 64/128 | 524,288 | 64 | 4,096 | 0 | 2,336/8 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb8.3.spatial.dw3x3` | dw3x3 | 8x8x128→8x8x128 | 128/128 | 73,728 | 16 | 28,344 | 3,952 | 576/8 | 0 | 2,048 | 28,591 | 32,296 |
| `mb8.3.project.1x1` | pw1x1 | 8x8x128→8x8x64 | 128/64 | 524,288 | 32 | 4,096 | 0 | 2,192/4 | 8,192 | 1,024 | 5,121 | 9,217 |
| `mb4.down.expand.1x1` | pw1x1 | 8x8x64→8x8x128 | 64/128 | 524,288 | 64 | 4,096 | 0 | 2,336/8 | 8,192 | 2,048 | 6,145 | 10,241 |
| `mb4.down.spatial.dw3x3` | dw3x3 | 8x8x128→4x4x128 | 128/128 | 18,432 | 8 | 17,928 | 4,952 | 576/8 | 0 | 1,024 | 18,547 | 22,880 |
| `mb4.down.project.1x1` | pw1x1 | 4x4x128→4x4x128 | 128/128 | 262,144 | 16 | 2,048 | 0 | 4,384/8 | 4,096 | 512 | 2,561 | 4,609 |
| `mb4.1.expand.1x1` | pw1x1 | 4x4x128→4x4x256 | 128/256 | 524,288 | 32 | 4,096 | 0 | 8,768/16 | 8,192 | 1,024 | 5,121 | 9,217 |
| `mb4.1.spatial.dw3x3` | dw3x3 | 4x4x256→4x4x256 | 256/256 | 36,864 | 16 | 28,416 | 3,952 | 1,152/16 | 0 | 2,048 | 28,663 | 32,368 |
| `mb4.1.project.1x1` | pw1x1 | 4x4x256→4x4x128 | 256/128 | 524,288 | 16 | 4,096 | 0 | 8,480/8 | 8,192 | 512 | 4,609 | 8,705 |
| `head.project.1x1` | pw1x1 | 4x4x128→4x4x256 | 128/256 | 524,288 | 32 | 4,096 | 0 | 8,768/16 | 8,192 | 1,024 | 5,121 | 9,217 |
| `classifier.fc` | other | 1x1x256→1x1x10 | 256/10 | 2,560 | 0 | 2,560 | 0 | 663/1 | 64 | 0 | 2,562 | 2,722 |

## Per-block schedule

| Block | Input→output | MAC | MAC share | params | param share | PW cycles | DW cycles | residual read/add | DW→PW overlap potential | selected | serial |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `stem` | 32x32x3→32x32x16 | 442,368 | 3.80% | 448 | 0.22% | 7,553 | 0 | 0/0 | 0 | 7,554 | 11,010 |
| `mb32.replacement_fused32` | 32x32x16→32x32x16 | 1,343,488 | 11.54% | 1,392 | 0.68% | 20,482 | 113,353 | 4,096/4,096 | 32 | 137,933 | 165,781 |
| `mb16.replacement_fused16_down` | 32x32x16→16x16x32 | 860,160 | 7.39% | 1,920 | 0.94% | 16,386 | 36,349 | 0/0 | 64 | 52,736 | 68,165 |
| `mb16.1` | 16x16x32→16x16x32 | 1,196,032 | 10.27% | 4,832 | 2.37% | 14,338 | 56,827 | 2,048/2,048 | 128 | 73,215 | 91,111 |
| `mb16.2` | 16x16x32→16x16x32 | 1,196,032 | 10.27% | 4,832 | 2.37% | 14,338 | 56,827 | 2,048/2,048 | 128 | 73,215 | 91,111 |
| `mb8.down` | 16x16x32→8x8x64 | 823,296 | 7.07% | 6,912 | 3.39% | 11,266 | 18,511 | 0/0 | 256 | 29,778 | 40,255 |
| `mb8.1` | 8x8x64→8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 11,266 | 28,591 | 1,024/1,024 | 512 | 40,883 | 53,803 |
| `mb8.2` | 8x8x64→8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 11,266 | 28,591 | 1,024/1,024 | 512 | 40,883 | 53,803 |
| `mb8.3` | 8x8x64→8x8x64 | 1,122,304 | 9.64% | 17,856 | 8.75% | 11,266 | 28,591 | 1,024/1,024 | 512 | 40,883 | 53,803 |
| `mb4.down` | 8x8x64→4x4x128 | 804,864 | 6.91% | 26,112 | 12.79% | 8,706 | 18,547 | 0/0 | 1,024 | 27,254 | 37,731 |
| `mb4.1` | 4x4x128→4x4x128 | 1,085,440 | 9.32% | 68,480 | 33.55% | 9,730 | 28,663 | 512/512 | 2,048 | 38,907 | 51,315 |
| `head` | 4x4x128→4x4x256 | 524,288 | 4.50% | 33,024 | 16.18% | 5,121 | 0 | 0/0 | 0 | 5,122 | 9,218 |
| `classifier` | 1x1x256→1x1x10 | 2,560 | 0.02% | 2,570 | 1.26% | 0 | 0 | 0/0 | 0 | 2,563 | 2,723 |

## Total cycle accounting

- Physical MACs issued by padded 8×16 tiles: **11,700,736**; masked physical products: **55,296**. Semantic work remains **11,645,440**; no network computation is removed.
- Selected dependency-ordered projection: **577,585 cycles** = convolution 570,926 + GAP 4,097 + FC 2,562.
- Serial memory upper comparison: **736,648 cycles**.
- At 125 MHz: selected 4.621 ms; serial upper 5.893 ms.
- Potential DW→following-PW prefetch overlap: 5,216 cycles, **not credited** in selected total because the current schedule keeps block dependencies explicit.
- Source-window words, activation words, scratch words, vector4 writeback, startup/drain, and residual service are all retained in the schedule; none is treated as zero-cost.

## Memory budget mapping

| Buffer | Bytes | BRAM36 lower bound | Evidence/meaning |
|---|---:|---:|---|
| activation_ping_pong | 32,768 | 8 | profile stage-boundary peak + mapping assumption |
| expanded_dw_scratch | 32,768 | 8 | profile internal peak |
| shortcut_scratch | 16,384 | 4 | exact residual input shape maximum |
| pw_weight_cache_double_bank | 8,192 | 2 | rtl_assumption; overlap refill |
| dw_weight_and_qparam_cache | 4,608 | 1 | rtl_assumption |
| dw_window_line_buffer | 4,608 | 1 | rtl_assumption; max 4x8 SAME footprint |
| global_weight_and_qparam_store | 227,722 | 50 | profile weight/bias counts + quantization contract |
| **modeled total** | **327,050** | **74** | lower-bound sum, not Vivado utilization |

Kernel weights are 201,136 INT8 bytes/parameters; the profile separately reports bias_params=2,954. Bias/multiplier/shift metadata is counted as INT32/packed-INT8 words in the machine schedule.

## DSP/resource risk

The 128-MAC array is 128 DSP48E1 if one INT8 product maps to one DSP. XC7Z020 has 220 DSPs, leaving 26 DSPs at the requested 70% ceiling. The historical C0 hierarchy used roughly 65 DSPs including shared stem/FC/control arithmetic; whether those resources can be removed, packed, or mapped to LUTs is not yet proven. Therefore this model does not claim the resource gate.

## C0 comparison

- C0 historical full-top evidence: 5,136,896 MAC, 1,003,577 measured cycles, INT8 top-1 66.16%.
- D4 deployment quality source: 91.46% INT8 (`build/edgembconv_hwacandidate_d4/edgembconv_hwacandidate_d4_test10k.json`); delta **+25.30 pp**.
- D4 adds 6,508,544 semantic MAC (126.70%) relative to C0. The selected D4 cycle value is a model and cannot be called a measured speedup; the model ratio is 0.576× C0.
- C0's 70.05%/66.16% quality is a retained trained-baseline result, not an architecture ceiling; D4 is not declared a replacement.

## First RTL validation block

The first bounded validation should instantiate the existing dense128 output-stationary primitive with a D4-shaped `mb32.expand` tile. It must use nonzero deterministic vectors and an independent Python INT32 scoreboard.

| Item | Expected |
|---|---:|
| Shape | 8 pixels × Cin16 × Cout16 tile (one of mb32.expand's two Cout tiles) |
| Accepted K tokens | 16 |
| Semantic/physical products | 2,048 / 2,048 |
| Vector4 commits | 32 |
| Ideal core cycles | 48 = 16 issue + 32 drain |
| Boundary startup/fence assumption | 50 cycles |
| Three-cycle output stall + boundary assumption | 53 cycles |

Exact vectors (all signed INT8, bias=0): `act[k][p]=k+p+1` for k=0..15 and p=0..7; `weight[k][c]=c-7` for c=0..15. The expected lane formula is `psum[p][c]=sum_k(act[k][p]*weight[k][c])`; the complete 8×16 expected INT32 matrix is recorded in the machine schedule. Required checks are first/last K tags, lane masks, exact 128 psums, output stability during a 3-cycle ready stall, and no duplicate/missing token. Full D4 block and full-top exact logits remain future gates.

## Limitations and next gate

- No D4 RTL integration, synthesis, post-route timing, congestion, activity-based power, or board power was run here.
- The selected schedule assumes packed 32-bit activation words and banked 8-byte activation / 16-byte weight rows; the current legacy external one-int8-per-word ABI cannot be silently substituted.
- DW command service is measured, but D4's expanded-channel command count and multi-block steady-state overlap still require an RTL producer/consumer test.
- Resource risk is material: 128 DSP array plus shared arithmetic may exceed the <70% DSP limit. This is an architecture/dataflow validation issue, not evidence that D4 wins C0.

Machine-readable schedule: `build/edgembconv_hwacandidate_d4_cycle_model/edgembconv_hwacandidate_d4_cycle_schedule.json`.
