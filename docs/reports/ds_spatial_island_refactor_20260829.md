# Spatial DS hierarchical-island refactor

Date: 2026-08-29  
Device: `xc7z020clg400-1`  
Scope: experimental `ds_block_tile_engine_spatial` only. The retained
`cnn_layer_runner`, production DS engine, and full-network harness were not
changed.

## Implementation

The spatial prototype now has explicit compute-island boundaries:

* `ds_spatial_dw_producer_island` owns the direct 16-lane DW pipeline, DW
  requantizers, and an elastic registered 128-bit write-command slot.
* `dw_pw_spatial_block_buffer_island` and its two
  `dw_pw_spatial_bank_bram` instances remain the ownership/epoch/commit
  boundary. BRAM write enables are generated only from each bank's local
  command register.
* `ds_spatial_pw_consumer_island` owns the direct 8x8 PW core behind the
  committed-bank read stream.
* DW lane masks are applied at the registered operand ingress, keeping the
  lane-mask mux out of the DSP accumulator timing arc.

The scheduler retains the existing external ABI, spatial block order,
commit/acquire/release tags, and no-intermediate-requant behavior. The
registered island command boundary adds no functional changes to the six-case
reference workload.

## Functional evidence

```text
PASS tb_ds_block_tile_engine_spatial cases=6 exact_reference
```

Cases cover the existing six combinations (`Cin=1/7/16/17/48/128`, output
tails, stride 1/2, and spatial/channel tails). Post-refactor cycles were
68/250/513/125/666/3451; all expected writes were observed and overlap was
preserved in the larger cases (155 and 640 measured overlap cycles).

## 8 ns XC7Z020 OOC screen

The fast routed screen used Vivado 2025.2, `general.maxThreads=2`,
`xc7z020clg400-1`, 8.000 ns, and `Quick` place/route. Reports:
`build/reports/vivado_ds_block_tile_engine_spatial_ooc_20260829_quick/`.

| Metric | Post-route result |
|---|---:|
| WNS / TNS | -27.285 ns / -437739.750 ns |
| WHS / THS | +0.096 ns / 0 ns |
| Setup failing endpoints | 66,488 |
| LUT / FF | 36,612 (68.82%) / 58,946 (55.40%) |
| DSP | 160 (72.73%) |
| BRAM | 48 (34.29%) |
| Total on-chip power | 0.430 W |
| Routing errors | 0 |

The worst path is `pw_pending_k_reg[6]` to `pw_state_reg[0]`, with 35.154 ns
data delay: 1.615 ns logic and 33.539 ns routing. Its high-fanout nets include
`pw_pending_k[6]` (fanout 1,027) and the clock net (fanout 68,423). The prior
DW path was removed by ingress masking, but the design exposed a larger
cross-island PW ready/state fanout cone. Resource mapping also rose to 160
DSPs, above the 70% device limit.

For context, the earlier BRAM screen was WNS `-0.278 ns` and the prior bank
island screen was WNS `-0.434 ns`; this candidate is therefore a negative
timing/PPA result despite clean routing and exact simulation. It fails the
required `WNS >= +0.5 ns`, zero-TNS, and DSP/resource gates. No full-top route
was run.

## Decision

`NEGATIVE_RESULT`: retain the island modules and protocol as an exploratory
contract only; do not integrate this candidate into production. A follow-up
would need to register PW geometry/state descriptors and eliminate the
high-fanout `pw_pending_k`/ready feedback cone before another expensive route.
