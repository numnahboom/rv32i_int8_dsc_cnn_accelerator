# M1.1-A non-zero fixture RTL gate

Status: `NONZERO_FIXTURE_RTL_PASS`. The independent fixture/reference and the current standalone core pass the non-zero arithmetic gate.

The run covers DS1/DS2 with no backpressure and randomized memory/output backpressure. The testbench still checks sink bytes, address/context/owner/epoch/last metadata, config count, DW/PW MAC/token/output ledgers, and error=0.

## Latest first mismatches and ledgers

| Case | First mismatch (word/address) | Expected -> actual | Cycles | Outputs | DW vectors/MAC | PW tokens/MAC | Stalls | error |
|---|---|---|---:|---:|---:|---:|---:|---:|
| layer1_no_bp | none | | 33142 | 8192 | 1024/147456 | 8192/524288 | 0 | 0 |
| layer1_random | none | | 36631 | 8192 | 1024/147456 | 8192/524288 | 7958 | 0 |
| layer2_no_bp | none | | 163620 | 4096 | 512/73728 | 8192/524288 | 0 | 0 |
| layer2_random | none | | 208274 | 4096 | 512/73728 | 8192/524288 | 4014 | 0 |

All four DS1/DS2 cases passed with non-zero fixture data, including randomized memory/output backpressure.

This is standalone M1.1-A evidence only, not full-network/full-top evidence.
